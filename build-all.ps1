param(
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
Set-Location $repoRoot

if (-not $SkipInstall) {
    Write-Host "Installing workspace dependencies..." -ForegroundColor Cyan
    npm ci --include=dev
}

Write-Host "Building Common..." -ForegroundColor Cyan
npm run build --workspace Common

Write-Host "Building Signalling..." -ForegroundColor Cyan
npm run build --workspace Signalling

Write-Host "Building SignallingWebServer..." -ForegroundColor Cyan
npm run build --workspace SignallingWebServer

Write-Host "Building Frontend library..." -ForegroundColor Cyan
npm run build --workspace Frontend/library

Write-Host "Building Frontend UI library..." -ForegroundColor Cyan
npm run build --workspace Frontend/ui-library

Write-Host "Building Frontend TypeScript implementation (player bundle)..." -ForegroundColor Cyan
npm run build --workspace Frontend/implementations/typescript

Write-Host "Build complete." -ForegroundColor Green
