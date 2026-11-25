<#
.SYNOPSIS
    Prints the installer version for a CI build: <BaseVersion>.<BuildVersion padded with BuildNumber>.

.EXAMPLE
    scripts\ci\get_version.ps1 -BuildNumber 2042   # -> 3.0.0.2042 (BaseVersion 3.0.0, BuildVersion 1000)
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$BuildNumber
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$versionXml = [xml](Get-Content (Join-Path $repoRoot 'dokan_wix\version.xml'))

function Get-VersionDefine([string]$Name) {
    $define = $versionXml.Include.define | Where-Object { $_.StartsWith("$Name=") } | Select-Object -First 1
    return ($define.Split('=')[1] -replace '"', '').Trim()
}

$baseVersion = Get-VersionDefine 'BaseVersion'
$template = Get-VersionDefine 'BuildVersion'
$number = "$BuildNumber"
if ($number.Length -lt $template.Length) {
    $number = $template.Substring(0, $template.Length - $number.Length) + $number
}
Write-Output "$baseVersion.$number"
