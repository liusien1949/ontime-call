[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'dist'),
    [string]$PackageName = 'ontime-call-portable'
)

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
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

$launcher = Get-ChildItem -LiteralPath $projectRoot -Filter *.bat -File | Select-Object -First 1
if ($null -eq $launcher) {
    throw 'Missing launcher batch file.'
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
Copy-Item -LiteralPath $launcher.FullName -Destination $packageRoot -Force

Copy-Item -LiteralPath (Join-Path $projectRoot 'assets') -Destination $packageRoot -Recurse -Force
$cacheDir = Join-Path $packageRoot 'assets\themes\cache'
if (Test-Path -LiteralPath $cacheDir) {
    Remove-Item -LiteralPath $cacheDir -Recurse -Force
}

Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force

Write-Host ("Portable package created: {0}" -f $zipPath)
Write-Host ("Portable folder created: {0}" -f $packageRoot)
