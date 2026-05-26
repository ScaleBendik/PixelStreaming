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

function Add-OptionalEc2TagArgument {
    param(
        [System.Collections.Generic.List[string]]$TagArguments,
        [string]$Key,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $normalizedValue = $Value.Trim()
    if ($normalizedValue.Length -gt 256) {
        $normalizedValue = $normalizedValue.Substring(0, 256)
    }

    $TagArguments.Add("Key=$Key,Value=$normalizedValue")
}

function Set-ProvisioningRuntimeIdentityTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [string]$ManifestKey,
        [pscustomobject]$InstallResult
    )

    $tagArguments = [System.Collections.Generic.List[string]]::new()
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingRuntimeManifestKey' -Value $ManifestKey
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingRuntimeBundleId' -Value ([string]$InstallResult.BundleId)
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingRuntimeArtifactKey' -Value ([string]$InstallResult.RuntimeZipKey)
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingRuntimeSourceCommit' -Value ([string]$InstallResult.SourceCommit)
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingRuntimeContractVersion' -Value ([string]$InstallResult.ContractVersion)
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingVersion' -Value ([string]$InstallResult.BundleId)
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldPixelStreamingUpdateCapabilities' -Value 'pixelstreaming_runtime,combined_runtime_unreal'
    Add-OptionalEc2TagArgument -TagArguments $tagArguments -Key 'ScaleWorldLastUpdatedAtUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))

    if ($tagArguments.Count -eq 0) {
        return
    }

    & $AwsCli ec2 create-tags --region $Region --resources $InstanceId --tags $tagArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to publish PixelStreaming runtime identity tags for $InstanceId."
    }

    $deliveryTagArguments = [System.Collections.Generic.List[string]]::new()
    Add-OptionalEc2TagArgument -TagArguments $deliveryTagArguments -Key 'ScaleWorldPixelStreamingDeliveryMode' -Value 'runtime_artifact'
    & $AwsCli ec2 create-tags --region $Region --resources $InstanceId --tags $deliveryTagArguments
    if ($LASTEXITCODE -ne 0) {
        Write-ProvisioningLog "Published PixelStreaming runtime identity tags for $InstanceId, but failed to publish delivery mode tag." 'WARN'
    }
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

    Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList $heartbeatArgumentString | Out-Null
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

    Start-Sleep -Milliseconds 250
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

        if (-not (Test-Path -LiteralPath $repoSyncScript)) {
            throw "ensure_repo_current.ps1 was not found at '$repoSyncScript'."
        }

        $heartbeatContext = New-ProvisioningHeartbeatContext -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId
        try {
            Set-ProvisioningHeartbeatState -Context $heartbeatContext -Status 'booting' -Reason 'provisioning_bootstrap'
            Start-ProvisioningHeartbeat -Context $heartbeatContext

            Write-ProvisioningLog "Provisioning maintenance detected for instance '$($identity.InstanceId)'. Ensuring repo/bootstrap prerequisites before first startup."
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

            if (-not [string]::IsNullOrWhiteSpace($targetRuntimeManifestKey)) {
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
