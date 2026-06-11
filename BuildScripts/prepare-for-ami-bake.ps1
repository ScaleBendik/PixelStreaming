[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallBasePath = $(if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }),
    [string]$BootstrapRepoPath = '',
    [string]$RuntimeRootPath = '',
    [string]$TargetCommit = '',
    [string]$TargetRef = '',
    [string]$ExpectedInstanceName = '',
    [switch]$UseScriptCheckoutCommit,
    [switch]$SkipBootstrapSync,
    [switch]$SkipProcessStop,
    [switch]$SkipTransientCleanup,
    [switch]$SkipDesiredStateReset,
    [switch]$SkipRuntimeCacheCleanup,
    [switch]$SkipArtifactQueueCleanup,
    [switch]$SkipVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CurrentProcessId = $PID
$script:CurrentParentProcessId = $null

try {
    $currentProcess = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop
    $script:CurrentParentProcessId = [int]$currentProcess.ParentProcessId
} catch {
    $script:CurrentParentProcessId = $null
}

function Write-BakePrepLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [bake-prep] $Message"
}

function Resolve-DefaultPath {
    param(
        [string]$Value,
        [string]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    return $Value
}

function Get-GitPath {
    $candidate = Get-Command git.exe -ErrorAction SilentlyContinue
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

    throw "Git ('git.exe') was not found."
}

function Get-AwsCliPath {
    $candidate = Get-Command aws.exe -ErrorAction SilentlyContinue
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

    throw "AWS CLI ('aws.exe') was not found."
}

function Get-InstanceIdentityDocument {
    try {
        $token = Invoke-RestMethod `
            -Method Put `
            -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' } `
            -TimeoutSec 3

        return Invoke-RestMethod `
            -Method Get `
            -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' `
            -Headers @{ 'X-aws-ec2-metadata-token' = $token } `
            -TimeoutSec 3
    } catch {
        throw "Could not read EC2 instance identity document: $($_.Exception.Message)"
    }
}

function Assert-ExpectedInstanceName {
    param([string]$ExpectedName)

    if ([string]::IsNullOrWhiteSpace($ExpectedName)) {
        return
    }

    $identity = Get-InstanceIdentityDocument
    $awsCli = Get-AwsCliPath
    $tagValue = & $awsCli ec2 describe-tags `
        --region ([string]$identity.region) `
        --filters ("Name=resource-id,Values={0}" -f ([string]$identity.instanceId)) 'Name=key,Values=Name' `
        --query 'Tags[0].Value' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read EC2 Name tag for instance '$($identity.instanceId)'."
    }

    $actualName = (($tagValue | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($actualName) -or $actualName -eq 'None') {
        throw "Instance '$($identity.instanceId)' does not have a Name tag; expected '$ExpectedName'."
    }

    if (-not [string]::Equals($actualName, $ExpectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing AMI bake preparation on instance '$actualName' ($($identity.instanceId)); expected '$ExpectedName'."
    }

    Write-BakePrepLog "Verified expected source instance '$actualName' ($($identity.instanceId))."
}

function Invoke-Git {
    param(
        [string]$RepoPath,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $git = Get-GitPath
    & $git -C $RepoPath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git -C '$RepoPath' $($Arguments -join ' ') failed with exit code $exitCode."
    }

    return $exitCode
}

function Get-GitOutput {
    param(
        [string]$RepoPath,
        [string[]]$Arguments
    )

    $git = Get-GitPath
    $output = & $git -C $RepoPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git -C '$RepoPath' $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return (($output | Out-String).Trim())
}

function Get-ScriptCheckoutInfo {
    $scriptCheckoutRoot = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path -LiteralPath (Join-Path $scriptCheckoutRoot '.git'))) {
        throw "Cannot use script checkout commit because '$scriptCheckoutRoot' is not a git checkout."
    }

    $head = Get-GitOutput -RepoPath $scriptCheckoutRoot -Arguments @('rev-parse', 'HEAD')
    $ref = Get-GitOutput -RepoPath $scriptCheckoutRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    if ([string]::Equals($ref, 'HEAD', [System.StringComparison]::OrdinalIgnoreCase)) {
        $ref = ''
    }

    return [pscustomobject]@{
        Root = $scriptCheckoutRoot
        Head = $head
        Ref = $ref
    }
}

function Get-RuntimeBundleMetadata {
    param([string]$RuntimeRoot)

    $metadataPath = Join-Path $RuntimeRoot 'runtime-bundle-metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        throw "Runtime bundle metadata was not found at '$metadataPath'."
    }

    return Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function New-SafeBranchName {
    param([string]$Value)

    $name = if ([string]::IsNullOrWhiteSpace($Value)) { 'runtime-source' } else { $Value.Trim() }
    $name = $name -replace '^refs/heads/', ''
    $name = $name -replace '[^A-Za-z0-9._/-]', '-'
    $name = $name.Trim('/').Trim()

    if ([string]::IsNullOrWhiteSpace($name)) {
        return 'runtime-source'
    }

    return $name
}

function Sync-BootstrapCheckout {
    param(
        [string]$RepoPath,
        [string]$Commit,
        [string]$Ref
    )

    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
        throw "Bootstrap repo '$RepoPath' is not a git checkout."
    }

    $currentHead = Get-GitOutput -RepoPath $RepoPath -Arguments @('rev-parse', 'HEAD')
    Write-BakePrepLog "Bootstrap checkout current HEAD: $currentHead"
    Write-BakePrepLog "Bootstrap checkout target HEAD: $Commit"

    if ([string]::Equals($currentHead, $Commit, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-BakePrepLog 'Bootstrap checkout already matches the runtime source commit.'
        return
    }

    $backupBranch = 'pre-bake-bootstrap-backup-{0}' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
    if ($PSCmdlet.ShouldProcess($RepoPath, "create backup branch '$backupBranch'")) {
        Invoke-Git -RepoPath $RepoPath -Arguments @('branch', $backupBranch, 'HEAD') | Out-Null
        Write-BakePrepLog "Created bootstrap backup branch '$backupBranch'."
    }

    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        if ($PSCmdlet.ShouldProcess($RepoPath, "fetch origin $Ref")) {
            Invoke-Git -RepoPath $RepoPath -Arguments @('fetch', 'origin', $Ref) | Out-Null
        }
    } elseif ($PSCmdlet.ShouldProcess($RepoPath, 'fetch origin')) {
        Invoke-Git -RepoPath $RepoPath -Arguments @('fetch', 'origin') | Out-Null
    }

    $branchName = New-SafeBranchName -Value $Ref
    if ($PSCmdlet.ShouldProcess($RepoPath, "checkout/reset '$branchName' to $Commit")) {
        Invoke-Git -RepoPath $RepoPath -Arguments @('checkout', '-B', $branchName, $Commit) | Out-Null
        Invoke-Git -RepoPath $RepoPath -Arguments @('reset', '--hard', $Commit) | Out-Null
    }
}

