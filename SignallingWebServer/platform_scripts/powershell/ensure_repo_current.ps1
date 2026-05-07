[CmdletBinding()]
param(
    [string]$RepoRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [string]$Mode = 'maintenance',
    [string]$PhaseAwsCli = '',
    [string]$PhaseRegion = '',
    [string]$PhaseInstanceId = '',
    [string]$BuildingUpdatePhase = '',
    [string]$GitSyncMode = $(if ($env:SCALEWORLD_GIT_SYNC_MODE) { $env:SCALEWORLD_GIT_SYNC_MODE } elseif ($env:SCALEWORLD_STREAMING_LANE -and $env:SCALEWORLD_STREAMING_LANE.Trim().ToLowerInvariant() -eq 'prod') { 'pinned' } else { 'upstream' }),
    [string]$GitTargetRef = $(if ($env:SCALEWORLD_GIT_TARGET_REF) { $env:SCALEWORLD_GIT_TARGET_REF } else { '' }),
    [string]$GitTargetRefParam = $(if ($env:SCALEWORLD_GIT_TARGET_REF_PARAM) { $env:SCALEWORLD_GIT_TARGET_REF_PARAM } else { '' })
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
        $safeArguments = if ($null -eq $Arguments) { @() } else { $Arguments }
        $quotedArgumentString = ($safeArguments | ForEach-Object {
            if ($_ -match '[\s"]') {
                '"{0}"' -f (($_ -replace '(\\*)"', '$1$1\"'))
            } else {
                $_
            }
        }) -join ' '

        $process = Start-Process -FilePath $AwsCli -ArgumentList $quotedArgumentString -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
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
                (ConvertTo-Json -InputObject @($tagPayload) -Compress -Depth 3),
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

function Get-AwsCliPath {
    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
        'C:\Program Files\Amazon\AWSCLI\bin\aws.exe'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "AWS CLI ('aws') was not found."
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

function Resolve-SsmRegion {
    if (-not [string]::IsNullOrWhiteSpace($env:AWS_REGION)) {
        return $env:AWS_REGION.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:AWS_DEFAULT_REGION)) {
        return $env:AWS_DEFAULT_REGION.Trim()
    }

    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
    return (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
}

function Resolve-ImdsV2Token {
    return (Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }).Trim()
}

function Resolve-Ec2InstanceId {
    param([string]$Token)

    return (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{ 'X-aws-ec2-metadata-token' = $Token }).Trim()
}

function New-RepoHeadTagContext {
    try {
        $awsCliPath = Get-AwsCliPath
        $imdsToken = Resolve-ImdsV2Token
        $region = Resolve-SsmRegion
        $instanceId = Resolve-Ec2InstanceId -Token $imdsToken
        if ([string]::IsNullOrWhiteSpace($instanceId)) {
            return $null
        }

        return [pscustomobject]@{
            AwsCliPath = $awsCliPath
            Region = $region
            InstanceId = $instanceId
            PublishScriptPath = Join-Path $PSScriptRoot 'publish_repo_head_tags.ps1'
        }
    } catch {
        Write-RepoSyncLog "Unable to initialize repo head tag publishing. $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function New-StartupRuntimeStatusContext {
    param([string]$CurrentMode)

    if (-not [string]::Equals($CurrentMode.Trim(), 'startup', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $publishScriptPath = Join-Path $PSScriptRoot 'publish_runtime_status_tags.ps1'
    $heartbeatScriptPath = Join-Path $PSScriptRoot 'runtime-status-heartbeat.ps1'
    if (-not (Test-Path -LiteralPath $publishScriptPath) -or -not (Test-Path -LiteralPath $heartbeatScriptPath)) {
        return $null
    }

    try {
        $awsCliPath = Get-AwsCliPath
        $imdsToken = Resolve-ImdsV2Token
        $region = Resolve-SsmRegion
        $instanceId = Resolve-Ec2InstanceId -Token $imdsToken
        if ([string]::IsNullOrWhiteSpace($instanceId)) {
            return $null
        }

        $heartbeatToken = [Guid]::NewGuid().ToString('N')
        $tempDirectory = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } elseif (-not [string]::IsNullOrWhiteSpace($env:TMP)) { $env:TMP } else { 'C:\Windows\Temp' }

        return [pscustomobject]@{
            AwsCliPath = $awsCliPath
            Region = $region
            InstanceId = $instanceId
            PublishScriptPath = $publishScriptPath
            HeartbeatScriptPath = $heartbeatScriptPath
            StateFilePath = Join-Path $tempDirectory ("scaleworld-boot-sync-status-$heartbeatToken.state")
            StopFilePath = Join-Path $tempDirectory ("scaleworld-boot-sync-status-$heartbeatToken.stop")
        }
    } catch {
        Write-RepoSyncLog "Unable to initialize startup runtime status publishing. $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Write-StartupRuntimeStatusState {
    param(
        [pscustomobject]$Context,
        [string]$Status,
        [string]$Source,
        [string]$Reason,
        [string]$Version,
        [string]$StatusAtUtc
    )

    if ($null -eq $Context) {
        return
    }

    @(
        "status=$Status"
        "source=$Source"
        "reason=$Reason"
        "version=$Version"
        "status_at_utc=$StatusAtUtc"
    ) | Set-Content -LiteralPath $Context.StateFilePath -Encoding ASCII
}

function Invoke-PublishRuntimeStatusScript {
    param(
        [pscustomobject]$Context,
        [string]$Status,
        [string]$Reason
    )

    if ($null -eq $Context) {
        return
    }

    $statusAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $runtimeStatusVersion = ''
    Write-StartupRuntimeStatusState -Context $Context -Status $Status -Source 'startup-script' -Reason $Reason -Version $runtimeStatusVersion -StatusAtUtc $statusAtUtc

    $publishArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $Context.PublishScriptPath,
        '-InstanceId',
        $Context.InstanceId,
        '-Region',
        $Context.Region,
        '-AwsCliPath',
        $Context.AwsCliPath,
        '-Status',
        $Status,
        '-Source',
        'startup-script',
        '-Reason',
        $Reason
    )
    if (-not [string]::IsNullOrWhiteSpace($runtimeStatusVersion)) {
        $publishArguments += @(
            '-Version',
            $runtimeStatusVersion
        )
    }
    $publishArguments += @(
        '-StatusAtUtc',
        $statusAtUtc
    )
    $publishResult = Invoke-AwsCliCapture -AwsCli 'powershell.exe' -Arguments $publishArguments

    if ($publishResult.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($publishResult.Combined)) {
            Write-RepoSyncLog "Failed to publish startup runtime status '$Status'." 'WARN'
        } else {
            Write-RepoSyncLog "Failed to publish startup runtime status '$Status'. $($publishResult.Combined)" 'WARN'
        }
    }
}

function Start-StartupRuntimeStatusHeartbeat {
    param([pscustomobject]$Context)

    if ($null -eq $Context) {
        return
    }

    if (Test-Path -LiteralPath $Context.StopFilePath) {
        Remove-Item -LiteralPath $Context.StopFilePath -Force -ErrorAction SilentlyContinue
    }

    $heartbeatArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $Context.HeartbeatScriptPath,
        '-InstanceId',
        $Context.InstanceId,
        '-Region',
        $Context.Region,
        '-AwsCliPath',
        $Context.AwsCliPath,
        '-StateFilePath',
        $Context.StateFilePath,
        '-StopFilePath',
        $Context.StopFilePath,
        '-IntervalSeconds',
        '30'
    )
    $heartbeatArgumentString = ($heartbeatArguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"{0}"' -f (($_ -replace '(\\*)"', '$1$1\"'))
        } else {
            $_
        }
    }) -join ' '

    Start-Process -FilePath 'powershell.exe' -ArgumentList $heartbeatArgumentString -WindowStyle Hidden | Out-Null
}

