param(
    [ValidateSet('all', 'shard1', 'shard2')]
    [string]$Shard = 'all',
    [ValidateSet('fail', 'warn')]
    [string]$XpassPolicy = 'fail',
    [switch]$SimulateBsod
)

$ErrorActionPreference = 'Stop'

function Exec-External {
    param([Parameter(Position = 0, Mandatory = $true)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command returned non-zero exit code ${LASTEXITCODE}: $Command"
    }
}

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host "=== Guest OS: $($cv.ProductName) (Build $($cv.CurrentBuildNumber).$($cv.UBR), Arch $($env:PROCESSOR_ARCHITECTURE), Shard=$Shard) ===" -ForegroundColor Cyan

# Disable ClearPageFileAtShutdown (used only during image bake) so test shutdowns are instant
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'ClearPageFileAtShutdown' -Type DWord -Value 0 -ErrorAction SilentlyContinue

Write-Host "=== Verifying TESTSIGNING is active ==="
$bcd = (& bcdedit.exe /enum '{current}' | Out-String)
if ($bcd -notmatch 'testsigning\s+Yes') {
    throw "TESTSIGNING is NOT active!`n$bcd"
}
Write-Host "TESTSIGNING = Yes [OK]"

Write-Host "=== Installing DokanSetup.exe ==="
$t0 = Get-Date
$installProc = Start-Process -PassThru -Wait -FilePath 'C:\ci\DokanSetup.exe' -ArgumentList @('/quiet', '/norestart', '/log', 'C:\ci\dokan_install.log')
if ($installProc.ExitCode -ne 0) {
    Write-Error "DokanSetup.exe failed with exit code $($installProc.ExitCode)"
    Get-Content 'C:\ci\dokan_install*.log' -ErrorAction SilentlyContinue | Select-Object -Last 80
    throw "Dokan installation failed"
}
Write-Host "Dokan installed in $([int]((Get-Date) - $t0).TotalSeconds)s"

Write-Host "=== Checking Driver Verifier status for dokan3.sys ==="
$vq = (& verifier.exe /query | Out-String)
Write-Host $vq
if ($LASTEXITCODE -ne 0) {
    throw "verifier /query failed with exit code $LASTEXITCODE"
}
if ($vq -notmatch 'dokan3\.sys') {
    throw "Driver Verifier is NOT monitoring dokan3.sys!"
}

if ($SimulateBsod) {
    Write-Host "=== [SIMULATED BSOD] Triggering controlled kernel BugCheck (0xDEADDEAD) with dokan3.sys loaded under Driver Verifier ===" -ForegroundColor Yellow
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DokanCiCrashTrigger {
    [DllImport("ntdll.dll")]
    public static extern uint RtlAdjustPrivilege(int Privilege, bool Enable, bool CurrentThread, out bool Enabled);

    [DllImport("ntdll.dll")]
    public static extern uint NtRaiseHardError(uint ErrorStatus, uint NumberOfParameters, uint UnicodeStringParameterMask, IntPtr Parameters, uint ValidResponseOption, out uint Response);

    public static void CrashNow() {
        bool enabled;
        uint response;
        RtlAdjustPrivilege(19, true, false, out enabled); // SeShutdownPrivilege
        NtRaiseHardError(0xDEADDEADu, 0, 0, IntPtr.Zero, 6, out response); // OptionShutdownSystem
    }
}
"@
    [Console]::Out.Flush()
    [DokanCiCrashTrigger]::CrashNow()
    throw "Simulated BSOD trigger returned unexpectedly without crashing the kernel!"
}

$dokanLib = [System.Environment]::GetEnvironmentVariable('DokanLibrary3', 'Machine')
if ([string]::IsNullOrWhiteSpace($dokanLib)) {
    throw "DokanLibrary3 machine environment variable not found after install"
}
$env:DokanLibrary3 = $dokanLib
$dokanCtl = Join-Path $dokanLib 'dokanctl.exe'
$fsxExe = 'C:\ci\fsx.exe'
$runIfsTest = 'C:\ci\run_ifstest.ps1'

# Auto-detect dokan_fstest.exe (PR #1365+)
$dokanFsTestExe = 'C:\ci\dokan_fstest.exe'
$baselinesDir = 'C:\ci\baselines'
$fsTestResultsDir = 'C:\ci\fstest-results'
$hasDokanFsTest = (Test-Path -LiteralPath $dokanFsTestExe -PathType Leaf) -and (Test-Path -LiteralPath $baselinesDir -PathType Container)
if ($hasDokanFsTest) {
    New-Item -ItemType Directory -Force -Path $fsTestResultsDir | Out-Null
    Write-Host "=== Detected dokan_fstest.exe + baselines; NTFS conformance suite ENABLED (xpass-policy=$XpassPolicy) ===" -ForegroundColor Cyan
} else {
    Write-Host "=== dokan_fstest.exe not present in artifacts; running fsx + IFSTest ===" -ForegroundColor Cyan
}

$ifstestUser = 'dokan_ifstest'
$ifstestPass = 'D0kan_1fstest'
$fsTestPath = 'C:\FSTMP'
$fsTestPath2 = 'C:\FSTMP2'
New-Item -ItemType Directory -Force -Path $fsTestPath, $fsTestPath2 | Out-Null

$commonIfsExcludes = @(
    '-t', 'EndOfFileInformationTest',
    '-t', 'SimpleRenameInformationTest',
    '-t', 'AVChangeLogTest',
    '-t', 'MountedDirtyTest',
    '-t', 'SetCompressionTest',
    '-t', 'FileOpenByIDTest',
    '-t', 'OpenVolumeTest',
    '-t', 'CaseSensitiveTest',
    '-t', 'ShortFileNameTest',
    '-t', 'TunnelingTest',
    '-t', 'CompressionInformationTest',
    '-t', 'LinkInformationTest',
    '-t', 'StreamStandardInformationTest',
    '-t', 'AlternateNameInformationTest',
    '-t', 'HardLinkInformationTest',
    '-t', 'EaInformationTest',
    '-t', 'FullDirectoryInformationTest',
    '-t', 'CreatePagingFileTest',
    '-g', 'ChangeJournal',
    '-g', 'Virus',
    '-g', 'DefragEnhancements',
    '-g', 'Quotas',
    '-g', 'Encryption',
    '-g', 'ObjectId',
    '-g', 'MountPoints',
    '-g', 'ReparsePoints',
    '-g', 'SparseFiles',
    '-g', 'EaInformation',
    '-g', 'FileSystemControlGeneral',
    '/v',
    '/d', '\Device\Dokan_3',
    '/r', $fsTestPath2,
    '/u', $ifstestUser,
    '/U', $ifstestPass
)

$memfsIfsParams = @(
    '-t', 'ArchiveAttributeTest',
    '-g', 'Security',
    '-g', 'CloseCleanupDelete',
    '-t', 'NotificationCleanupAttribTest',
    '-t', 'NotificationSecurityTest'
) + $commonIfsExcludes

$mirrorIfsParams = @(
    '-t', 'FileNameLengthTest'
) + $commonIfsExcludes

function Stop-Mount {
    param(
        [System.Diagnostics.Process]$Proc,
        [string]$MountPoint
    )
    if (-not $Proc -or $Proc.HasExited) {
        return
    }
    $ctlProc = Start-Process -FilePath $dokanCtl -ArgumentList @('/u', $MountPoint) -WindowStyle Hidden -PassThru
    if ($ctlProc -and -not $ctlProc.WaitForExit(10000)) {
        Stop-Process -Id $ctlProc.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $Proc.WaitForExit(15000)) {
        Write-Warning "Mount process $($Proc.Id) did not exit cleanly after dokanctl /u $MountPoint; killing."
        Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue
        $Proc.WaitForExit(5000) | Out-Null
    }
}

function Invoke-MountSuite {
    param(
        [string]$Label,
        [string]$ExePath,
        [string]$Arguments,
        [string]$Destination,
        [string]$UnmountTarget,
        [string]$ProbePath,
        [string[]]$IfsParams,
        [string]$SuiteKind,
        [string]$ArchTag,
        [string]$ConfigName,
        [string]$FsTestTarget
    )
    Write-Host "=== [$Label] Mounting $ExePath $Arguments -> $Destination ===" -ForegroundColor Green
    $tStart = Get-Date
    Remove-Item -Recurse -Force "$fsTestPath2\*" -ErrorAction SilentlyContinue
    $proc = Start-Process -PassThru -NoNewWindow -FilePath $ExePath -ArgumentList $Arguments
    try {
        $ready = $false
        for ($i = 0; $i -lt 40; $i++) {
            if ($proc.HasExited) {
                throw "Mount process exited prematurely with code $($proc.ExitCode)"
            }
            if (Test-Path -LiteralPath $ProbePath) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ready) {
            throw "Mount point $ProbePath did not become ready within 10s"
        }

        Write-Host "[$Label] Running fsx -N 5000..."
        Exec-External { & $fsxExe -N 5000 "$Destination\fsxtest" }

        if ($hasDokanFsTest) {
            $baselineName = if ($SuiteKind -eq 'memfs') { 'dokan_memfs.json' } else { 'dokan_mirror.json' }
            $baselinePath = Join-Path $baselinesDir $baselineName
            $rootArg = if ($Destination -match '^[A-Za-z]:$') { "$Destination\" } else { $Destination }
            $jsonOut = Join-Path $fsTestResultsDir "${SuiteKind}_${ArchTag}_${ConfigName}.json"
            Write-Host "[$Label] Running dokan_fstest ($FsTestTarget / $ArchTag)..."
            Exec-External {
                & $dokanFsTestExe `
                    "--root=$rootArg" `
                    "--baseline=$baselinePath" `
                    "--target=$FsTestTarget" `
                    "--target-arch=$ArchTag" `
                    "--xpass-policy=$XpassPolicy" `
                    "--json-out=$jsonOut"
            }
        }

        if ($Destination -match '^[A-Za-z]:$') {
            Write-Host "[$Label] Running IFSTest..."
            Exec-External { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runIfsTest @IfsParams "$Destination\" }
        } else {
            Write-Host "[$Label] Skipping IFSTest on non-drive mount ($Destination)"
        }
    } finally {
        Stop-Mount -Proc $proc -MountPoint $UnmountTarget
    }
    Write-Host "=== [$Label] PASSED in $([int]((Get-Date) - $tStart).TotalSeconds)s ===" -ForegroundColor Green
}

# 0. Real NTFS --strict conformance gate (when dokan_fstest.exe is present; runs on shard1 / all)
if ($hasDokanFsTest -and ($Shard -eq 'all' -or $Shard -eq 'shard1')) {
    Write-Host "=== [ntfs-strict] Running dokan_fstest --strict on real NTFS (C:\fstest_ntfs) ===" -ForegroundColor Green
    $tNtfs = Get-Date
    $ntfsRoot = 'C:\fstest_ntfs'
    if (Test-Path -LiteralPath $ntfsRoot) {
        Exec-External { & $dokanFsTestExe "--cleanup-dir=$ntfsRoot" }
    }
    New-Item -ItemType Directory -Force -Path $ntfsRoot | Out-Null
    $ntfsJson = Join-Path $fsTestResultsDir "ntfs_strict_build_$($cv.CurrentBuildNumber).json"
    try {
        Exec-External { & $dokanFsTestExe "--root=$ntfsRoot" '--strict' "--json-out=$ntfsJson" }
    } finally {
        if (Test-Path -LiteralPath $ntfsRoot) {
            & $dokanFsTestExe "--cleanup-dir=$ntfsRoot"
            if ($LASTEXITCODE -ne 0) {
                & cmd.exe /d /c "rmdir /s /q \\?\$ntfsRoot"
            }
        }
    }
    Write-Host "=== [ntfs-strict] PASSED in $([int]((Get-Date) - $tNtfs).TotalSeconds)s ===" -ForegroundColor Green
}

# 1. MemFS (x64 + x86) -> shard1 / all
if ($Shard -eq 'all' -or $Shard -eq 'shard1') {
    foreach ($entry in @(
        @{ Label = 'memfs-x64-drive'; Arch = 'x64'; Exe = "$dokanLib\sample\memfs\memfs.exe" },
        @{ Label = 'memfs-x86-drive'; Arch = 'x86'; Exe = "$dokanLib\x86\sample\memfs\memfs.exe" }
    )) {
        Invoke-MountSuite `
            -Label $entry.Label `
            -ExePath $entry.Exe `
            -Arguments '/l M' `
            -Destination 'M:' `
            -UnmountTarget 'M' `
            -ProbePath 'M:\' `
            -IfsParams $memfsIfsParams `
            -SuiteKind 'memfs' `
            -ArchTag $entry.Arch `
            -ConfigName 'drive' `
            -FsTestTarget 'memfs_drive'
    }
}

# 2. Mirror (x64 all 6 mount configs + x86 drive & netUnc), balanced across shard1 and shard2
#    shard1: memfs x64+x86 (~100s) + mirror x64 (drive, dirJunction, driveRemovable, netUnc) (~350s) => ~450s
#    shard2: mirror x64 (driveMntMgr, driveRemovableMntMgr) + mirror x86 (drive, netUnc) (~495s)
$mirrorConfigs = @(
    @{ Name = 'drive';                Target = 'mirror_drive';            Args = '/l M';                Dest = 'M:';            Unmount = 'M';            Shard = 'shard1' },
    @{ Name = 'dirJunction';          Target = 'mirror_junction';         Args = '/l C:\DokanMount';    Dest = 'C:\DokanMount'; Unmount = 'C:\DokanMount'; Shard = 'shard1' },
    @{ Name = 'driveRemovable';       Target = 'mirror_removable';        Args = '/l M /m';             Dest = 'M:';            Unmount = 'M';            Shard = 'shard1' },
    @{ Name = 'driveMntMgr';          Target = 'mirror_mntmgr';           Args = '/l M /o';             Dest = 'M:';            Unmount = 'M';            Shard = 'shard2' },
    @{ Name = 'driveRemovableMntMgr'; Target = 'mirror_removable_mntmgr'; Args = '/l M /o /m';          Dest = 'M:';            Unmount = 'M';            Shard = 'shard2' },
    @{ Name = 'netUnc';               Target = 'mirror_unc';              Args = '/l M /n \myfs\dokan'; Dest = '\\myfs\dokan';  Unmount = 'M';            Shard = 'shard1' }
)

$mirrorRuns = @(
    @{ Arch = 'x64'; Exe = "$dokanLib\sample\mirror\mirror.exe";     Configs = $mirrorConfigs; ForceShard = $null },
    @{ Arch = 'x86'; Exe = "$dokanLib\x86\sample\mirror\mirror.exe"; Configs = ($mirrorConfigs | Where-Object { $_.Name -in @('drive', 'netUnc') }); ForceShard = 'shard2' }
)

foreach ($mr in $mirrorRuns) {
    foreach ($cfg in $mr.Configs) {
        $assignedShard = if ($mr.ForceShard) { $mr.ForceShard } else { $cfg.Shard }
        if ($Shard -ne 'all' -and $Shard -ne $assignedShard) {
            continue
        }
        $mirrorDir = "$fsTestPath\$($mr.Arch)_$($cfg.Name)"
        New-Item -ItemType Directory -Force -Path $mirrorDir | Out-Null
        Remove-Item -Recurse -Force "$mirrorDir\*" -ErrorAction SilentlyContinue
        New-Item -ItemType File -Force -Path "$mirrorDir\tmp" | Out-Null

        if ($cfg.Dest.StartsWith('C:\')) {
            New-Item -ItemType Directory -Force -Path $cfg.Dest | Out-Null
            Remove-Item -Recurse -Force "$($cfg.Dest)\*" -ErrorAction SilentlyContinue
        }

        Invoke-MountSuite `
            -Label "mirror-$($mr.Arch)-$($cfg.Name)" `
            -ExePath $mr.Exe `
            -Arguments "/r $mirrorDir $($cfg.Args)" `
            -Destination $cfg.Dest `
            -UnmountTarget $cfg.Unmount `
            -ProbePath "$($cfg.Dest)\tmp" `
            -IfsParams $mirrorIfsParams `
            -SuiteKind 'mirror' `
            -ArchTag $mr.Arch `
            -ConfigName $cfg.Name `
            -FsTestTarget $cfg.Target
    }
}

Write-Host "=== Post-test Driver Verifier statistics ===" -ForegroundColor Cyan
Exec-External { & verifier.exe /query }

$bugchecks = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting' } -ErrorAction SilentlyContinue
if ($bugchecks) {
    $bugchecks | Format-List TimeCreated, Message | Out-String | Write-Error
    throw "BugCheck event detected in System Event Log!"
}

Write-Host "=== ALL DOKAN KERNEL + DRIVER VERIFIER TESTS PASSED (Shard=$Shard) ===" -ForegroundColor Green