function Test-BootstrapProvisioningScript {
    param([string]$RepoPath)

    $scriptPath = Join-Path $RepoPath 'SignallingWebServer\platform_scripts\powershell\invoke_provisioning_mode.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Provisioning script was not found at '$scriptPath'."
    }

    $content = Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop
    if (-not $content.Contains('function Set-ProvisioningInstanceTags')) {
        throw "Provisioning script '$scriptPath' does not contain Set-ProvisioningInstanceTags."
    }

    if (-not $content.Contains('Clear-ProvisioningUpdatePhaseTag')) {
        throw "Provisioning script '$scriptPath' does not clear stale ScaleWorldUpdatePhase."
    }

    if ($content.Contains('Key=$Key,Value=$normalizedValue')) {
        throw "Provisioning script '$scriptPath' still contains AWS CLI tag shorthand."
    }

    Write-BakePrepLog "Verified fixed provisioning script at '$scriptPath'."
}

function Test-RuntimeLaunchRoot {
    param([string]$RuntimeRoot)

    $requiredPaths = @(
        'runtime-bundle-metadata.json',
        'BuildScripts\prepare-for-ami-bake.ps1',
        'BuildScripts\prepare-scaleworld-s4-for-ami-bake.bat',
        'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat',
        'SignallingWebServer\platform_scripts\powershell\invoke_provisioning_mode.ps1',
        'SignallingWebServer\platform_scripts\powershell\invoke_update_mode.ps1',
        'SignallingWebServer\platform_scripts\powershell\install_pixelstreaming_runtime.ps1',
        'SignallingWebServer\platform_scripts\powershell\watchdog.ps1'
    )

    foreach ($relativePath in $requiredPaths) {
        $scriptPath = Join-Path $RuntimeRoot $relativePath
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Runtime artifact launch root '$RuntimeRoot' is missing required bake/startup file '$relativePath'."
        }
    }

    Write-BakePrepLog "Verified runtime artifact launch root at '$RuntimeRoot'."
}