function Publish-RepoUpdateRuntimeStatus {
    param(
        [pscustomobject]$Context,
        [ref]$Published
    )

    if ($null -eq $Context -or $Published.Value) {
        return
    }

    Invoke-PublishRuntimeStatusScript -Context $Context -Status 'updating_infra' -Reason 'repo_update_in_progress'
    $Published.Value = $true
}

function Start-PostRepoSyncStackRelaunch {
    param(
        [string]$RepoRootPath,
        [string]$InitialHead,
        [string]$CurrentHead,
        [string]$CurrentMode
    )

    if ($CurrentMode -ne 'startup') {
        return $false
    }

    if ($env:SCALEWORLD_DISABLE_POST_SYNC_STACK_RELAUNCH -ieq 'true' -or
        $env:STACK_RELAUNCHED_AFTER_BOOT_SYNC -ieq 'true' -or
        [string]::IsNullOrWhiteSpace($InitialHead) -or
        [string]::IsNullOrWhiteSpace($CurrentHead) -or
        [string]::Equals($InitialHead, $CurrentHead, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $stackLauncherPath = Join-Path $RepoRootPath 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
    if (-not (Test-Path -LiteralPath $stackLauncherPath)) {
        Write-RepoSyncLog "Updated checkout requires stack relaunch, but stack launcher was not found at '$stackLauncherPath'." 'WARN'
        return $false
    }

    $command = 'set "STACK_ENABLE_BOOT_GIT_SYNC=false" && set "STACK_RELAUNCHED_AFTER_BOOT_SYNC=true" && call "{0}"' -f $stackLauncherPath
    Write-RepoSyncLog "Repo HEAD changed from $InitialHead to $CurrentHead. Launching fresh stack from updated checkout."
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $command) -WindowStyle Minimized | Out-Null
    return $true
}
function Stop-StartupRuntimeStatusHeartbeat {
    param([pscustomobject]$Context)

    if ($null -eq $Context) {
        return
    }

    'stop' | Set-Content -LiteralPath $Context.StopFilePath -Encoding ASCII -Force
}

function Publish-RepoHeadTag {
    param(
        [pscustomobject]$Context,
        [string]$CurrentHead,
        [string]$CurrentVersion
    )

    if ($null -eq $Context) {
        return
    }

    if (-not (Test-Path -LiteralPath $Context.PublishScriptPath)) {
        Write-RepoSyncLog "Repo head publish helper '$($Context.PublishScriptPath)' was not found." 'WARN'
        return
    }

    $publishResult = Invoke-AwsCliCapture -AwsCli 'powershell.exe' -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $Context.PublishScriptPath,
        '-InstanceId',
        $Context.InstanceId,
        '-Region',
        $Context.Region,
        '-AwsCliPath',
        $Context.AwsCliPath,
        '-CurrentRepoHead',
        $CurrentHead,
        '-CurrentVersion',
        $CurrentVersion
    )

    if ($publishResult.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($publishResult.Combined)) {
            Write-RepoSyncLog "Failed to publish current repo head '$CurrentHead'." 'WARN'
        } else {
            Write-RepoSyncLog "Failed to publish current repo head '$CurrentHead'. $($publishResult.Combined)" 'WARN'
        }
    }
}

