<#
.SYNOPSIS
    One-time provisioning of the Windows Server Core CI image (runs inside the guest during bake_image.sh).

.DESCRIPTION
    Invoked by run_provisioning.cmd from autounattend.xml FirstLogonCommands with the seed CD drive letter.
    Leaves a guest that boots straight into a state where test-signed dokan3.sys loads under Driver Verifier:
    test signing on, Dokan test CA trusted, Driver Verifier armed for dokan3.sys, kernel memory dumps
    (including NMI-triggered dumps) enabled, OpenSSH server with key-only access, HLK IFSTest installed.
    Output goes to COM1 (captured by QEMU as serial.log); the host looks for PROVISIONING_SUCCEEDED.
#>
param([string]$SeedDrive = 'E:')
$ErrorActionPreference = 'Stop'

$logFile = 'C:\ci-provisioning.log'
function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Add-Content -Path $logFile -Value $line
    Write-Output $line
}

try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Log "Guest booted: $($cv.ProductName) build $($cv.CurrentBuildNumber).$($cv.UBR)"

    # 1. Disable Windows Update & Defender real-time overhead for deterministic CI
    Log "Disabling Windows Update and adding Defender exclusions..."
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
            foreach ($excl in @('C:\ci', 'C:\FSTMP', 'C:\FSTMP2', 'C:\DokanMount', 'C:\fstest_ntfs', 'M:\')) {
                Add-MpPreference -ExclusionPath $excl -ErrorAction SilentlyContinue
            }
        } catch {
            Log "Defender configuration skipped: $($_.Exception.Message)"
        }
    }

    # Copy seed files to local writable temp dir before using them
    $localSeed = 'C:\Windows\Temp\seed'
    New-Item -ItemType Directory -Force -Path $localSeed | Out-Null
    Copy-Item -Path "$SeedDrive\*" -Destination $localSeed -Recurse -Force

    # 2. Import Dokan test CA certificate (certutil works reliably on headless Server Core)
    Log "Importing DokanCA.cer..."
    & certutil.exe -addstore -f Root "$localSeed\DokanCA.cer" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil Root failed: $LASTEXITCODE" }
    & certutil.exe -addstore -f TrustedPublisher "$localSeed\DokanCA.cer" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil TrustedPublisher failed: $LASTEXITCODE" }

    # 3. Enable TESTSIGNING and pre-arm Driver Verifier for dokan3.sys
    Log "Enabling TESTSIGNING and Driver Verifier for dokan3.sys..."
    & bcdedit.exe /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit testsigning failed: $LASTEXITCODE" }
    $vOut = (& verifier.exe /standard /driver dokan3.sys 2>&1 | Out-String).Trim()
    # verifier.exe exit code 2 = EXIT_CODE_REBOOT_REQUIRED (success; changes take effect on next boot)
    Log "verifier exit=${LASTEXITCODE}: $vOut"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "verifier config failed: $LASTEXITCODE" }

    # 4. Configure Kernel Memory Dump (CrashDumpEnabled=2 -> C:\Windows\MEMORY.DMP) + AutoReboot
    Log "Configuring Kernel Memory Dump (MEMORY.DMP)..."
    $cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    Set-ItemProperty -Path $cc -Name 'CrashDumpEnabled' -Type DWord -Value 2
    Set-ItemProperty -Path $cc -Name 'DumpFile' -Type ExpandString -Value '%SystemRoot%\MEMORY.DMP'
    Set-ItemProperty -Path $cc -Name 'Overwrite' -Type DWord -Value 1
    Set-ItemProperty -Path $cc -Name 'AutoReboot' -Type DWord -Value 1
    # Let the CI host turn guest hangs into a kernel dump via QEMU 'nmi' (BugCheck 0x80 NMI_HARDWARE_FAILURE)
    Set-ItemProperty -Path $cc -Name 'NMICrashDump' -Type DWord -Value 1
    # Ensure pagefile is large enough on C: for kernel memory dump, and zero it on bake shutdown so qemu-img drops it
    $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Set-ItemProperty -Path $mmKey -Name 'PagingFiles' -Type MultiString -Value @('C:\pagefile.sys 2048 4096')
    Set-ItemProperty -Path $mmKey -Name 'ClearPageFileAtShutdown' -Type DWord -Value 1

    # 5. Install Win32-OpenSSH from local seed copy
    Log "Installing Win32-OpenSSH..."
    $sshDest = 'C:\Program Files\OpenSSH'
    New-Item -ItemType Directory -Force -Path $sshDest | Out-Null
    Expand-Archive -Path "$localSeed\OpenSSH-Win64.zip" -DestinationPath 'C:\Windows\Temp\openssh-extract' -Force
    $inner = Get-ChildItem 'C:\Windows\Temp\openssh-extract' -Directory | Select-Object -First 1
    if ($inner) {
        Copy-Item -Path "$($inner.FullName)\*" -Destination $sshDest -Recurse -Force
    } else {
        Copy-Item -Path 'C:\Windows\Temp\openssh-extract\*' -Destination $sshDest -Recurse -Force
    }
    Remove-Item 'C:\Windows\Temp\openssh-extract' -Recurse -Force
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$sshDest\install-sshd.ps1"
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Start-Sleep -Seconds 2

    # Configure sshd_config (disable UseDNS so restrict=on isolated NAT never stalls banner exchange)
    $sshData = 'C:\ProgramData\ssh'
    New-Item -ItemType Directory -Force -Path $sshData | Out-Null
    $sshdCfg = "$sshData\sshd_config"
    if (Test-Path -LiteralPath $sshdCfg) {
        $cfgText = Get-Content -LiteralPath $sshdCfg -Raw
        if ($cfgText -notmatch '(?m)^UseDNS\s+no') {
            $cfgText = "UseDNS no`r`n" + $cfgText
        }
        [System.IO.File]::WriteAllText($sshdCfg, $cfgText, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Configure authorized_keys for Administrators
    $authKeys = "$sshData\administrators_authorized_keys"
    Copy-Item -LiteralPath "$localSeed\authorized_keys" -Destination $authKeys -Force
    & icacls.exe $authKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

    # Set PowerShell as default SSH shell and open firewall port 22 on ALL profiles (unique rule name!)
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
    & netsh.exe advfirewall firewall add rule name="DokanCI-SSH-In" dir=in action=allow protocol=TCP localport=22 profile=any
    if ($LASTEXITCODE -ne 0) { throw "netsh advfirewall add rule failed: $LASTEXITCODE" }

    Restart-Service sshd
    Start-Sleep -Seconds 3
    $sshdSvc = Get-Service sshd
    Log "sshd service status: $($sshdSvc.Status)"
    if ($sshdSvc.Status -ne 'Running') { throw "sshd is not running: $($sshdSvc.Status)" }
    $listening = & netstat.exe -ano | Select-String ':22\s'
    Log "netstat port 22: $($listening -join ' | ')"
    if (-not $listening) { throw "sshd is not listening on port 22!" }

    # 6. Create dokan_ifstest user & install HLK IFSTest
    Log "Creating dokan_ifstest user..."
    & net.exe user dokan_ifstest D0kan_1fstest /ADD
    if ($LASTEXITCODE -ne 0) { throw "net user failed: $LASTEXITCODE" }

    Log "Installing WLK/HLK IFSTest..."
    $env:WLK_INST_CACHE = 'C:\Windows\Temp\wlk_inst'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$localSeed\install_wlk_ifstest.ps1"
    if ($LASTEXITCODE -ne 0) { throw "install_wlk_ifstest.ps1 failed: $LASTEXITCODE" }
    Remove-Item -Path 'C:\Windows\Temp\wlk_inst' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $localSeed -Recurse -Force -ErrorAction SilentlyContinue

    # 7. Shrink OS component store and zero free space before shutdown for maximum zstd deduplication
    Log "Running DISM StartComponentCleanup /ResetBase..."
    $tDism = Get-Date
    $dismOut = (& dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-String).Trim()
    Log "DISM exit=${LASTEXITCODE} in $([int]((Get-Date) - $tDism).TotalSeconds)s"
    if ($LASTEXITCODE -ne 0) {
        Log "DISM warning output: $dismOut"
    }

    Log "Cleaning temp, update cache, and log files..."
    foreach ($cleanDir in @(
        'C:\Windows\Temp\*',
        'C:\Windows\SoftwareDistribution\Download\*',
        'C:\Windows\Logs\CBS\*',
        'C:\Windows\Logs\DISM\*',
        'C:\Windows\Panther\UnattendGC\*'
    )) {
        Remove-Item -Path $cleanDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Disable hibernation to eliminate hiberfil.sys
    & powercfg.exe /h off | Out-Null

    Log "Zeroing free space for sparse hole-punching..."

    # Zero free blocks using a sparse-disabled zero stream (capped to avoid filling disk)
    $drive = Get-PSDrive C
    $freeBytes = [int64]($drive.Free - 256MB)
    if ($freeBytes -gt 0) {
        $zeroPath = 'C:\zero.tmp'
        $buf = New-Object byte[] (4MB)
        $fs = [System.IO.File]::Open($zeroPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $written = [int64]0
            while ($written -lt $freeBytes) {
                $chunk = [Math]::Min($buf.Length, $freeBytes - $written)
                $fs.Write($buf, 0, [int]$chunk)
                $written += $chunk
            }
            $fs.Flush()
        } catch {
            Log "Stopped zeroing free space early: $($_.Exception.Message)"
        } finally {
            $fs.Close()
            Remove-Item -LiteralPath $zeroPath -Force -ErrorAction SilentlyContinue
        }
    }

    Log "PROVISIONING_SUCCEEDED"
    exit 0
} catch {
    Log "PROVISIONING_FAILED: $($_.Exception.Message)"
    Log ($_.ScriptStackTrace | Out-String)
    exit 1
}
