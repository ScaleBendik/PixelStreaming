[CmdletBinding()]
param(
    [int]$BootstrapTimeoutSeconds = $(if ($env:SCALEWORLD_PROVISIONING_BOOTSTRAP_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_PROVISIONING_BOOTSTRAP_TIMEOUT_SECONDS } else { 900 }),
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

function Test-FatalBootstrapError {
    param([string]$Message)

    $fatalFragments = @(
        "AWS CLI ('aws') was not found.",
        "Git ('git') was not found.",
        'build-all.bat was not found',
        'is not a git repository',
        'Tracked local changes are present',
        'ensure_repo_current.ps1 was not found'
    )

    foreach ($fragment in $fatalFragments) {
        if ($Message -like "*$fragment*") {
            return $true
        }
    }

    return $false
}

$pixelStreamingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$repoSyncScript = Join-Path $PSScriptRoot 'ensure_repo_current.ps1'
$deadline = (Get-Date).AddSeconds([Math]::Max($BootstrapTimeoutSeconds, 1))
$attempt = 0

while ($true) {
    $attempt++

    try {
        $awsCli = Get-AwsCliPath
        $identity = Get-InstanceIdentity
        $instanceTags = Get-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId
        $maintenanceMode = ([string]$instanceTags['ScaleWorldMaintenanceMode']).Trim().ToLowerInvariant()

        if ($maintenanceMode -ne 'provisioning') {
            Write-ProvisioningLog 'No provisioning maintenance mode requested. Continuing with normal startup.'
            exit 0
        }

        if (-not (Test-Path -LiteralPath $repoSyncScript)) {
            throw "ensure_repo_current.ps1 was not found at '$repoSyncScript'."
        }

        Write-ProvisioningLog "Provisioning maintenance detected for instance '$($identity.InstanceId)'. Ensuring repo/bootstrap prerequisites before first startup."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repoSyncScript -RepoRoot $pixelStreamingRoot -Mode 'provisioning'
        if ($LASTEXITCODE -ne 0) {
            throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
        }

        Write-ProvisioningLog 'Provisioning bootstrap completed. Continuing with normal startup.'
        exit 0
    } catch {
        $message = $_.Exception.Message
        if (Test-FatalBootstrapError -Message $message) {
            Write-ProvisioningLog "Provisioning bootstrap failed with a non-retryable error: $message" 'ERROR'
            exit 1
        }

        if ((Get-Date) -ge $deadline) {
            Write-ProvisioningLog "Provisioning bootstrap timed out after $BootstrapTimeoutSeconds seconds. Last error: $message" 'ERROR'
            exit 1
        }

        Write-ProvisioningLog "Provisioning bootstrap prerequisites not ready yet (attempt $attempt): $message" 'WARN'
        Start-Sleep -Seconds ([Math]::Max($RetryDelaySeconds, 1))
    }
}