function Test-BakePrepScripts {
    param([string]$RepoPath)

    $requiredPaths = @(
        'BuildScripts\prepare-for-ami-bake.ps1',
        'BuildScripts\prepare-scaleworld-s4-for-ami-bake.bat'
    )

    foreach ($relativePath in $requiredPaths) {
        $path = Join-Path $RepoPath $relativePath
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Bake-prep script '$path' is missing after bootstrap sync. The selected target commit does not contain the AMI bake tooling."
        }
    }

    Write-BakePrepLog "Verified AMI bake-prep tooling in '$RepoPath'."
}

function Stop-StreamerStackProcesses {
    $matches = @(
        Get-CimInstance Win32_Process | Where-Object {
            $processId = [int]$_.ProcessId
            if ($processId -eq $script:CurrentProcessId -or
                ($script:CurrentParentProcessId -and $processId -eq $script:CurrentParentProcessId)) {
                return $false
            }

            $name = [string]$_.Name
            $commandLine = [string]$_.CommandLine

            if ($commandLine -like '*ProgramData\Amazon\SSM\InstanceData*') {
                return $false
            }

            if ($name -like 'ScaleWorld*.exe') {
                return $true
            }

            if ($name -eq 'node.exe' -and $commandLine -like '*PixelStreaming*SignallingWebServer*') {
                return $true
            }

            if ($name -eq 'cmd.exe' -and (
                    $commandLine -like '*start_dev_turn.bat*' -or
                    $commandLine -like '*start_watchdog.bat*' -or
                    $commandLine -like '*start_streamer_stack.bat*' -or
                    $commandLine -like '*start_unreal.bat*')) {
                return $true
            }

            if ($name -eq 'powershell.exe' -and (
                    $commandLine -like '*watchdog.ps1*' -or
                    $commandLine -like '*start_scaleworld.ps1*' -or
                    $commandLine -like '*start_watchdog.bat*' -or
                    $commandLine -like '*invoke_update_mode.ps1*' -or
                    $commandLine -like '*invoke_provisioning_mode.ps1*')) {
                return $true
            }

            return $false
        }
    )

    foreach ($match in $matches) {
        if ($PSCmdlet.ShouldProcess("PID $($match.ProcessId)", "stop $($match.Name)")) {
            try {
                Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
                Write-BakePrepLog "Stopped $($match.Name) PID=$($match.ProcessId)."
            } catch {
                Write-BakePrepLog "Failed to stop $($match.Name) PID=$($match.ProcessId): $($_.Exception.Message)" 'WARN'
            }
        }
    }

    Start-Sleep -Seconds 3
}

function Remove-FileIfPresent {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'remove transient bake file')) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-BakePrepLog "Removed '$Path'."
    }
}

function Clear-DirectoryChildren {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'create empty bake directory')) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-BakePrepLog "Created '$Path'."
        }

        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'clear transient bake directory contents')) {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction Stop
        Write-BakePrepLog "Cleared '$Path'."
    }
}

function Clear-TransientBakeState {
    param(
        [string]$InstallRoot,
        [string]$BootstrapRoot,
        [string]$RuntimeRoot
    )

    $stateRoot = Join-Path $InstallRoot 'state'
    $transientFiles = @(
        (Join-Path $RuntimeRoot 'SignallingWebServer\state\streamer-health.json'),
        (Join-Path $BootstrapRoot 'SignallingWebServer\state\streamer-health.json'),
        (Join-Path $stateRoot 'streamer-health.json'),
        (Join-Path $stateRoot 'update-mode-trace.log'),
        (Join-Path $stateRoot 'runtime-prepare.stdout.log'),
        (Join-Path $stateRoot 'runtime-prepare.stderr.log'),
        (Join-Path $stateRoot 'runtime-install.stdout.log'),
        (Join-Path $stateRoot 'runtime-install.stderr.log'),
        (Join-Path $stateRoot 'update-prepare.stdout.log'),
        (Join-Path $stateRoot 'update-prepare.stderr.log'),
        (Join-Path $stateRoot 'provisioning-runtime-install-result.json'),
        (Join-Path $stateRoot 'runtime-install-result.json'),
        (Join-Path $stateRoot 'update-result.json')
    )

    foreach ($file in $transientFiles) {
        Remove-FileIfPresent -Path $file
    }
}

