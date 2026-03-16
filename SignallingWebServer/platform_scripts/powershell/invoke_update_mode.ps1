[CmdletBinding()]
param(
    [int]$FailureStopDelaySeconds = $(if ($env:SCALEWORLD_UPDATE_FAILURE_STOP_DELAY_SECONDS) { [int]$env:SCALEWORLD_UPDATE_FAILURE_STOP_DELAY_SECONDS } else { 1800 }),
    [int]$ValidationTimeoutSeconds = $(if ($env:SCALEWORLD_UPDATE_VALIDATION_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_UPDATE_VALIDATION_TIMEOUT_SECONDS } else { 180 }),
    [int]$ValidationStableSeconds = $(if ($env:SCALEWORLD_UPDATE_VALIDATION_STABLE_SECONDS) { [int]$env:SCALEWORLD_UPDATE_VALIDATION_STABLE_SECONDS } else { 15 }),
    [bool]$AllowUnchanged = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-UpdateModeLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [update-mode] $Message"
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

function Set-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [hashtable]$Tags
    )

    if (-not $Tags -or $Tags.Count -eq 0) {
        return
    }

    $args = @('ec2', 'create-tags', '--region', $Region, '--resources', $InstanceId, '--tags')
    foreach ($key in $Tags.Keys) {
        $args += ("Key={0},Value={1}" -f $key, (Normalize-TagValue ([string]$Tags[$key])))
    }

    & $AwsCli @args *> $null
}

function Schedule-DelayedStop {
    param(
        [int]$DelaySeconds
    )

    $scriptPath = Join-Path $PSScriptRoot 'stop_instance_after_delay.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-UpdateModeLog "Delayed stop script not found at '$scriptPath'. Manual cleanup may be required." 'WARN'
        return
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-DelaySeconds', $DelaySeconds
    ) -WindowStyle Hidden | Out-Null

    Write-UpdateModeLog "Scheduled delayed instance stop in $DelaySeconds seconds."
}

