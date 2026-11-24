$ErrorActionPreference = 'Stop'

function Exec-External {
    param([Parameter(Position = 0, Mandatory = $true)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command returned non-zero exit code ${LASTEXITCODE}: $Command"
    }
}

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host "=== Guest OS: $($cv.ProductName) (Build $($cv.CurrentBuildNumber).$($cv.UBR), Arch $($env:PROCESSOR_ARCHITECTURE)) ===" -ForegroundColor Cyan

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

$dokanLib = [System.Environment]::GetEnvironmentVariable('DokanLibrary3', 'Machine')
if ([string]::IsNullOrWhiteSpace($dokanLib)) {
    throw "DokanLibrary3 machine environment variable not found after install"
}
$env:DokanLibrary3 = $dokanLib
$dokanCtl = Join-Path $dokanLib 'dokanctl.exe'
$fsxExe = 'C:\ci\fsx.exe'
$runIfsTest = 'C:\ci\run_ifstest.ps1'

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
    & $dokanCtl /u $MountPoint | Out-Null
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
        [string[]]$IfsParams
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

# 1. MemFS (x64 + x86)
foreach ($entry in @(
    @{ Label = 'memfs-x64-drive'; Exe = "$dokanLib\sample\memfs\memfs.exe" },
    @{ Label = 'memfs-x86-drive'; Exe = "$dokanLib\x86\sample\memfs\memfs.exe" }
)) {
    Invoke-MountSuite `
        -Label $entry.Label `
        -ExePath $entry.Exe `
        -Arguments '/l M' `
        -Destination 'M:' `
        -UnmountTarget 'M' `
        -ProbePath 'M:\' `
        -IfsParams $memfsIfsParams
}

# 2. Mirror (x64 all 6 mount configs + x86 drive & netUnc)
$mirrorConfigs = @(
    @{ Name = 'drive';                Args = '/l M';              Dest = 'M:';            Unmount = 'M' },
    @{ Name = 'dirJunction';          Args = '/l C:\DokanMount';  Dest = 'C:\DokanMount'; Unmount = 'C:\DokanMount' },
    @{ Name = 'driveRemovable';       Args = '/l M /m';           Dest = 'M:';            Unmount = 'M' },
    @{ Name = 'driveMntMgr';          Args = '/l M /o';           Dest = 'M:';            Unmount = 'M' },
    @{ Name = 'driveRemovableMntMgr'; Args = '/l M /o /m';        Dest = 'M:';            Unmount = 'M' },
    @{ Name = 'netUnc';               Args = '/l M /n \myfs\dokan'; Dest = '\\myfs\dokan'; Unmount = 'M' }
)

$mirrorRuns = @(
    @{ Arch = 'x64'; Exe = "$dokanLib\sample\mirror\mirror.exe";     Configs = $mirrorConfigs },
    @{ Arch = 'x86'; Exe = "$dokanLib\x86\sample\mirror\mirror.exe"; Configs = ($mirrorConfigs | Where-Object { $_.Name -in @('drive', 'netUnc') }) }
)

foreach ($mr in $mirrorRuns) {
    foreach ($cfg in $mr.Configs) {
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
            -IfsParams $mirrorIfsParams
    }
}

Write-Host "=== Post-test Driver Verifier statistics ===" -ForegroundColor Cyan
Exec-External { & verifier.exe /query }

$bugchecks = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting' } -ErrorAction SilentlyContinue
if ($bugchecks) {
    $bugchecks | Format-List TimeCreated, Message | Out-String | Write-Error
    throw "BugCheck event detected in System Event Log!"
}

Write-Host "=== ALL DOKAN KERNEL + DRIVER VERIFIER TESTS PASSED ===" -ForegroundColor Green
