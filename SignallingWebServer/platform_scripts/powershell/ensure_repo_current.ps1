[CmdletBinding()]
param(
    [string]$RepoRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [string]$Mode = 'maintenance',
    [string]$PhaseAwsCli = '',
    [string]$PhaseRegion = '',
    [string]$PhaseInstanceId = '',
    [string]$BuildingUpdatePhase = '',
    [string]$GitSyncMode = $(if ($env:SCALEWORLD_GIT_SYNC_MODE) { $env:SCALEWORLD_GIT_SYNC_MODE } elseif ($env:SCALEWORLD_STREAMING_LANE -and $env:SCALEWORLD_STREAMING_LANE.Trim().ToLowerInvariant() -eq 'prod') { 'pinned' } else { 'upstream' }),
    [string]$GitTargetRef = $(if ($env:SCALEWORLD_GIT_TARGET_REF) { $env:SCALEWORLD_GIT_TARGET_REF } else { '' })
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

function Normalize-TagValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $normalized = ($Value -replace '\s+', ' ').Trim()
    if ($normalized.Length -gt 256) {
        return $normalized.Substring(0, 256)
    }

    return $normalized
}

function Invoke-AwsCliCapture {
    param(
        [string]$AwsCli,
        [string[]]$Arguments
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath $AwsCli -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath) {
            (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
        } else {
            ''
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
        } else {
            ''
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Combined = (@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-OptionalUpdatePhase {
    param([string]$Phase)

    if ([string]::IsNullOrWhiteSpace($Phase)) {
        return
    }

    $missingPhaseTarget =
        [string]::IsNullOrWhiteSpace($PhaseAwsCli) -or
        [string]::IsNullOrWhiteSpace($PhaseRegion) -or
        [string]::IsNullOrWhiteSpace($PhaseInstanceId)

    if ($missingPhaseTarget) {
        return
    }

    try {
        $tagPayload = @(
            @{
                Key = 'ScaleWorldUpdatePhase'
                Value = Normalize-TagValue $Phase
            }
        )

        $tagPayloadPath = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText(
                $tagPayloadPath,
                ($tagPayload | ConvertTo-Json -Compress -Depth 3),
                (New-Object System.Text.UTF8Encoding($false))
            )
            $args = @(
                'ec2',
                'create-tags',
                '--region', $PhaseRegion,
                '--resources', $PhaseInstanceId,
                '--tags', ("file://{0}" -f $tagPayloadPath)
            )
            $result = Invoke-AwsCliCapture -AwsCli $PhaseAwsCli -Arguments $args
            if ($result.ExitCode -ne 0) {
                if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                    Write-RepoSyncLog "Failed to publish update phase '$Phase' while preparing $Mode mode." 'WARN'
                } else {
                    Write-RepoSyncLog "Failed to publish update phase '$Phase' while preparing $Mode mode. $($result.Combined)" 'WARN'
                }
            }
        } finally {
            Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-RepoSyncLog "Failed to publish update phase '$Phase' while preparing $Mode mode. $($_.Exception.Message)" 'WARN'
    }
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

function Normalize-GitSyncMode {
    param([string]$Value)

    $normalized = if ([string]::IsNullOrWhiteSpace($Value)) {
        'upstream'
    } else {
        $Value.Trim().ToLowerInvariant()
    }

    if ($normalized -notin @('upstream', 'pinned', 'off')) {
        throw "Unsupported git sync mode '$Value'. Expected upstream, pinned, or off."
    }

    return $normalized
}

function Resolve-CommitFromRef {
    param(
        [string]$GitCli,
        [string]$Ref
    )

    $resolved = ((& $GitCli rev-parse $Ref) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Failed to resolve git ref '$Ref'."
    }

    return $resolved
}

$gitCli = Get-GitCliPath
$buildScript = Join-Path $RepoRoot 'build-all.bat'
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "build-all.bat was not found at '$buildScript'."
}
$buildStampPath = Join-Path $RepoRoot 'SignallingWebServer\state\repo-build-head.txt'
$wilburDistPath = Join-Path $RepoRoot 'SignallingWebServer\dist\index.js'
$gitSyncModeNormalized = Normalize-GitSyncMode -Value $GitSyncMode
$gitTargetRefNormalized = if ([string]::IsNullOrWhiteSpace($GitTargetRef)) { '' } else { $GitTargetRef.Trim() }

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

    $currentHead = ((& $gitCli rev-parse HEAD) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($currentHead)) {
        throw 'Failed to resolve local git commit for PixelStreaming repo.'
    }

    $buildReasons = [System.Collections.Generic.List[string]]::new()
    $trackedChanges = ((& $gitCli status --porcelain --untracked-files=no) | Out-String).Trim()

    Write-RepoSyncLog "Applying git sync mode '$gitSyncModeNormalized' before $Mode mode."

    switch ($gitSyncModeNormalized) {
        'upstream' {
            Write-RepoSyncLog "Fetching PixelStreaming repo before $Mode mode."
            & $gitCli fetch --prune
            if ($LASTEXITCODE -ne 0) {
                throw 'git fetch --prune failed.'
            }

            $upstreamBranch = ((& $gitCli rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null) | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($upstreamBranch)) {
                $upstreamHead = Resolve-CommitFromRef -GitCli $gitCli -Ref '@{u}'

                if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                    Write-RepoSyncLog "Discarding tracked local PixelStreaming repo changes before $Mode mode."
                    & $gitCli reset --hard $upstreamHead
                    if ($LASTEXITCODE -ne 0) {
                        throw "git reset --hard $upstreamHead failed."
                    }
                    $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                    $trackedChanges = ''
                }

                if ($currentHead -ne $upstreamHead) {
                    Write-RepoSyncLog "Remote PixelStreaming changes detected on $upstreamBranch. Resetting local checkout to upstream before continuing."
                    & $gitCli reset --hard $upstreamHead
                    if ($LASTEXITCODE -ne 0) {
                        throw "git reset --hard $upstreamHead failed."
                    }
                    $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                    $buildReasons.Add("repo aligned to upstream commit $currentHead")
                } else {
                    Write-RepoSyncLog "PixelStreaming repo already matches $upstreamBranch."
                }
            } else {
                Write-RepoSyncLog 'No upstream branch configured for PixelStreaming repo. Skipping repo pull and validating local build freshness only.' 'WARN'
                if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                    Write-RepoSyncLog "Discarding tracked local PixelStreaming repo changes without upstream before $Mode mode."
                    & $gitCli reset --hard $currentHead
                    if ($LASTEXITCODE -ne 0) {
                        throw "git reset --hard $currentHead failed."
                    }
                    $trackedChanges = ''
                }
            }
        }
        'pinned' {
            if ([string]::IsNullOrWhiteSpace($gitTargetRefNormalized)) {
                throw 'Pinned git sync mode requires SCALEWORLD_GIT_TARGET_REF.'
            }

            Write-RepoSyncLog "Fetching PixelStreaming repo before resolving pinned ref '$gitTargetRefNormalized'."
            & $gitCli fetch --prune --tags
            if ($LASTEXITCODE -ne 0) {
                throw 'git fetch --prune --tags failed.'
            }

            $targetHead = Resolve-CommitFromRef -GitCli $gitCli -Ref $gitTargetRefNormalized

            if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                Write-RepoSyncLog "Discarding tracked local PixelStreaming repo changes before pinned reset to '$gitTargetRefNormalized'."
                & $gitCli reset --hard $targetHead
                if ($LASTEXITCODE -ne 0) {
                    throw "git reset --hard $targetHead failed."
                }
                $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                $trackedChanges = ''
            }

            if ($currentHead -ne $targetHead) {
                Write-RepoSyncLog "Resetting local checkout to pinned ref '$gitTargetRefNormalized' ($targetHead)."
                & $gitCli reset --hard $targetHead
                if ($LASTEXITCODE -ne 0) {
                    throw "git reset --hard $targetHead failed."
                }
                $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                $buildReasons.Add("repo aligned to pinned ref '$gitTargetRefNormalized' ($currentHead)")
            } else {
                Write-RepoSyncLog "PixelStreaming repo already matches pinned ref '$gitTargetRefNormalized' ($targetHead)."
            }
        }
        'off' {
            if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                throw 'Tracked local changes are present while SCALEWORLD_GIT_SYNC_MODE=off.'
            }

            Write-RepoSyncLog "Git sync is disabled for $Mode mode. Using current checkout at HEAD $currentHead."
        }
    }

    $buildStamp = Get-BuildStamp -Path $buildStampPath
    if (-not (Test-Path -LiteralPath $wilburDistPath)) {
        $buildReasons.Add('wilbur dist/index.js missing')
    }
    if ($buildStamp -ne $currentHead) {
        $buildReasons.Add("build stamp '$buildStamp' does not match HEAD '$currentHead'")
    }

    if ($buildReasons.Count -gt 0) {
        Set-OptionalUpdatePhase -Phase $BuildingUpdatePhase
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
