param(
    [switch]$SkipInstall,
    [ValidateSet('full', 'runtime')]
    [string]$BuildScope = 'full'
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

$installStampPath = Join-Path $repoRoot 'SignallingWebServer\state\workspace-install-lock-hash.txt'
$packageLockPath = Join-Path $repoRoot 'package-lock.json'
$rootNodeModulesPath = Join-Path $repoRoot 'node_modules'

function Get-NpmCliPath {
    $candidate = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\nodejs\npm.cmd',
        'C:\Program Files (x86)\nodejs\npm.cmd'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "npm.cmd was not found."
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RecordedInstallHash {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $value = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.ToLowerInvariant()
}

function Write-RecordedInstallHash {
    param(
        [string]$Path,
        [string]$Hash
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $Hash -Encoding ASCII
}

function Invoke-NpmStep {
    param(
        [string]$Description,
        [string[]]$Arguments
    )

    Write-Host $Description -ForegroundColor Cyan
    $npmCli = Get-NpmCliPath
    & $npmCli @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "npm $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

if (-not $SkipInstall) {
    $currentLockHash = Get-FileSha256 -Path $packageLockPath
    $recordedInstallHash = Get-RecordedInstallHash -Path $installStampPath

    $shouldInstall =
        (-not (Test-Path -LiteralPath $rootNodeModulesPath)) -or
        [string]::IsNullOrWhiteSpace($currentLockHash) -or
        [string]::IsNullOrWhiteSpace($recordedInstallHash) -or
        ($currentLockHash -ne $recordedInstallHash)

    if ($shouldInstall) {
        Invoke-NpmStep -Description "Installing workspace dependencies..." -Arguments @('ci', '--include=dev')

        if (-not [string]::IsNullOrWhiteSpace($currentLockHash)) {
            Write-RecordedInstallHash -Path $installStampPath -Hash $currentLockHash
        }
    } else {
        Write-Host "Workspace dependencies already match package-lock.json. Skipping npm ci." -ForegroundColor DarkCyan
    }
}

Invoke-NpmStep -Description "Building Common..." -Arguments @('run', 'build', '--workspace', 'Common')

Invoke-NpmStep -Description "Building Signalling..." -Arguments @('run', 'build', '--workspace', 'Signalling')

Invoke-NpmStep -Description "Building SignallingWebServer..." -Arguments @('run', 'build', '--workspace', 'SignallingWebServer')

if ($BuildScope -eq 'full') {
    Invoke-NpmStep -Description "Building Frontend library..." -Arguments @('run', 'build', '--workspace', 'Frontend/library')

    Invoke-NpmStep -Description "Building Frontend UI library..." -Arguments @('run', 'build', '--workspace', 'Frontend/ui-library')

    Invoke-NpmStep -Description "Building Frontend TypeScript implementation (player bundle)..." -Arguments @('run', 'build', '--workspace', 'Frontend/implementations/typescript')
} else {
    Write-Host "Skipping frontend library and player bundle build for runtime scope." -ForegroundColor DarkCyan
}

Write-Host "Build complete." -ForegroundColor Green
