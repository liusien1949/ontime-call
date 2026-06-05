[CmdletBinding()]
param(
    [string]$OutputRoot = '',
    [string]$PackageName = 'ontime-call-portable'
)

$ErrorActionPreference = 'Stop'

$projectRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot 'dist'
}

$packageRoot = Join-Path $OutputRoot $PackageName
$zipPath = Join-Path $OutputRoot ($PackageName + '.zip')

$requiredFiles = @(
    'meal-reminder.ps1',
    'meal-reminder.vbs',
    'README.md'
)

foreach ($file in $requiredFiles) {
    $source = Join-Path $projectRoot $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing required file: $file"
    }
}

$assetsRoot = Join-Path $projectRoot 'assets'
if (-not (Test-Path -LiteralPath $assetsRoot -PathType Container)) {
    throw 'Missing required directory: assets'
}

if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

foreach ($file in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $file) -Destination $packageRoot -Force
}

Copy-Item -LiteralPath $assetsRoot -Destination $packageRoot -Recurse -Force
$cacheDir = Join-Path $packageRoot 'assets\themes\cache'
if (Test-Path -LiteralPath $cacheDir) {
    Remove-Item -LiteralPath $cacheDir -Recurse -Force
}

Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force

Write-Host ("Portable package created: {0}" -f $zipPath)
Write-Host ("Portable folder created: {0}" -f $packageRoot)
