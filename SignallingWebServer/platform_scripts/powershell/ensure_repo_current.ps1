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
$buildStampPath = Join-Path $RepoRoot 'SignallingWebServer\state\repo-build-head.txt'
$wilburDistPath = Join-Path $RepoRoot 'SignallingWebServer\dist\index.js'

function Get-BuildStamp {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $value = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Write-BuildStamp {
    param(
        [string]$Path,
        [string]$Head
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $Head -Encoding ASCII
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

    $currentHead = ((& $gitCli rev-parse HEAD) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($currentHead)) {
        throw 'Failed to resolve local git commit for PixelStreaming repo.'
    }

    $upstreamBranch = ((& $gitCli rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null) | Out-String).Trim()
    $buildReasons = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($upstreamBranch)) {
        $upstreamHead = ((& $gitCli rev-parse '@{u}') | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($upstreamHead)) {
            throw 'Failed to resolve upstream git commit for PixelStreaming repo.'
        }

        if ($currentHead -ne $upstreamHead) {
            $trackedChanges = ((& $gitCli status --porcelain --untracked-files=no) | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                throw 'Tracked local changes are present in the PixelStreaming repo. Resolve them before maintenance bootstrap can pull the latest repo.'
            }

            Write-RepoSyncLog "Remote PixelStreaming changes detected on $upstreamBranch. Pulling latest before continuing."
            & $gitCli pull --ff-only
            if ($LASTEXITCODE -ne 0) {
                throw 'git pull --ff-only failed.'
            }

            $currentHead = ((& $gitCli rev-parse HEAD) | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($currentHead)) {
                throw 'Failed to resolve local git commit after git pull.'
            }
            $buildReasons.Add("repo updated to $currentHead")
        } else {
            Write-RepoSyncLog "PixelStreaming repo already matches $upstreamBranch."
        }
    } else {
        Write-RepoSyncLog 'No upstream branch configured for PixelStreaming repo. Skipping repo pull and validating local build freshness only.' 'WARN'
    }

    $buildStamp = Get-BuildStamp -Path $buildStampPath
    if (-not (Test-Path -LiteralPath $wilburDistPath)) {
        $buildReasons.Add('wilbur dist/index.js missing')
    }
    if ($buildStamp -ne $currentHead) {
        $buildReasons.Add("build stamp '$buildStamp' does not match HEAD '$currentHead'")
    }

    if ($buildReasons.Count -gt 0) {
        Write-RepoSyncLog ("Running build-all.bat before {0} mode because: {1}." -f $Mode, ($buildReasons -join '; '))
        & $buildScript
        if ($LASTEXITCODE -ne 0) {
            throw "build-all.bat failed with exit code $LASTEXITCODE."
        }

        Write-BuildStamp -Path $buildStampPath -Head $currentHead
        Write-RepoSyncLog "Recorded build stamp for HEAD $currentHead."
    } else {
        Write-RepoSyncLog "Build artifacts already match HEAD $currentHead. Skipping build-all.bat."
    }
} finally {
    Pop-Location
}