function Clear-BakeCaches {
    param([string]$InstallRoot)

    $stateRoot = Join-Path $InstallRoot 'state'
    if (-not $SkipRuntimeCacheCleanup) {
        Clear-DirectoryChildren -Path (Join-Path $stateRoot 'runtime-updates')
    }

    if (-not $SkipArtifactQueueCleanup) {
        Clear-DirectoryChildren -Path (Join-Path $stateRoot 'session-artifact-queue')
        Clear-DirectoryChildren -Path (Join-Path $stateRoot 'session-screenshot-artifact-queue')
    }
}

function Reset-InstanceAgentDesiredStateForBake {
    param([string]$InstallRoot)

    $stateRoot = Join-Path $InstallRoot 'state'
    $desiredStatePath = Join-Path $stateRoot 'instance-agent-desired-state.json'
    $desiredState = [ordered]@{
        warmHoldEnabled = $false
        drainEnabled = $false
        shutdownRequested = $false
        policyVersion = 'bake-default'
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        receivedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    if ($PSCmdlet.ShouldProcess($desiredStatePath, 'write neutral instance-agent desired state for AMI bake')) {
        if (-not (Test-Path -LiteralPath $stateRoot)) {
            New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        }

        [System.IO.File]::WriteAllText(
            $desiredStatePath,
            (ConvertTo-Json -InputObject $desiredState -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-BakePrepLog "Wrote neutral bake desired state to '$desiredStatePath'."
    }
}

function Get-DirectorySizeBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $files = @(
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer }
    )

    if ($files.Count -eq 0) {
        return 0
    }

    return [long](($files | Measure-Object -Property Length -Sum).Sum)
}

function Write-FinalSummary {
    param(
        [string]$InstallRoot,
        [string]$BootstrapRoot,
        [string]$RuntimeRoot
    )

    Write-BakePrepLog 'Final bake-prep summary:'
    foreach ($path in @(
            $BootstrapRoot,
            $RuntimeRoot,
            (Join-Path $InstallRoot 'WindowsNoEditor'),
            (Join-Path $InstallRoot 'releases'),
            (Join-Path $InstallRoot 'state')
        )) {
        if (Test-Path -LiteralPath $path) {
            $sizeGb = [Math]::Round((Get-DirectorySizeBytes -Path $path) / 1GB, 3)
            Write-BakePrepLog ("  {0} size={1} GB" -f $path, $sizeGb)
        } else {
            Write-BakePrepLog "  $path missing" 'WARN'
        }
    }

    try {
        $remaining = @(
            Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $processId = [int]$_.ProcessId
                if ($processId -eq $script:CurrentProcessId -or
                    ($script:CurrentParentProcessId -and $processId -eq $script:CurrentParentProcessId)) {
                    return $false
                }

                $name = [string]$_.Name
                $commandLine = [string]$_.CommandLine

                if ($commandLine -like '*ProgramData\Amazon\SSM\InstanceData*') {
                    return $false
                }

                if ($name -like 'ScaleWorld*.exe') {
                    return $true
                }

                if ($name -eq 'node.exe' -and $commandLine -like '*PixelStreaming*SignallingWebServer*') {
                    return $true
                }

                if ($name -eq 'cmd.exe' -and (
                        $commandLine -like '*start_dev_turn.bat*' -or
                        $commandLine -like '*start_watchdog.bat*' -or
                        $commandLine -like '*start_streamer_stack.bat*' -or
                        $commandLine -like '*start_unreal.bat*')) {
                    return $true
                }

                if ($name -eq 'powershell.exe' -and (
                        $commandLine -like '*watchdog.ps1*' -or
                        $commandLine -like '*start_scaleworld.ps1*' -or
                        $commandLine -like '*start_watchdog.bat*' -or
                        $commandLine -like '*invoke_update_mode.ps1*' -or
                        $commandLine -like '*invoke_provisioning_mode.ps1*')) {
                    return $true
                }

                return $false
            }
        )

        if ($remaining.Count -gt 0) {
            $summary = ($remaining | ForEach-Object { "$($_.Name) PID=$($_.ProcessId)" }) -join ', '
            Write-BakePrepLog "Remaining PixelStreaming-related processes: $summary" 'WARN'
        } else {
            Write-BakePrepLog 'No remaining PixelStreaming stack processes detected.'
        }
    } catch {
        Write-BakePrepLog "Could not inspect remaining processes: $($_.Exception.Message)" 'WARN'
    }
}