function Publish-CurrentBuildTags {
    param(
        [string]$PublishScriptPath,
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId
    )

    if (-not (Test-Path -LiteralPath $PublishScriptPath)) {
        Write-UpdateModeLog "Current build publish script not found at '$PublishScriptPath'." 'WARN'
        return $false
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PublishScriptPath -InstanceId $InstanceId -Region $Region -AwsCliPath $AwsCli
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    if ($LASTEXITCODE -eq 2) {
        Write-UpdateModeLog 'Current release metadata was not available after update validation. Falling back to zip filename tags.' 'WARN'
        return $false
    }

    Write-UpdateModeLog "Current build tag publish script failed with exit code $LASTEXITCODE. Falling back to zip filename tags." 'WARN'
    return $false
}

function Get-StreamerHealthSnapshot {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Wait-ForStreamerValidation {
    param(
        [string]$HealthPath,
        [int]$TimeoutSeconds,
        [int]$StableSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $healthySince = $null

    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-StreamerHealthSnapshot -Path $HealthPath
        $isHealthy =
            $snapshot -and
            [string]$snapshot.status -eq 'ready' -and
            $snapshot.healthy -eq $true -and
            [int]$snapshot.streamerCount -gt 0

        if ($isHealthy) {
            if (-not $healthySince) {
                $healthySince = Get-Date
            }

            if (((Get-Date) - $healthySince).TotalSeconds -ge $StableSeconds) {
                return $true
            }
        } else {
            $healthySince = $null
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

$awsCli = Get-AwsCliPath
$identity = Get-InstanceIdentity
$instanceTags = Get-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId

$maintenanceMode = [string]$instanceTags['ScaleWorldMaintenanceMode']
if ($maintenanceMode -ne 'update') {
    Write-UpdateModeLog 'No update maintenance mode requested. Continuing with normal startup.'
    exit 0
}

$currentUpdateState = ([string]$instanceTags['ScaleWorldUpdateState']).Trim().ToLowerInvariant()
if ($currentUpdateState -in @('succeeded', 'failed', 'stopping')) {
    Write-UpdateModeLog "Maintenance update is already in terminal state '$currentUpdateState'. Waiting for API reconciliation or explicit retry."
    exit 11
}

$targetZipKey = [string]$instanceTags['ScaleWorldTargetZipKey']
if ([string]::IsNullOrWhiteSpace($targetZipKey)) {
    Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'failed'
        ScaleWorldUpdateResultReason = 'missing_target_zip'
        ScaleWorldUpdateCompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Schedule-DelayedStop -DelaySeconds $FailureStopDelaySeconds
    Write-UpdateModeLog 'Update maintenance mode was requested without ScaleWorldTargetZipKey.' 'ERROR'
    exit 11
}

$zipFileName = Split-Path -Leaf $targetZipKey
Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
    ScaleWorldUpdateState = 'running'
    ScaleWorldUpdateResultReason = ''
    ScaleWorldUpdateCompletedAtUtc = ''
}

$pixelStreamingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$updateScript = Join-Path $pixelStreamingRoot 'SWupdate.ps1'
$stackLauncher = Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat'
$streamerHealthPath = Join-Path $pixelStreamingRoot 'SignallingWebServer\state\streamer-health.json'
$repoSyncScript = Join-Path $PSScriptRoot 'ensure_repo_current.ps1'
$publishCurrentBuildScript = Join-Path $PSScriptRoot 'publish_current_build_tags.ps1'

$prepareDataDrive = if ($env:STACK_PREPARE_DATA_DRIVE) { [System.Boolean]::Parse($env:STACK_PREPARE_DATA_DRIVE) } else { $true }
$requireDataDrive = if ($env:STACK_REQUIRE_DATA_DRIVE) { [System.Boolean]::Parse($env:STACK_REQUIRE_DATA_DRIVE) } else { $false }
$dataDiskNumber = if ($env:SCALEWORLD_DATA_DISK_NUMBER) { [int]$env:SCALEWORLD_DATA_DISK_NUMBER } else { 1 }

try {
    if ($prepareDataDrive) {
        $dataDriveScript = Join-Path $PSScriptRoot 'ensure_data_drive.ps1'
        if (Test-Path -LiteralPath $dataDriveScript) {
            Write-UpdateModeLog 'Preparing data drive for update mode.'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dataDriveScript -DataDiskNumber $dataDiskNumber -SkipIfUnavailable
            if ($LASTEXITCODE -ne 0) {
                if ($requireDataDrive) {
                    throw "Data drive preparation failed with code $LASTEXITCODE."
                }

                Write-UpdateModeLog "Data drive preparation failed with code $LASTEXITCODE. Continuing without prepared data drive." 'WARN'
            }
        } else {
            Write-UpdateModeLog "Data drive script not found at '$dataDriveScript'. Continuing without prepared data drive." 'WARN'
        }
    }

    if (-not (Test-Path -LiteralPath $repoSyncScript)) {
        throw "Repo sync helper not found at '$repoSyncScript'."
    }

    Write-UpdateModeLog 'Checking PixelStreaming repo for remote updates before Unreal update.'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repoSyncScript -RepoRoot $pixelStreamingRoot -Mode 'update'
    if ($LASTEXITCODE -ne 0) {
        throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $updateScript)) {
        throw "SWupdate.ps1 not found at '$updateScript'."
    }

    $updateArgs = @('-ZipKey', $targetZipKey)
    if ($AllowUnchanged) {
        $updateArgs += '-AllowUnchanged'
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updateScript @updateArgs
    if ($LASTEXITCODE -ne 0) {
        throw "SWupdate.ps1 exited with code $LASTEXITCODE."
    }

    Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'validating'
        ScaleWorldUpdateResultReason = ''
        ScaleWorldUpdateCompletedAtUtc = ''
    }

    if (-not (Test-Path -LiteralPath $stackLauncher)) {
        throw "Validation stack launcher not found at '$stackLauncher'."
    }

    if (Test-Path -LiteralPath $streamerHealthPath) {
        Remove-Item -LiteralPath $streamerHealthPath -Force
    }

    Write-UpdateModeLog "Launching validation stack for '$zipFileName'."
    Start-Process -FilePath $stackLauncher -ArgumentList '--validation' -WindowStyle Hidden | Out-Null

    Write-UpdateModeLog "Waiting up to $ValidationTimeoutSeconds seconds for streamer validation."
    $validated = Wait-ForStreamerValidation -HealthPath $streamerHealthPath -TimeoutSeconds $ValidationTimeoutSeconds -StableSeconds $ValidationStableSeconds
    if (-not $validated) {
        throw "Updated build failed validation within $ValidationTimeoutSeconds seconds."
    }

    $completionTime = (Get-Date).ToUniversalTime().ToString('o')
    $publishedCurrentBuild = Publish-CurrentBuildTags -PublishScriptPath $publishCurrentBuildScript -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId
    $successTags = @{
        ScaleWorldUpdateState = 'succeeded'
        ScaleWorldUpdateResultReason = 'validated_streamer_connected'
        ScaleWorldUpdateCompletedAtUtc = $completionTime
    }
    if (-not $publishedCurrentBuild) {
        $successTags.ScaleWorldCurrentBuild = $zipFileName
        $successTags.ScaleWorldLastUpdatedAtUtc = $completionTime
    }
    Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags $successTags
    Write-UpdateModeLog "Update validated successfully for '$zipFileName'. Requesting instance stop and leaving Fleet command tags for API reconciliation."
    & $awsCli ec2 stop-instances --region $identity.Region --instance-ids $identity.InstanceId *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to request instance stop after validation."
    }
    exit 10
} catch {
    $reason = $_.Exception.Message
    Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'failed'
        ScaleWorldUpdateResultReason = $reason
        ScaleWorldUpdateCompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Schedule-DelayedStop -DelaySeconds $FailureStopDelaySeconds
    Write-UpdateModeLog "Update failed: $reason" 'ERROR'
    exit 11
}
