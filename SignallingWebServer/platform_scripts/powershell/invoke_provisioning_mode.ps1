[CmdletBinding()]
param(
    [int]$BootstrapTimeoutSeconds = $(if ($env:SCALEWORLD_PROVISIONING_BOOTSTRAP_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_PROVISIONING_BOOTSTRAP_TIMEOUT_SECONDS } else { 900 }),
    [int]$DetectionTimeoutSeconds = $(if ($env:SCALEWORLD_PROVISIONING_DETECTION_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_PROVISIONING_DETECTION_TIMEOUT_SECONDS } else { 90 }),
    [int]$RetryDelaySeconds = $(if ($env:SCALEWORLD_PROVISIONING_BOOTSTRAP_RETRY_DELAY_SECONDS) { [int]$env:SCALEWORLD_PROVISIONING_BOOTSTRAP_RETRY_DELAY_SECONDS } else { 15 })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ProvisioningLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [provisioning-mode] $Message"
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

function Get-InstanceIdentity {
    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
    return [pscustomobject]@{
        InstanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
        Region = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
    }
}

function Get-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId
    )

    $json = & $AwsCli ec2 describe-tags --region $Region --filters "Name=resource-id,Values=$InstanceId" "Name=key,Values=ScaleWorld*" --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to describe EC2 tags for $InstanceId."
    }

    $document = ($json | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $map = @{}
    foreach ($tag in @($document.Tags)) {
        $map[[string]$tag.Key] = [string]$tag.Value
    }

    return $map
}

function Get-ProvisioningTagValue {
    param(
        [hashtable]$Tags,
        [string]$Key
    )

    $value = [string]$Tags[$Key]
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }

    return $value.Trim()
}

function Normalize-ProvisioningTagValue {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $normalizedValue = $Value.Trim()
    if ($normalizedValue.Length -gt 256) {
        $normalizedValue = $normalizedValue.Substring(0, 256)
    }

    return $normalizedValue
}

function Set-ProvisioningInstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [hashtable]$Tags
    )

    if (-not $Tags -or $Tags.Count -eq 0) {
        return
    }

    $tagPayload = foreach ($key in $Tags.Keys) {
        $normalizedValue = Normalize-ProvisioningTagValue ([string]$Tags[$key])
        if ([string]::IsNullOrWhiteSpace($normalizedValue)) {
            continue
        }

        @{
            Key = [string]$key
            Value = $normalizedValue
        }
    }

    if ($null -eq $tagPayload -or @($tagPayload).Count -eq 0) {
        return
    }

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            (ConvertTo-Json -InputObject @($tagPayload) -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        & $AwsCli ec2 create-tags --region $Region --resources $InstanceId --tags ("file://{0}" -f $tagPayloadPath)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set EC2 tags for $InstanceId."
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ProvisioningInstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [string[]]$Keys
    )

    if (-not $Keys -or $Keys.Count -eq 0) {
        return
    }

    $tagPayload = foreach ($key in $Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        @{
            Key = $key.Trim()
        }
    }

    if ($null -eq $tagPayload -or @($tagPayload).Count -eq 0) {
        return
    }

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            (ConvertTo-Json -InputObject @($tagPayload) -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        & $AwsCli ec2 delete-tags --region $Region --resources $InstanceId --tags ("file://{0}" -f $tagPayloadPath)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete EC2 tags for $InstanceId."
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-ProvisioningRuntimeIdentityTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [string]$ManifestKey,
        [pscustomobject]$InstallResult
    )

    Set-ProvisioningInstanceTags -AwsCli $AwsCli -Region $Region -InstanceId $InstanceId -Tags @{
        ScaleWorldPixelStreamingRuntimeManifestKey = $ManifestKey
        ScaleWorldPixelStreamingRuntimeBundleId = ([string]$InstallResult.BundleId)
        ScaleWorldPixelStreamingRuntimeArtifactKey = ([string]$InstallResult.RuntimeZipKey)
        ScaleWorldPixelStreamingRuntimeSourceCommit = ([string]$InstallResult.SourceCommit)
        ScaleWorldPixelStreamingRuntimeContractVersion = ([string]$InstallResult.ContractVersion)
        ScaleWorldPixelStreamingVersion = ([string]$InstallResult.BundleId)
        ScaleWorldPixelStreamingUpdateCapabilities = 'pixelstreaming_runtime,combined_runtime_unreal'
        ScaleWorldPixelStreamingDeliveryMode = 'runtime_artifact'
        ScaleWorldLastUpdatedAtUtc = ((Get-Date).ToUniversalTime().ToString('o'))
    }
}

