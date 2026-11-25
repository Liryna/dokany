<#
.SYNOPSIS
    Builds the file system test tools for CI: dokan_fstest.exe (tests/fstest) and fsx.exe (Liryna/fstools).

.DESCRIPTION
    Independent of the Dokan build, so CI runs it in its own job in parallel.
    Stages:
        * $OutputDir\fstest: dokan_fstest.exe, baselines\ and license files
        * $OutputDir\fsx.exe
        * $ReleaseDir\dokan-fstest-<version>.zip (contents of $OutputDir\fstest)
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$BuildNumber,
    [string]$OutputDir = 'ci-test-tools',
    [string]$ReleaseDir = 'ci-release-fstest',
    [string]$FsTestDepsCacheDir = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

. .\scripts\build_helper.ps1
Add-VisualStudio-Path
$msbuild = (Get-Command msbuild.exe -CommandType Application | Select-Object -First 1).Source

# Keep in sync with $fstoolsRevision in samples/memfs_test.ps1 and samples/mirror_test.ps1.
$fstoolsRevision = '9e378a7745a7dcb6fbfc1f649975e7a47c8f952e'
$version = & "$PSScriptRoot\get_version.ps1" -BuildNumber $BuildNumber

# 1. dokan_fstest.exe: static CRT, Server 2016 import gate, self-tests.
$fsTestArgs = @{ Configuration = 'Release'; VerifyStaticCrt = $true }
if (-not [string]::IsNullOrWhiteSpace($FsTestDepsCacheDir)) {
    $fsTestArgs['CacheDir'] = $FsTestDepsCacheDir
}
& .\scripts\build_fstest.ps1 @fsTestArgs
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "scripts\build_fstest.ps1 failed with exit code $LASTEXITCODE"
}

# 2. fsx.exe, so the test VMs do not need Visual Studio.
$fstoolsDir = Join-Path $repoRoot 'build\fstools'
if (-not (Test-Path -LiteralPath $fstoolsDir)) {
    Exec-External { & git clone -q https://github.com/Liryna/fstools.git $fstoolsDir }
}
Push-Location $fstoolsDir
try {
    Exec-External { & git reset -q --hard $fstoolsRevision }
    Exec-External { & $msbuild '.\winfstest.sln' '/m' '/p:Configuration=Release' '/p:Platform=x64' }
} finally {
    Pop-Location
}

# 3. Stage the tools and the dokan-fstest release zip (same layout as the former AppVeyor artifact).
$outputAbs = Join-Path $repoRoot $OutputDir
$releaseAbs = Join-Path $repoRoot $ReleaseDir
foreach ($dir in @($outputAbs, $releaseAbs)) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$fsTestStage = Join-Path $outputAbs 'fstest'
New-Item -ItemType Directory -Force -Path $fsTestStage | Out-Null
Copy-Item -LiteralPath "$repoRoot\tests\fstest\build\bin\Release\dokan_fstest.exe" -Destination $fsTestStage
Copy-Item -LiteralPath "$repoRoot\tests\fstest\baselines" -Destination $fsTestStage -Recurse
Copy-Item -LiteralPath "$repoRoot\tests\fstest\LICENSE" -Destination "$fsTestStage\LICENSE"
Copy-Item -LiteralPath "$repoRoot\tests\fstest\build\_deps\googletest-src\LICENSE" -Destination "$fsTestStage\LICENSE-googletest.txt"
Copy-Item -LiteralPath "$repoRoot\tests\fstest\LICENSE-nlohmann-json.txt" -Destination "$fsTestStage\LICENSE-nlohmann-json.txt"
Copy-Item -LiteralPath "$fstoolsDir\src\fsx\fsx.exe" -Destination "$outputAbs\fsx.exe"

$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $sevenZip) {
    $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
}
Exec-External { & $sevenZip a -tzip (Join-Path $releaseAbs "dokan-fstest-$version.zip") "$fsTestStage\*" | Out-Null }

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$version"
}
Get-ChildItem -LiteralPath $outputAbs, $releaseAbs -Recurse -File | Format-Table FullName, Length
