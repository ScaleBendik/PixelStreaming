$ErrorActionPreference = "Stop"

param(
    [switch]$SkipInstall
)

$repoRoot = $PSScriptRoot
Set-Location $repoRoot

if (-not $SkipInstall) {
    Write-Host "Installing workspace dependencies..." -ForegroundColor Cyan
    npm install --include=dev
}

Write-Host "Building Common..." -ForegroundColor Cyan
npm run build --workspace Common

Write-Host "Building Signalling..." -ForegroundColor Cyan
npm run build --workspace Signalling

Write-Host "Building SignallingWebServer..." -ForegroundColor Cyan
npm run build --workspace SignallingWebServer

Write-Host "Build complete." -ForegroundColor Green
