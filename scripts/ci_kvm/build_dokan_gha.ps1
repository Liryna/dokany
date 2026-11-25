param(
    [ValidateSet('Release', 'Debug')]
    [string]$BuildConfig = 'Release',
    [string]$BuildNumber = '1',
    [string]$OutputDir = 'ci-artifacts',
    [string]$ReleaseDir = 'ci-release',
    [string]$FsTestDepsCacheDir = '',
    [switch]$RequireFuse
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

. .\scripts\build_helper.ps1
Add-VisualStudio-Path
$buildCmd = (Get-Command msbuild.exe -CommandType Application | Select-Object -First 1).Source
Write-Host "Using MSBuild: $buildCmd"

# 1. Import public Dokan test-signing certificate (without running bcdedit, which fails under Secure Boot)
Write-Host "Importing Dokan test-signing certificates..."
Import-Certificate -FilePath .\cert\DokanCA.cer -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath .\cert\DokanCA.cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
Import-PfxCertificate -FilePath .\cert\DokanSign.pfx -CertStoreLocation 'Cert:\CurrentUser\My' | Out-Null

# 2. Ensure WDK NuGet packages are restored
if (!(Test-Path -Path '.\packages\Microsoft.Windows.WDK.x64.*')) {
    Write-Host "Restoring WDK NuGet packages..."
    Exec-External { & nuget restore .\sys\packages.config -PackagesDirectory .\packages }
}

# 3. Compute version matching AppVeyor convention
$xmlversion = [xml](Get-Content "$repoRoot\dokan_wix\version.xml")
$baseVersion = (($xmlversion.Include.define | Where-Object { $_.StartsWith('BaseVersion=') }).Split('=')[1] -replace '"', '').Trim()
$buildVerDef = (($xmlversion.Include.define | Where-Object { $_.StartsWith('BuildVersion=') }).Split('=')[1] -replace '"', '').Trim()
$paddedBuild = $BuildNumber.Trim()
if ($paddedBuild.Length -lt $buildVerDef.Length) {
    $mmVersion = $buildVerDef.Substring(0, $buildVerDef.Length - $paddedBuild.Length) + $paddedBuild
} else {
    $mmVersion = $paddedBuild
}
$installerVersion = "$baseVersion.$mmVersion"
Write-Host "Installer version: $installerVersion"

(Get-Content "$repoRoot\CHANGELOG.md") -replace '[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,4}', $installerVersion | Set-Content "$repoRoot\CHANGELOG.md"

# 4. Resolve signtool.exe (prefer Windows Kits, fallback to WDK NuGet)
$signtool = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\10.0.*\x64\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
if (!$signtool) {
    $signtool = Get-ChildItem "$repoRoot\packages\Microsoft.Windows.SDK.CPP.x64.*\c\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
}
if (!$signtool) {
    throw "signtool.exe not found"
}
Write-Host "Using signtool: $($signtool.FullName)"
$env:Path += ";$($signtool.DirectoryName)"
$env:CERTISSUER = 'DokanCA'
$env:ADDITIONALCERT = "$repoRoot\cert\DokanCA.cer"
$env:SIGNTOOL = $signtool.FullName

# 5. Update assembly versions
Push-Location "$repoRoot\dokan_wix"
try {
    Exec-External { & $buildCmd 'SetAssemblyVersion.sln' '/m' '/p:Configuration=Release' '/p:Platform=Any CPU' }
    Exec-External { & .\SetAssemblyVersion\bin\Release\SetAssemblyVersion.exe ..\CHANGELOG.md version.xml ..\ }
} finally {
    Pop-Location
}

# 6. Build Dokan (Win32, x64, ARM64 + Cygwin + MSYS2 dokan_fuse)
$buildParts = @('win')
$hasCygwinTools = Test-Path -LiteralPath 'C:\cygwin64\bin\bash.exe'
$hasMsys2Tools = (Test-Path -LiteralPath 'C:\msys64\ucrt64\bin\gcc.exe') -and (Test-Path -LiteralPath 'C:\msys64\mingw32\bin\gcc.exe') -and (Test-Path -LiteralPath 'C:\msys64\usr\bin\make.exe')
if ($RequireFuse) {
    if (-not $hasCygwinTools) {
        throw "RequireFuse set, but Cygwin (C:\cygwin64\bin\bash.exe) was not found."
    }
    if (-not $hasMsys2Tools) {
        throw "RequireFuse set, but MSYS2 toolchains (ucrt64/gcc, mingw32/gcc, usr/bin/make) were not found."
    }
}
if ($hasCygwinTools) {
    $buildParts += 'cygwin'
}
if ($hasMsys2Tools) {
    $buildParts += 'msys2'
}
Write-Host "Building Dokan parts: $($buildParts -join ', ')"
Exec-External { & .\scripts\build.ps1 -BuildPart $buildParts -Configurations $BuildConfig }

# 7. Sign binaries with public Dokan test cert
Exec-External { & .\cert\dokan-sign.ps1 }

# 8. Build WiX v4 installer
Push-Location "$repoRoot\dokan_wix"
try {
    Get-ChildItem .\* -Include @('*.wixproj', '*.vcxproj') -Recurse | ForEach-Object {
        Exec-External { & nuget restore $_.FullName -SolutionDirectory . }
    }
    $hasCygwin = ($buildParts -contains 'cygwin')
    $hasMsys2 = ($buildParts -contains 'msys2')
    $vXml = Get-Content version.xml
    $vXml = $vXml -replace 'BuildCygwin="(true|false)"', "BuildCygwin=`"$($hasCygwin.ToString().ToLowerInvariant())`""
    $vXml = $vXml -replace 'BuildMsys2="(true|false)"', "BuildMsys2=`"$($hasMsys2.ToString().ToLowerInvariant())`""
    $vXml = $vXml -replace 'Compressed="no"', 'Compressed="yes"'
    Set-Content version.xml $vXml

    Exec-External { & $buildCmd 'Dokan_WiX.sln' '/m' "/p:Configuration=$BuildConfig" '/p:Platform=Mixed Platforms' }
} finally {
    Pop-Location
}

# 9. Pre-build fsx.exe (Liryna/fstools) so test VMs do not need Visual Studio
$fstoolsDir = Join-Path $repoRoot 'ci-fstools'
if (!(Test-Path $fstoolsDir)) {
    Exec-External { & git clone -q https://github.com/Liryna/fstools.git $fstoolsDir }
}
Push-Location $fstoolsDir
try {
    Exec-External { & git reset --hard 9e378a7745a7dcb6fbfc1f649975e7a47c8f952e }
    Exec-External { & $buildCmd '.\winfstest.sln' '/m' '/p:Configuration=Release' '/p:Platform=x64' }
} finally {
    Pop-Location
}

# 10. Auto-detect and build dokan_fstest.exe (PR #1365+) with static CRT (/MT) if present
$buildFsTestScript = Join-Path $repoRoot 'scripts\build_fstest.ps1'
$hasDokanFsTest = (Test-Path -LiteralPath $buildFsTestScript -PathType Leaf) -and (Test-Path -LiteralPath "$repoRoot\tests\fstest\CMakeLists.txt" -PathType Leaf)
if ($hasDokanFsTest) {
    Write-Host "Detected tests/fstest; building dokan_fstest.exe ($BuildConfig, static CRT)..."
    $fsBuildArgs = @{
        Configuration   = $BuildConfig
        VerifyStaticCrt = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($FsTestDepsCacheDir)) {
        $fsBuildArgs['CacheDir'] = $FsTestDepsCacheDir
    }
    & $buildFsTestScript @fsBuildArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "scripts\build_fstest.ps1 failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Host "tests/fstest not present on this branch; skipping dokan_fstest.exe build."
}

# 11. Stage CI handoff artifacts and AppVeyor-parity release packages
$outAbs = Join-Path $repoRoot $OutputDir
$relAbs = Join-Path $repoRoot $ReleaseDir
New-Item -ItemType Directory -Force -Path $outAbs, $relAbs | Out-Null

$setupExe = "$repoRoot\dokan_wix\Bootstrapper\bin\x86\$BuildConfig\DokanSetup.exe"
Copy-Item -LiteralPath $setupExe -Destination "$outAbs\DokanSetup.exe" -Force
Copy-Item -LiteralPath "$fstoolsDir\src\fsx\fsx.exe" -Destination "$outAbs\fsx.exe" -Force
Copy-Item -LiteralPath "$repoRoot\x64\$BuildConfig\Driver\dokan3.pdb" -Destination "$outAbs\dokan3.pdb" -Force
Copy-Item -LiteralPath "$repoRoot\x64\$BuildConfig\Driver\dokan3.sys" -Destination "$outAbs\dokan3.sys" -Force
Copy-Item -LiteralPath "$repoRoot\cert\DokanCA.cer" -Destination "$outAbs\DokanCA.cer" -Force

if ($hasDokanFsTest) {
    $fsTestExePath = "$repoRoot\tests\fstest\build\bin\$BuildConfig\dokan_fstest.exe"
    if (-not (Test-Path -LiteralPath $fsTestExePath -PathType Leaf)) {
        throw "Expected dokan_fstest.exe not found at $fsTestExePath"
    }
    Copy-Item -LiteralPath $fsTestExePath -Destination "$outAbs\dokan_fstest.exe" -Force
    $baselinesSrc = "$repoRoot\tests\fstest\baselines"
    if (Test-Path -LiteralPath $baselinesSrc -PathType Container) {
        Copy-Item -LiteralPath $baselinesSrc -Destination "$outAbs\baselines" -Recurse -Force
    }
}

# Build AppVeyor-parity versioned release artifacts (DokanSetup-<version>.exe + dokan-<version>.zip)
$versionedSetup = Join-Path $relAbs "DokanSetup-${installerVersion}.exe"
$versionedZip = Join-Path $relAbs "dokan-${installerVersion}.zip"
Copy-Item -LiteralPath $setupExe -Destination $versionedSetup -Force
if (Test-Path -LiteralPath $versionedZip) {
    Remove-Item -LiteralPath $versionedZip -Force
}
$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $sevenZip -and (Test-Path 'C:\Program Files\7-Zip\7z.exe')) {
    $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
}
if (-not $sevenZip) {
    throw "7z.exe not found; cannot build dokan-${installerVersion}.zip"
}
Write-Host "Packaging $versionedZip (Win32, x64, ARM64)..."
Exec-External { & $sevenZip a -tzip $versionedZip Win32 x64 ARM64 | Out-Null }

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_version=$installerVersion"
}

Write-Host "Staged CI artifacts in ${outAbs}:"
Get-ChildItem -LiteralPath $outAbs | Format-Table Name, Length
Write-Host "Staged release artifacts in ${relAbs}:"
Get-ChildItem -LiteralPath $relAbs | Format-Table Name, Length
