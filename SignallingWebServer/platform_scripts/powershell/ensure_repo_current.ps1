[CmdletBinding()]
param(
    [string]$RepoRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [string]$Mode = 'maintenance'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-RepoSyncLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [repo-sync] $Message"
}

function Get-GitCliPath {
    $candidate = Get-Command git -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "Git ('git') was not found."
}

$gitCli = Get-GitCliPath
$buildScript = Join-Path $RepoRoot 'build-all.bat'
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "build-all.bat was not found at '$buildScript'."
}

Push-Location $RepoRoot
try {
    & $gitCli rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "PixelStreaming root '$RepoRoot' is not a git repository."
    }

    Write-RepoSyncLog "Fetching PixelStreaming repo before $Mode mode."
    & $gitCli fetch --prune
    if ($LASTEXITCODE -ne 0) {
        throw 'git fetch --prune failed.'
    }

    $upstreamBranch = ((& $gitCli rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($upstreamBranch)) {
        Write-RepoSyncLog 'No upstream branch configured for PixelStreaming repo. Skipping repo sync/build.' 'WARN'
        return
    }

    $currentHead = ((& $gitCli rev-parse HEAD) | Out-String).Trim()
    $upstreamHead = ((& $gitCli rev-parse '@{u}') | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($currentHead) -or [string]::IsNullOrWhiteSpace($upstreamHead)) {
        throw 'Failed to resolve local or upstream git commit for PixelStreaming repo.'
    }

    if ($currentHead -eq $upstreamHead) {
        Write-RepoSyncLog "PixelStreaming repo already matches $upstreamBranch."
        return
    }

    $trackedChanges = ((& $gitCli status --porcelain --untracked-files=no) | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
        throw 'Tracked local changes are present in the PixelStreaming repo. Resolve them before maintenance bootstrap can pull the latest repo.'
    }

    Write-RepoSyncLog "Remote PixelStreaming changes detected on $upstreamBranch. Pulling latest before continuing."
    & $gitCli pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        throw 'git pull --ff-only failed.'
    }

    Write-RepoSyncLog 'Running build-all.bat after repo sync.'
    & $buildScript
    if ($LASTEXITCODE -ne 0) {
        throw "build-all.bat failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