function Clear-ProvisioningUpdatePhaseTag {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId
    )

    try {
        Remove-ProvisioningInstanceTags -AwsCli $AwsCli -Region $Region -InstanceId $InstanceId -Keys @('ScaleWorldUpdatePhase')
    } catch {
        Write-ProvisioningLog "Provisioning bootstrap completed, but failed to clear ScaleWorldUpdatePhase: $($_.Exception.Message)" 'WARN'
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return ''
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }

    return ([string]$property.Value).Trim()
}

function Test-FatalBootstrapError {
    param([string]$Message)

    $fatalFragments = @(
        "AWS CLI ('aws') was not found.",
        "Git ('git') was not found.",
        'build-all.bat was not found',
        'is not a git repository',
        'Tracked local changes are present',
        'ensure_repo_current.ps1 was not found',
        'install_pixelstreaming_runtime.ps1 was not found',
        'Provisioning launch root',
        'Pinned git sync mode requires SCALEWORLD_GIT_TARGET_REF',
        'Unsupported git sync mode'
    )

    foreach ($fragment in $fatalFragments) {
        if ($Message -like "*$fragment*") {
            return $true
        }
    }

    return $false
}

function New-ProvisioningHeartbeatContext {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId
    )

    $heartbeatScript = Join-Path $PSScriptRoot 'runtime-status-heartbeat.ps1'
    if (-not (Test-Path -LiteralPath $heartbeatScript)) {
        Write-ProvisioningLog "Runtime status heartbeat helper was not found at '$heartbeatScript'. Continuing without provisioning heartbeat refresh." 'WARN'
        return $null
    }

    $token = '{0}-{1}' -f $InstanceId, ([guid]::NewGuid().ToString('N'))
    $stateFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "scaleworld-provisioning-status-$token.state"
    $stopFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "scaleworld-provisioning-status-$token.stop"

    return [pscustomobject]@{
        ScriptPath = $heartbeatScript
        AwsCli = $AwsCli
        Region = $Region
        InstanceId = $InstanceId
        StateFilePath = $stateFilePath
        StopFilePath = $stopFilePath
        Source = 'startup-script'
        Process = $null
    }
}

function Set-ProvisioningHeartbeatState {
    param(
        [pscustomobject]$Context,
        [string]$Status,
        [string]$Reason
    )

    if (-not $Context) {
        return
    }

    $lines = @(
        "status=$Status",
        "source=$($Context.Source)",
        "reason=$Reason",
        'version=',
        ("status_at_utc={0}" -f ((Get-Date).ToUniversalTime().ToString('o')))
    )
    [System.IO.File]::WriteAllLines($Context.StateFilePath, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Start-ProvisioningHeartbeat {
    param([pscustomobject]$Context)

    if (-not $Context) {
        return
    }

    if (Test-Path -LiteralPath $Context.StopFilePath) {
        Remove-Item -LiteralPath $Context.StopFilePath -Force -ErrorAction SilentlyContinue
    }

    $heartbeatArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Context.ScriptPath,
        '-InstanceId', $Context.InstanceId,
        '-Region', $Context.Region,
        '-AwsCliPath', $Context.AwsCli,
        '-StateFilePath', $Context.StateFilePath,
        '-StopFilePath', $Context.StopFilePath,
        '-IntervalSeconds', '30'
    )
    $heartbeatArgumentString = ($heartbeatArguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"{0}"' -f (($_ -replace '(\\*)"', '$1$1\"'))
        } else {
            $_
        }
    }) -join ' '

    $Context.Process = Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList $heartbeatArgumentString -PassThru
}

