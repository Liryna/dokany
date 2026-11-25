param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string]$SymbolsDir,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [switch]$RequireDump
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Locate kd.exe or cdb.exe from pre-installed Windows Kits Debuggers
$debuggerCandidates = @(
    'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe',
    'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
)
$debuggerExe = $null
foreach ($cand in $debuggerCandidates) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) {
        $debuggerExe = $cand
        break
    }
}
if (-not $debuggerExe) {
    foreach ($name in @('kd.exe', 'cdb.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            $debuggerExe = $cmd.Source
            break
        }
    }
}
if (-not $debuggerExe) {
    throw "Neither kd.exe nor cdb.exe was found on this runner!"
}
Write-Host "Using Windows Debugger: $debuggerExe"

$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $sevenZip -and (Test-Path 'C:\Program Files\7-Zip\7z.exe')) {
    $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
}
if (-not $sevenZip) {
    throw "7z.exe not found on this runner!"
}

$dumps = @(Get-ChildItem -Path $ResultsRoot -Recurse -Filter 'MEMORY.DMP.7z' -File -ErrorAction SilentlyContinue)
if ($dumps.Count -eq 0) {
    Write-Host "No MEMORY.DMP.7z files found under $ResultsRoot."
    if ($RequireDump) {
        throw "RequireDump was specified, but no MEMORY.DMP.7z was found!"
    }
    exit 0
}

$symCache = Join-Path ([System.IO.Path]::GetTempPath()) 'dokan-symcache'
New-Item -ItemType Directory -Force -Path $symCache | Out-Null
$symPath = "${SymbolsDir};srv*${symCache}*https://msdl.microsoft.com/download/symbols"
Write-Host "Symbol path: $symPath"

foreach ($archive in $dumps) {
    $label = Split-Path -Leaf (Split-Path -Parent $archive.FullName)
    Write-Host "=== Analyzing crash dump for [$label]: $($archive.FullName) ($([Math]::Round($archive.Length / 1MB, 1)) MB compressed) ===" -ForegroundColor Yellow

    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dmp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    try {
        & $sevenZip x -y "-o$extractDir" $archive.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "7z extraction failed with exit code $LASTEXITCODE for $($archive.FullName)"
        }
        $dmpFile = Get-ChildItem -Path $extractDir -Filter 'MEMORY.DMP' -File | Select-Object -First 1
        if (-not $dmpFile) {
            throw "MEMORY.DMP not found inside $($archive.FullName)"
        }
        Write-Host "Extracted MEMORY.DMP: $([Math]::Round($dmpFile.Length / 1MB, 1)) MB"

        $analysisTxt = Join-Path $OutputDir "bsod-analysis-${label}.txt"
        $kdScriptPath = Join-Path $extractDir 'kd_commands.txt'
        $kdScriptLines = @(
            '.reload /f dokan3.sys'
            '!analyze -v'
            '.echo === STACK ==='
            'kP 30'
            '.echo === LOCAL VARIABLES ==='
            'dv /t /i /V'
            '.echo === DOKAN3 MODULE ==='
            'lmvm dokan3'
            '.echo === DRIVER VERIFIER ==='
            '!verifier 0x1'
            'q'
        )
        [System.IO.File]::WriteAllText($kdScriptPath, ($kdScriptLines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $rawOut = @(& $debuggerExe -lines -z $dmpFile.FullName -y $symPath -cf $kdScriptPath 2>&1)
        $kdRc = $LASTEXITCODE
        $fullText = ($rawOut -join "`n")
        [System.IO.File]::WriteAllText($analysisTxt, $fullText, (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "Debugger exit code: $kdRc; saved report to $analysisTxt"
        if ($fullText -notmatch 'BUGCHECK_CODE|BugCheck') {
            Write-Host ($rawOut | Select-Object -Last 60 | Out-String)
            throw "Debugger output did not contain expected BugCheck analysis for $label!"
        }

        # Extract concise highlights for GitHub Step Summary
        $summaryLines = New-Object System.Collections.Generic.List[string]
        $summaryLines.Add("## BSOD Crash Analysis: ``$label``")
        $summaryLines.Add("")
        $summaryLines.Add("- **Dump**: ``$($archive.Name)`` ($([Math]::Round($archive.Length / 1MB, 1)) MB compressed / $([Math]::Round($dmpFile.Length / 1MB, 1)) MB uncompressed)")
        foreach ($key in @('BUGCHECK_CODE', 'BUGCHECK_P1', 'BUGCHECK_P2', 'PROCESS_NAME', 'MODULE_NAME', 'IMAGE_NAME', 'FAILURE_BUCKET_ID')) {
            $m = [regex]::Match($fullText, "(?m)^${key}:\s*(.+)$")
            if ($m.Success) {
                $summaryLines.Add("- **${key}**: ``$($m.Groups[1].Value.Trim())``")
            }
        }
        $hasDokan3 = ($fullText -match '(?i)dokan3\.sys|dokan3\s+dokan3\.pdb')
        $summaryLines.Add("- **dokan3.sys present in kernel dump**: ``$hasDokan3``")
        $summaryLines.Add("")
        $summaryLines.Add("<details><summary>Full <code>!analyze -v</code>, stack, <code>lmvm dokan3</code>, and <code>!verifier</code></summary>")
        $summaryLines.Add("")
        $summaryLines.Add('```text')
        # Keep summary under GitHub's 1MB step-summary limit (trim to last 250 lines if huge)
        $trimmed = if ($rawOut.Count -gt 250) { $rawOut | Select-Object -First 250 } else { $rawOut }
        $summaryLines.Add(($trimmed -join "`n"))
        $summaryLines.Add('```')
        $summaryLines.Add("</details>")
        $summaryLines.Add("")

        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summaryLines -join "`n")
        }

        Write-Host "=== Key Analysis Lines [$label] ===" -ForegroundColor Cyan
        $rawOut | Select-String -Pattern 'BugCheck|BUGCHECK_|PROCESS_NAME|MODULE_NAME|IMAGE_NAME|FAILURE_BUCKET_ID|dokan3|Verify Level|Verified Drivers' | ForEach-Object { Write-Host $_.Line }
    } finally {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
