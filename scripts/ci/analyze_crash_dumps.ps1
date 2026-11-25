<#
.SYNOPSIS
    Analyzes MEMORY.DMP.7z crash dumps collected from the CI test VMs with kd.exe.

.DESCRIPTION
    For every <DumpsRoot>\<artifact>\MEMORY.DMP.7z, runs kd.exe with dokan3.sys/dokan3.pdb from
    <SymbolsDir> plus the Microsoft symbol server, writes the full report to <OutputDir>, and adds
    a summary (bugcheck code, faulting module, full report in a collapsed section) to the job summary.
    The command set is a superset of the former AppVeyor one (!analyze -v; kp; dv /t /i /V), extended
    with !running, !locks and !stacks for hangs that the CI turns into dumps with an NMI.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$DumpsRoot,
    [Parameter(Mandatory = $true)]
    [string]$SymbolsDir,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    # Fail when no dump is found (used by the crash-capture self-test).
    [switch]$RequireDump
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$kd = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe'
if (-not (Test-Path -LiteralPath $kd -PathType Leaf)) {
    throw "kd.exe not found at $kd"
}
$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $sevenZip) {
    $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
}

$archives = @(Get-ChildItem -Path $DumpsRoot -Recurse -Filter 'MEMORY.DMP.7z' -File -ErrorAction SilentlyContinue)
if ($archives.Count -eq 0) {
    if ($RequireDump) {
        throw "No MEMORY.DMP.7z found under $DumpsRoot."
    }
    Write-Host "No MEMORY.DMP.7z found under $DumpsRoot."
    exit 0
}

$symbolCache = Join-Path $env:RUNNER_TEMP 'symbols'
$symbolPath = "$SymbolsDir;srv*$symbolCache*https://msdl.microsoft.com/download/symbols"
$kdCommands = @(
    '.reload /f dokan3.sys'
    '!analyze -v'
    '.echo ===== Stack ====='
    'kP 30'
    '.echo ===== Locals ====='
    'dv /t /i /V'
    '.echo ===== dokan3.sys ====='
    'lmvm dokan3'
    '.echo ===== Running threads (all processors) ====='
    '!running -it'
    '.echo ===== Contended locks ====='
    '!locks'
    '.echo ===== Threads with dokan3 frames ====='
    '!stacks 2 dokan'
    '.echo ===== Driver Verifier ====='
    '!verifier 0x1'
    'q'
)
# Commands go through a -cf file: inline -c strings are cut at the first '.echo', swallowing the final 'q'.
$commandFile = Join-Path $env:RUNNER_TEMP 'kd_commands.txt'
[System.IO.File]::WriteAllText($commandFile, ($kdCommands -join "`r`n") + "`r`n")

$failed = $false
foreach ($archive in $archives) {
    $label = Split-Path -Leaf (Split-Path -Parent $archive.FullName)
    Write-Host "=== Analyzing $label ($([Math]::Round($archive.Length / 1MB, 1)) MB) ===" -ForegroundColor Yellow
    $extractDir = Join-Path $env:RUNNER_TEMP "dump-$label"
    & $sevenZip x -y "-o$extractDir" $archive.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "7z failed to extract $($archive.FullName)"
    }
    $dump = Join-Path $extractDir 'MEMORY.DMP'

    $report = @(& $kd -lines -z $dump -y $symbolPath -i $SymbolsDir -cf $commandFile 2>&1 |
        Where-Object { $_ -notmatch 'not present in the dump file' })
    $reportText = $report -join "`n"
    $reportFile = Join-Path $OutputDir "$label.txt"
    [System.IO.File]::WriteAllText($reportFile, $reportText)
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($reportText -notmatch 'BUGCHECK_CODE') {
        Write-Host ($report | Select-Object -Last 40 | Out-String)
        Write-Host "::error::kd.exe did not produce a bugcheck analysis for $label"
        $failed = $true
        continue
    }

    $summary = @("## Crash dump: ``$label``", '')
    foreach ($key in @('BUGCHECK_CODE', 'BUGCHECK_P1', 'BUGCHECK_P2', 'BUGCHECK_P3', 'BUGCHECK_P4', 'PROCESS_NAME', 'MODULE_NAME', 'IMAGE_NAME', 'FAILURE_BUCKET_ID')) {
        $match = [regex]::Match($reportText, "(?m)^${key}:\s*(.+)$")
        if ($match.Success) {
            $summary += "- **${key}**: ``$($match.Groups[1].Value.Trim())``"
        }
    }
    # Keep the step summary well under GitHub's 1 MiB limit; the full report is in the artifact.
    $summary += '', '<details><summary>kd.exe report (first 400 lines)</summary>', '', '```text'
    $summary += ($report | Select-Object -First 400)
    $summary += '```', '</details>', ''
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summary -join "`n")
    }
    $report | Select-String -Pattern '^(BUGCHECK_CODE|MODULE_NAME|IMAGE_NAME|FAILURE_BUCKET_ID):' | ForEach-Object { Write-Host $_.Line }
}

if ($failed) {
    exit 1
}