$installRoot = (Resolve-DefaultPath -Value $InstallBasePath -DefaultValue 'C:\PixelStreaming').TrimEnd('\')
$bootstrapRoot = Resolve-DefaultPath -Value $BootstrapRepoPath -DefaultValue (Join-Path $installRoot 'PixelStreaming')
$runtimeRoot = Resolve-DefaultPath -Value $RuntimeRootPath -DefaultValue (Join-Path $installRoot 'PixelStreaming')

Write-BakePrepLog "Install root: $installRoot"
Write-BakePrepLog "Launch root: $bootstrapRoot"
Write-BakePrepLog "Runtime root: $runtimeRoot"

Assert-ExpectedInstanceName -ExpectedName $ExpectedInstanceName

$runtimeMetadata = Get-RuntimeBundleMetadata -RuntimeRoot $runtimeRoot
$runtimeRootIsArtifact = Test-Path -LiteralPath (Join-Path $runtimeRoot 'runtime-bundle-metadata.json') -PathType Leaf
$useScriptCheckoutTarget = $UseScriptCheckoutCommit -and (-not $runtimeRootIsArtifact)
$scriptCheckoutInfo = if ($UseScriptCheckoutCommit -and $runtimeRootIsArtifact) {
    Write-BakePrepLog 'Ignoring -UseScriptCheckoutCommit because the runtime launch root is an artifact, not a git checkout.' 'WARN'
    $null
} elseif ($useScriptCheckoutTarget) {
    Get-ScriptCheckoutInfo
} else {
    $null
}

$resolvedTargetCommit = if (-not [string]::IsNullOrWhiteSpace($TargetCommit)) {
    $TargetCommit.Trim()
} elseif ($useScriptCheckoutTarget) {
    [string]$scriptCheckoutInfo.Head
} else {
    [string]$runtimeMetadata.pixelStreamingRepoCommit
}

$resolvedTargetRef = if (-not [string]::IsNullOrWhiteSpace($TargetRef)) {
    $TargetRef.Trim()
} elseif ($useScriptCheckoutTarget) {
    [string]$scriptCheckoutInfo.Ref
} else {
    [string]$runtimeMetadata.sourceRef
}

if ([string]::IsNullOrWhiteSpace($resolvedTargetCommit)) {
    throw 'Target commit was not provided and runtime metadata did not contain pixelStreamingRepoCommit.'
}

Write-BakePrepLog "Runtime bundle: $($runtimeMetadata.bundleId)"
Write-BakePrepLog "Runtime metadata source commit: $($runtimeMetadata.pixelStreamingRepoCommit)"
Write-BakePrepLog "Runtime metadata source ref: $($runtimeMetadata.sourceRef)"
if ($useScriptCheckoutTarget) {
    Write-BakePrepLog "Using script checkout commit from '$($scriptCheckoutInfo.Root)' as bootstrap target."
}

Write-BakePrepLog "Bootstrap target commit: $resolvedTargetCommit"
Write-BakePrepLog "Bootstrap target ref: $resolvedTargetRef"

if ($runtimeRootIsArtifact) {
    Write-BakePrepLog 'Skipping bootstrap git sync because the runtime artifact is the launch root.'
} elseif (-not $SkipBootstrapSync) {
    Sync-BootstrapCheckout -RepoPath $bootstrapRoot -Commit $resolvedTargetCommit -Ref $resolvedTargetRef
}

if (-not $SkipVerification) {
    if ($runtimeRootIsArtifact) {
        Test-RuntimeLaunchRoot -RuntimeRoot $runtimeRoot
    } else {
        Test-BootstrapProvisioningScript -RepoPath $bootstrapRoot
        Test-BakePrepScripts -RepoPath $bootstrapRoot
    }
}

if (-not $SkipProcessStop) {
    Stop-StreamerStackProcesses
}

if (-not $SkipTransientCleanup) {
    Clear-TransientBakeState -InstallRoot $installRoot -BootstrapRoot $bootstrapRoot -RuntimeRoot $runtimeRoot
}

if (-not $SkipDesiredStateReset) {
    Reset-InstanceAgentDesiredStateForBake -InstallRoot $installRoot
}

Clear-BakeCaches -InstallRoot $installRoot
Write-FinalSummary -InstallRoot $installRoot -BootstrapRoot $bootstrapRoot -RuntimeRoot $runtimeRoot
Write-BakePrepLog 'AMI bake preparation completed.'
