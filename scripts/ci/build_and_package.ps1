<#
.SYNOPSIS
    Builds, test-signs and packages Dokan for CI (replaces the former AppVeyor "All" job).

.DESCRIPTION
    - Builds Win32/x64/ARM64 (and Cygwin + MSYS2 dokan_fuse when the toolchains are installed).
    - Test-signs all binaries with the public Dokan test certificate (cert/DokanSign.pfx).
    - Builds the WiX installer bundle (DokanSetup.exe).
    - Stages:
        * $ReleaseDir: DokanSetup-<version>.exe, dokan-<version>.zip
        * $PayloadDir: what the VM test jobs need (DokanSetup.exe, dokan3.sys and dokan3.pdb for crash analysis)
    The test tools (dokan_fstest.exe, fsx.exe) are built in parallel by build_test_tools.ps1.
#>
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [Parameter(Mandatory = $true)]
    [int]$BuildNumber,
    [string]$PayloadDir = 'ci-payload',
    [string]$ReleaseDir = 'ci-release',
    # Fail instead of silently skipping dokan_fuse when Cygwin/MSYS2 toolchains are missing.
    [switch]$RequireFuse
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

. .\scripts\build_helper.ps1
Add-VisualStudio-Path
$msbuild = (Get-Command msbuild.exe -CommandType Application | Select-Object -First 1).Source
Write-Host "Using MSBuild: $msbuild"

# 1. Trust the public Dokan test certificate. cert/dokan-import.ps1 is not used because it also
#    runs 'bcdedit /set testsigning on', which is neither needed nor allowed on hosted runners.
Write-Host 'Importing Dokan test-signing certificates...'
Import-Certificate -FilePath .\cert\DokanCA.cer -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath .\cert\DokanCA.cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
Import-PfxCertificate -FilePath .\cert\DokanSign.pfx -CertStoreLocation 'Cert:\CurrentUser\My' | Out-Null

# 2. Compute the installer version and stamp it into CHANGELOG.md (read by SetAssemblyVersion).
$installerVersion = & "$PSScriptRoot\get_version.ps1" -BuildNumber $BuildNumber
Write-Host "Installer version: $installerVersion"

(Get-Content "$repoRoot\CHANGELOG.md") -replace '[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,4}', $installerVersion | Set-Content "$repoRoot\CHANGELOG.md"

# 3. Locate signtool.exe (Windows SDK first, WDK NuGet package as fallback) for cert\dokan-sign.ps1.
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.*\x64\signtool.exe' -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) {
    $signtool = Get-ChildItem "$repoRoot\packages\Microsoft.Windows.SDK.CPP.x64.*\c\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
}
if (-not $signtool) {
    throw 'signtool.exe not found'
}
Write-Host "Using signtool: $($signtool.FullName)"
$env:Path += ";$($signtool.DirectoryName)"
$env:CERTISSUER = 'DokanCA'
$env:ADDITIONALCERT = "$repoRoot\cert\DokanCA.cer"
$env:SIGNTOOL = $signtool.FullName

# 4. Stamp assembly versions.
Push-Location "$repoRoot\dokan_wix"
try {
    Exec-External { & $msbuild 'SetAssemblyVersion.sln' '/m' '/p:Configuration=Release' '/p:Platform=Any CPU' }
    Exec-External { & .\SetAssemblyVersion\bin\Release\SetAssemblyVersion.exe ..\CHANGELOG.md version.xml ..\ }
} finally {
    Pop-Location
}

# 5. Build Dokan (Win32, x64, ARM64) and dokan_fuse (Cygwin x64, MSYS2 MINGW32 + UCRT64).
$hasCygwin = Test-Path -LiteralPath 'C:\cygwin64\bin\bash.exe'
$hasMsys2 = (Test-Path -LiteralPath 'C:\msys64\ucrt64\bin\gcc.exe') -and
    (Test-Path -LiteralPath 'C:\msys64\mingw32\bin\gcc.exe') -and
    (Test-Path -LiteralPath 'C:\msys64\usr\bin\make.exe')
if ($RequireFuse -and -not ($hasCygwin -and $hasMsys2)) {
    throw "Cygwin (found: $hasCygwin) and MSYS2 MINGW32/UCRT64 toolchains (found: $hasMsys2) are required for dokan_fuse."
}
$buildParts = @('win')
if ($hasCygwin) { $buildParts += 'cygwin' }
if ($hasMsys2) { $buildParts += 'msys2' }
Write-Host "Building Dokan parts: $($buildParts -join ', ')"
Exec-External { & .\scripts\build.ps1 -BuildPart $buildParts -Configurations $Configuration }

# 6. Test-sign all binaries.
Exec-External { & .\cert\dokan-sign.ps1 }

# 7. Build the WiX installer bundle.
Push-Location "$repoRoot\dokan_wix"
try {
    Get-ChildItem .\* -Include @('*.wixproj', '*.vcxproj') -Recurse | ForEach-Object {
        Exec-External { & nuget restore $_.FullName -SolutionDirectory . }
    }
    $versionXmlText = Get-Content version.xml
    $versionXmlText = $versionXmlText -replace 'BuildCygwin="(true|false)"', "BuildCygwin=`"$($hasCygwin.ToString().ToLowerInvariant())`""
    $versionXmlText = $versionXmlText -replace 'BuildMsys2="(true|false)"', "BuildMsys2=`"$($hasMsys2.ToString().ToLowerInvariant())`""
    $versionXmlText = $versionXmlText -replace 'Compressed="no"', 'Compressed="yes"'
    Set-Content version.xml $versionXmlText
    Exec-External { & $msbuild 'Dokan_WiX.sln' '/m' "/p:Configuration=$Configuration" '/p:Platform=Mixed Platforms' }
} finally {
    Pop-Location
}

# 8. Stage release artifacts (same names as the former AppVeyor artifacts).
$payloadAbs = Join-Path $repoRoot $PayloadDir
$releaseAbs = Join-Path $repoRoot $ReleaseDir
foreach ($dir in @($payloadAbs, $releaseAbs)) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $sevenZip) {
    $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
}

$setupExe = "$repoRoot\dokan_wix\Bootstrapper\bin\x86\$Configuration\DokanSetup.exe"
Copy-Item -LiteralPath $setupExe -Destination (Join-Path $releaseAbs "DokanSetup-$installerVersion.exe")
Exec-External { & $sevenZip a -tzip (Join-Path $releaseAbs "dokan-$installerVersion.zip") Win32 x64 ARM64 | Out-Null }

# 9. Stage the VM test payload.
Copy-Item -LiteralPath $setupExe -Destination "$payloadAbs\DokanSetup.exe"
Copy-Item -LiteralPath "$repoRoot\x64\$Configuration\Driver\dokan3.sys" -Destination "$payloadAbs\dokan3.sys"
Copy-Item -LiteralPath "$repoRoot\x64\$Configuration\Driver\dokan3.pdb" -Destination "$payloadAbs\dokan3.pdb"

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_version=$installerVersion"
}

Write-Host "Release artifacts ($releaseAbs):"
Get-ChildItem -LiteralPath $releaseAbs | Format-Table Name, Length
Write-Host "VM test payload ($payloadAbs):"
Get-ChildItem -LiteralPath $payloadAbs -Recurse -File | Format-Table FullName, Length