function Stop-ProvisioningHeartbeat {
    param([pscustomobject]$Context)

    if (-not $Context) {
        return
    }

    try {
        [System.IO.File]::WriteAllText($Context.StopFilePath, 'stop', (New-Object System.Text.UTF8Encoding($false)))
    } catch {
    }

    $heartbeatProcess = $Context.Process
    if ($heartbeatProcess) {
        try {
            if (-not $heartbeatProcess.HasExited -and -not $heartbeatProcess.WaitForExit(5000)) {
                Stop-Process -Id $heartbeatProcess.Id -Force -ErrorAction SilentlyContinue
                $heartbeatProcess.WaitForExit(2000) | Out-Null
            }
        } catch {
            try {
                Stop-Process -Id $heartbeatProcess.Id -Force -ErrorAction SilentlyContinue
            } catch {
            }
        }
    } else {
        Start-Sleep -Milliseconds 250
    }

    Remove-Item -LiteralPath $Context.StateFilePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Context.StopFilePath -Force -ErrorAction SilentlyContinue
}

$pixelStreamingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$repoSyncScript = Join-Path $PSScriptRoot 'ensure_repo_current.ps1'
$runtimeInstallerScript = Join-Path $PSScriptRoot 'install_pixelstreaming_runtime.ps1'
$installBasePath = if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }
$runtimeArtifactBucket = if ($env:SCALEWORLD_RUNTIME_ARTIFACT_BUCKET) { $env:SCALEWORLD_RUNTIME_ARTIFACT_BUCKET } else { 'scaleworlddepot' }
$bootstrapDeadline = (Get-Date).AddSeconds([Math]::Max($BootstrapTimeoutSeconds, 1))
$detectionDeadline = (Get-Date).AddSeconds([Math]::Max($DetectionTimeoutSeconds, 1))
$attempt = 0
$provisioningConfirmed = $false