function Resolve-PixelStreamingVersionTagValue {
    param(
        [string]$SyncMode,
        [string]$TargetRef,
        [string]$CurrentHead
    )

    if ([string]::Equals($SyncMode, 'pinned', [System.StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrWhiteSpace($TargetRef)) {
        return $TargetRef.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($CurrentHead)) {
        return ''
    }

    $normalizedHead = $CurrentHead.Trim()
    if ($normalizedHead.Length -le 12) {
        return $normalizedHead
    }

    return $normalizedHead.Substring(0, 12)
}

function Resolve-ServiceSafeGitRemoteUrl {
    param([string]$OriginUrl)

    if (-not [string]::IsNullOrWhiteSpace($env:SCALEWORLD_GIT_REMOTE_URL)) {
        return $env:SCALEWORLD_GIT_REMOTE_URL.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($OriginUrl)) {
        return ''
    }

    $trimmedUrl = $OriginUrl.Trim()
    $githubAliasPrefix = 'git@github-pixelstreaming:'
    if ($trimmedUrl.StartsWith($githubAliasPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'https://github.com/' + $trimmedUrl.Substring($githubAliasPrefix.Length)
    }

    return ''
}

function Ensure-ServiceSafeGitOriginRemote {
    param([string]$GitCli)

    $originUrl = ((& $GitCli remote get-url origin 2>$null) | Out-String).Trim()
    $safeOriginUrl = Resolve-ServiceSafeGitRemoteUrl -OriginUrl $originUrl
    if ([string]::IsNullOrWhiteSpace($safeOriginUrl) -or
        [string]::Equals($originUrl, $safeOriginUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    Write-RepoSyncLog "Updating PixelStreaming origin fetch URL for service startup from '$originUrl' to '$safeOriginUrl'."
    & $GitCli remote set-url origin $safeOriginUrl
    if ($LASTEXITCODE -ne 0) {
        throw "git remote set-url origin '$safeOriginUrl' failed."
    }
}
function Resolve-GitTargetRefValue {
    param(
        [string]$ExplicitRef,
        [string]$TargetRefParam
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRef)) {
        return $ExplicitRef.Trim()
    }

    $targetRefParams = @(
        $TargetRefParam -split '[;,]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($targetRefParams.Count -eq 0) {
        return ''
    }

    $awsCli = Get-AwsCliPath
    $region = Resolve-SsmRegion
    $lastFailure = $null

    foreach ($parameterName in $targetRefParams) {
        Write-RepoSyncLog "Resolving pinned git target ref from SSM parameter '$parameterName' in region '$region'."
        $result = Invoke-AwsCliCapture -AwsCli $awsCli -Arguments @(
            'ssm',
            'get-parameter',
            '--region', $region,
            '--name', $parameterName,
            '--query', 'Parameter.Value',
            '--output', 'text'
        )
        if ($result.ExitCode -ne 0) {
            $lastFailure = if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                "Failed to resolve pinned git target ref from SSM parameter '$parameterName'."
            }
            else {
                "Failed to resolve pinned git target ref from SSM parameter '$parameterName'. $($result.Combined)"
            }
            if ($targetRefParams.Count -gt 1) {
                Write-RepoSyncLog "$lastFailure Trying the next configured fallback parameter." -Level WARN
                continue
            }

            throw $lastFailure
        }

        $resolved = ($result.StdOut | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $lastFailure = "SSM parameter '$parameterName' did not contain a pinned git target ref."
            if ($targetRefParams.Count -gt 1) {
                Write-RepoSyncLog "$lastFailure Trying the next configured fallback parameter." -Level WARN
                continue
            }

            throw $lastFailure
        }

        return $resolved
    }

    throw ($lastFailure ?? "No configured SSM parameter contained a pinned git target ref.")
}

function Resolve-CommitFromRef {
    param(
        [string]$GitCli,
        [string]$Ref
    )

    $resolved = ((& $GitCli rev-parse "$Ref^{commit}") | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Failed to resolve git ref '$Ref'."
    }

    return $resolved
}

function Try-ResolveCommitFromRef {
    param(
        [string]$GitCli,
        [string]$Ref
    )

    if ([string]::IsNullOrWhiteSpace($Ref)) {
        return $null
    }

    $resolved = ((& $GitCli rev-parse --verify --quiet "$Ref^{commit}" 2>$null) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        return $null
    }

    return $resolved
}

function Get-PinnedRefCandidates {
    param([string]$Ref)

    $trimmedRef = $Ref.Trim()
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($trimmedRef)

    if (-not $trimmedRef.StartsWith('refs/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidates.Add("refs/tags/$trimmedRef")
        $candidates.Add("refs/remotes/origin/$trimmedRef")
        $candidates.Add("origin/$trimmedRef")
    }

    return @($candidates | Select-Object -Unique)
}

function Try-ResolvePinnedCommitFromRef {
    param(
        [string]$GitCli,
        [string]$Ref
    )

    foreach ($candidate in Get-PinnedRefCandidates -Ref $Ref) {
        $resolved = Try-ResolveCommitFromRef -GitCli $GitCli -Ref $candidate
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            if (-not [string]::Equals($candidate, $Ref.Trim(), [System.StringComparison]::Ordinal)) {
                Write-RepoSyncLog "Resolved pinned ref '$($Ref.Trim())' via '$candidate'."
            }

            return $resolved
        }
    }

    return $null
}

function Resolve-PinnedCommitFromRef {
    param(
        [string]$GitCli,
        [string]$Ref
    )

    $trimmedRef = $Ref.Trim()
    $resolved = Try-ResolvePinnedCommitFromRef -GitCli $GitCli -Ref $trimmedRef
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved
    }

    throw "Pinned git target ref '$trimmedRef' could not be resolved after fetch. Confirm the branch or tag exists on the remote and that the configured ref name is exact."
}

$gitCli = Get-GitCliPath
$buildScript = Join-Path $RepoRoot 'build-all.bat'
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "build-all.bat was not found at '$buildScript'."
}
$buildStampPath = Join-Path $RepoRoot 'SignallingWebServer\state\repo-build-head.txt'
$wilburDistPath = Join-Path $RepoRoot 'SignallingWebServer\dist\index.js'
$frontendBundlePath = Join-Path $RepoRoot 'SignallingWebServer\www\player.html'
$gitSyncModeNormalized = Normalize-GitSyncMode -Value $GitSyncMode
$gitTargetRefNormalized = Resolve-GitTargetRefValue -ExplicitRef $GitTargetRef -TargetRefParam $GitTargetRefParam
$startupRuntimeStatusContext = New-StartupRuntimeStatusContext -CurrentMode $Mode
$repoHeadTagContext = New-RepoHeadTagContext

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

function Get-ChangedFilesBetweenCommits {
    param(
        [string]$GitCli,
        [string]$FromCommit,
        [string]$ToCommit
    )

    if ([string]::IsNullOrWhiteSpace($FromCommit) -or [string]::IsNullOrWhiteSpace($ToCommit)) {
        return $null
    }

    & $GitCli cat-file -e "$FromCommit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    & $GitCli cat-file -e "$ToCommit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $output = & $GitCli diff --name-only $FromCommit $ToCommit --
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return @(
        $output |
            ForEach-Object { ($_ | Out-String).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-IsNonBuildAffectingPath {
    param([string]$Path)

    $normalized = ($Path -replace '\\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $true
    }

    if ($normalized.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    switch -Regex ($normalized) {
        '^Docs/' { return $true }
        '^BuildScripts/' { return $true }
        '^\.gitignore$' { return $true }
        '^build-all\.(bat|ps1)$' { return $true }
        '^pull-latest\.bat$' { return $true }
        '^promote-prod-(streamer-release|dark-connect-ticket)\.(bat|ps1)$' { return $true }
        '^SWupdate\.ps1$' { return $true }
        '^SignallingWebServer/platform_scripts/' { return $true }
        '^SignallingWebServer/(config\.json|peer_options\.player\.json|peer_options\.streamer\.json)$' { return $true }
        '^SignallingWebServer/(apidoc|logs)/' { return $true }
        '^Common/docs/' { return $true }
        '^Signalling/docs/' { return $true }
        '^Frontend/Docs/' { return $true }
        default { return $false }
    }
}

function Get-BuildImpactFromChangedFiles {
    param([string[]]$ChangedFiles)

    $runtimeReason = $null

    foreach ($path in $ChangedFiles) {
        $normalized = ($path -replace '\\', '/').Trim()
        if (Test-IsNonBuildAffectingPath -Path $normalized) {
            continue
        }

        if ($normalized -eq 'package.json' -or
            $normalized -eq 'package-lock.json' -or
            $normalized.StartsWith('Common/', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith('Frontend/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Scope = 'full'
                Reason = "full build required because '$normalized' changed"
            }
        }

        if ($normalized.StartsWith('Signalling/', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith('SignallingWebServer/', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ([string]::IsNullOrWhiteSpace($runtimeReason)) {
                $runtimeReason = "runtime build required because '$normalized' changed"
            }

            continue
        }

        return [pscustomobject]@{
            Scope = 'full'
            Reason = "full build required because unclassified path '$normalized' changed"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($runtimeReason)) {
        return [pscustomobject]@{
            Scope = 'runtime'
            Reason = $runtimeReason
        }
    }

    return [pscustomobject]@{
        Scope = 'none'
        Reason = 'only non-build-affecting files changed'
    }
}

Push-Location $RepoRoot
try {
    if ($startupRuntimeStatusContext) {
        Invoke-PublishRuntimeStatusScript -Context $startupRuntimeStatusContext -Status 'booting' -Reason 'git_sync_check'
        Start-StartupRuntimeStatusHeartbeat -Context $startupRuntimeStatusContext
    }

    & $gitCli rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "PixelStreaming root '$RepoRoot' is not a git repository."
    }

    Ensure-ServiceSafeGitOriginRemote -GitCli $gitCli

    $currentHead = ((& $gitCli rev-parse HEAD) | Out-String).Trim()
    $initialHead = $currentHead
    if ([string]::IsNullOrWhiteSpace($currentHead)) {
        throw 'Failed to resolve local git commit for PixelStreaming repo.'
    }

    $requiresInfraUpdateStatus = $false
    $publishedRepoUpdateStatus = $false
    $buildReasons = [System.Collections.Generic.List[string]]::new()
    $buildScope = 'none'
    $updateBuildStampWithoutBuild = $false
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
                    $requiresInfraUpdateStatus = $true
                    Write-RepoSyncLog "Discarding tracked local PixelStreaming repo changes before $Mode mode."
                    Publish-RepoUpdateRuntimeStatus -Context $startupRuntimeStatusContext -Published ([ref]$publishedRepoUpdateStatus)

                    & $gitCli reset --hard $upstreamHead
                    if ($LASTEXITCODE -ne 0) {
                        throw "git reset --hard $upstreamHead failed."
                    }
                    $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                    $trackedChanges = ''
                }

                if ($currentHead -ne $upstreamHead) {
                    $requiresInfraUpdateStatus = $true
                    Write-RepoSyncLog "Remote PixelStreaming changes detected on $upstreamBranch. Resetting local checkout to upstream before continuing."
                    Publish-RepoUpdateRuntimeStatus -Context $startupRuntimeStatusContext -Published ([ref]$publishedRepoUpdateStatus)

                    & $gitCli reset --hard $upstreamHead
                    if ($LASTEXITCODE -ne 0) {
                        throw "git reset --hard $upstreamHead failed."
                    }
                    $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                } else {
                    Write-RepoSyncLog "PixelStreaming repo already matches $upstreamBranch."
                }
            } else {
                Write-RepoSyncLog 'No upstream branch configured for PixelStreaming repo. Skipping repo pull and validating local build freshness only.' 'WARN'
                if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                    $requiresInfraUpdateStatus = $true
                    Write-RepoSyncLog "Discarding tracked local PixelStreaming repo changes without upstream before $Mode mode."
                    Publish-RepoUpdateRuntimeStatus -Context $startupRuntimeStatusContext -Published ([ref]$publishedRepoUpdateStatus)

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
                throw 'Pinned git sync mode requires SCALEWORLD_GIT_TARGET_REF or SCALEWORLD_GIT_TARGET_REF_PARAM.'
            }

            $targetHead = Try-ResolvePinnedCommitFromRef -GitCli $gitCli -Ref $gitTargetRefNormalized
            $buildStampBeforeFetch = Get-BuildStamp -Path $buildStampPath
            $buildArtifactsFreshBeforeFetch =
                -not [string]::IsNullOrWhiteSpace($targetHead) `
                -and [string]::Equals($currentHead, $targetHead, [System.StringComparison]::OrdinalIgnoreCase) `
                -and [string]::Equals($buildStampBeforeFetch, $currentHead, [System.StringComparison]::OrdinalIgnoreCase) `
                -and (Test-Path -LiteralPath $frontendBundlePath) `
                -and (Test-Path -LiteralPath $wilburDistPath)

            if ([string]::IsNullOrWhiteSpace($targetHead) -or -not [string]::IsNullOrWhiteSpace($trackedChanges) -or -not $buildArtifactsFreshBeforeFetch) {
                Write-RepoSyncLog "Fetching PixelStreaming repo before resolving pinned ref '$gitTargetRefNormalized'."
                & $gitCli fetch --prune --tags
                if ($LASTEXITCODE -ne 0) {
                    throw 'git fetch --prune --tags failed.'
                }

                $targetHead = Resolve-PinnedCommitFromRef -GitCli $gitCli -Ref $gitTargetRefNormalized
            } else {
                Write-RepoSyncLog "Pinned ref '$gitTargetRefNormalized' already matches HEAD $currentHead with fresh build artifacts. Skipping git fetch."
            }

            if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
                $requiresInfraUpdateStatus = $true
                Write-RepoSyncLog "Discarding tracked local PixelStreaming repo changes before pinned reset to '$gitTargetRefNormalized'."
                Publish-RepoUpdateRuntimeStatus -Context $startupRuntimeStatusContext -Published ([ref]$publishedRepoUpdateStatus)

                & $gitCli reset --hard $targetHead
                if ($LASTEXITCODE -ne 0) {
                    throw "git reset --hard $targetHead failed."
                }
                $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
                $trackedChanges = ''
            }

            if ($currentHead -ne $targetHead) {
                $requiresInfraUpdateStatus = $true
                Write-RepoSyncLog "Resetting local checkout to pinned ref '$gitTargetRefNormalized' ($targetHead)."
                Publish-RepoUpdateRuntimeStatus -Context $startupRuntimeStatusContext -Published ([ref]$publishedRepoUpdateStatus)

                & $gitCli reset --hard $targetHead
                if ($LASTEXITCODE -ne 0) {
                    throw "git reset --hard $targetHead failed."
                }
                $currentHead = Resolve-CommitFromRef -GitCli $gitCli -Ref 'HEAD'
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
    if (-not (Test-Path -LiteralPath $frontendBundlePath)) {
        $buildScope = 'full'
        $buildReasons.Add("frontend bundle '$frontendBundlePath' missing")
    }

    if (-not (Test-Path -LiteralPath $wilburDistPath)) {
        if ($buildScope -ne 'full') {
            $buildScope = 'runtime'
        }
        $buildReasons.Add("wilbur dist '$wilburDistPath' missing")
    }

    if ($buildStamp -ne $currentHead) {
        $changedFiles = Get-ChangedFilesBetweenCommits -GitCli $gitCli -FromCommit $buildStamp -ToCommit $currentHead
        if ($null -eq $changedFiles) {
            if ($buildScope -ne 'full') {
                $buildScope = 'full'
            }
            $buildReasons.Add("build stamp '$buildStamp' does not match HEAD '$currentHead'")
        } else {
            $buildImpact = Get-BuildImpactFromChangedFiles -ChangedFiles $changedFiles
            switch ($buildImpact.Scope) {
                'full' {
                    $buildScope = 'full'
                    $buildReasons.Add($buildImpact.Reason)
                }
                'runtime' {
                    if ($buildScope -eq 'none') {
                        $buildScope = 'runtime'
                    }
                    $buildReasons.Add($buildImpact.Reason)
                }
                'none' {
                    $updateBuildStampWithoutBuild = $true
                }
            }
        }
    }

    if ($buildScope -ne 'none') {
        $requiresInfraUpdateStatus = $true
    }

    if ($startupRuntimeStatusContext -and $buildScope -ne 'none') {
        Invoke-PublishRuntimeStatusScript -Context $startupRuntimeStatusContext -Status 'updating_infra' -Reason 'repo_build_in_progress'
    }

    if ($buildScope -ne 'none') {
        Set-OptionalUpdatePhase -Phase $BuildingUpdatePhase
        Write-RepoSyncLog ("Running build-all.bat before {0} mode with build scope '{1}' because: {2}." -f $Mode, $buildScope, ($buildReasons -join '; '))
        & $buildScript -BuildScope $buildScope
        if ($LASTEXITCODE -ne 0) {
            throw "build-all.bat failed with exit code $LASTEXITCODE."
        }

        Write-BuildStamp -Path $buildStampPath -Head $currentHead
        Write-RepoSyncLog "Recorded build stamp for HEAD $currentHead."
    } elseif ($updateBuildStampWithoutBuild) {
        Write-BuildStamp -Path $buildStampPath -Head $currentHead
        Write-RepoSyncLog "Updated build stamp to HEAD $currentHead without rebuild because only non-build-affecting files changed."
    } else {
        Write-RepoSyncLog "Build artifacts already match HEAD $currentHead. Skipping build-all.bat."
    }

    $currentVersionTagValue = Resolve-PixelStreamingVersionTagValue -SyncMode $gitSyncModeNormalized -TargetRef $gitTargetRefNormalized -CurrentHead $currentHead
    Publish-RepoHeadTag -Context $repoHeadTagContext -CurrentHead $currentHead -CurrentVersion $currentVersionTagValue

    if (Start-PostRepoSyncStackRelaunch -RepoRootPath $RepoRoot -InitialHead $initialHead -CurrentHead $currentHead -CurrentMode $Mode) {
        exit 42
    }
} catch {
    if ($startupRuntimeStatusContext) {
        Invoke-PublishRuntimeStatusScript -Context $startupRuntimeStatusContext -Status 'runtime_fault' -Reason 'repo_sync_failed'
    }

    throw
} finally {
    if ($startupRuntimeStatusContext) {
        Stop-StartupRuntimeStatusHeartbeat -Context $startupRuntimeStatusContext
    }

    Pop-Location
}