while ($true) {
    $attempt++

    try {
        $awsCli = Get-AwsCliPath
        $identity = Get-InstanceIdentity
        $instanceTags = Get-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId
        $maintenanceMode = ([string]$instanceTags['ScaleWorldMaintenanceMode']).Trim().ToLowerInvariant()
        $targetRuntimeManifestKey = Get-ProvisioningTagValue -Tags $instanceTags -Key 'ScaleWorldTargetRuntimeManifestKey'

        if ($maintenanceMode -ne 'provisioning') {
            Write-ProvisioningLog 'No provisioning maintenance mode requested. Continuing with normal startup.'
            exit 0
        }

        $provisioningConfirmed = $true
        $hasRuntimeArtifactTarget = -not [string]::IsNullOrWhiteSpace($targetRuntimeManifestKey)
        $runtimeBundleMetadataPath = Join-Path $pixelStreamingRoot 'runtime-bundle-metadata.json'
        $currentRootIsRuntimeArtifact = Test-Path -LiteralPath $runtimeBundleMetadataPath -PathType Leaf
        $currentRootIsGitCheckout = Test-Path -LiteralPath (Join-Path $pixelStreamingRoot '.git') -PathType Container

        if ((-not $currentRootIsRuntimeArtifact) -and (-not $currentRootIsGitCheckout)) {
            throw "Provisioning launch root '$pixelStreamingRoot' is neither a git checkout nor an installed PixelStreaming runtime artifact."
        }

        $heartbeatContext = New-ProvisioningHeartbeatContext -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId
        try {
            Set-ProvisioningHeartbeatState -Context $heartbeatContext -Status 'booting' -Reason 'provisioning_bootstrap'
            Start-ProvisioningHeartbeat -Context $heartbeatContext

            Write-ProvisioningLog "Provisioning maintenance detected for instance '$($identity.InstanceId)'. Preparing launch root before first startup."
            if ($currentRootIsGitCheckout) {
                if (-not (Test-Path -LiteralPath $repoSyncScript)) {
                    throw "ensure_repo_current.ps1 was not found at '$repoSyncScript'."
                }

                Set-ProvisioningHeartbeatState -Context $heartbeatContext -Status 'updating_infra' -Reason 'provisioning_repo_sync'
                & $repoSyncScript `
                    -RepoRoot $pixelStreamingRoot `
                    -Mode 'provisioning' `
                    -PhaseAwsCli $awsCli `
                    -PhaseRegion $identity.Region `
                    -PhaseInstanceId $identity.InstanceId `
                    -BuildingUpdatePhase 'provisioning_repo_sync'
                if ($LASTEXITCODE -ne 0) {
                    throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
                }
            } else {
                Write-ProvisioningLog "Launch root '$pixelStreamingRoot' is already a runtime artifact. Skipping provisioning git sync."
            }

            if ($hasRuntimeArtifactTarget) {
                if (-not (Test-Path -LiteralPath $runtimeInstallerScript)) {
                    throw "install_pixelstreaming_runtime.ps1 was not found at '$runtimeInstallerScript'."
                }

                $runtimeInstallResultPath = Join-Path $installBasePath 'state\provisioning-runtime-install-result.json'
                if (Test-Path -LiteralPath $runtimeInstallResultPath) {
                    Remove-Item -LiteralPath $runtimeInstallResultPath -Force
                }

                Write-ProvisioningLog "Installing PixelStreaming runtime artifact '$targetRuntimeManifestKey' before first startup."
                Set-ProvisioningHeartbeatState -Context $heartbeatContext -Status 'updating_infra' -Reason 'installing_pixelstreaming_runtime'
                & powershell.exe `
                    -NoProfile `
                    -ExecutionPolicy Bypass `
                    -File $runtimeInstallerScript `
                    -BucketName $runtimeArtifactBucket `
                    -ManifestS3Key $targetRuntimeManifestKey `
                    -Region $identity.Region `
                    -InstallRoot $installBasePath `
                    -ResultPath $runtimeInstallResultPath `
                    -Activate
                if ($LASTEXITCODE -ne 0) {
                    throw "install_pixelstreaming_runtime.ps1 exited with code $LASTEXITCODE."
                }

                $installResult = Get-Content -LiteralPath $runtimeInstallResultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

                Set-ProvisioningRuntimeIdentityTags `
                    -AwsCli $awsCli `
                    -Region $identity.Region `
                    -InstanceId $identity.InstanceId `
                    -ManifestKey $targetRuntimeManifestKey `
                    -InstallResult $installResult
            }
        } finally {
            Stop-ProvisioningHeartbeat -Context $heartbeatContext
        }

        Clear-ProvisioningUpdatePhaseTag -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId
        Write-ProvisioningLog 'Provisioning bootstrap completed. Continuing with normal startup.'
        exit 0
    } catch {
        $message = $_.Exception.Message

        if (-not $provisioningConfirmed) {
            if ((Get-Date) -ge $detectionDeadline) {
                Write-ProvisioningLog "Provisioning maintenance state could not be confirmed within $DetectionTimeoutSeconds seconds. Continuing with normal startup. Last error: $message" 'WARN'
                exit 0
            }

            Write-ProvisioningLog "Provisioning maintenance state not confirmed yet (attempt $attempt): $message" 'WARN'
            Start-Sleep -Seconds ([Math]::Max($RetryDelaySeconds, 1))
            continue
        }

        if (Test-FatalBootstrapError -Message $message) {
            Write-ProvisioningLog "Provisioning bootstrap failed with a non-retryable error: $message" 'ERROR'
            exit 1
        }

        if ((Get-Date) -ge $bootstrapDeadline) {
            Write-ProvisioningLog "Provisioning bootstrap timed out after $BootstrapTimeoutSeconds seconds. Last error: $message" 'ERROR'
            exit 1
        }

        Write-ProvisioningLog "Provisioning bootstrap prerequisites not ready yet (attempt $attempt): $message" 'WARN'
        Start-Sleep -Seconds ([Math]::Max($RetryDelaySeconds, 1))
    }
}
