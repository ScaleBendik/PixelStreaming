[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AwsCliPath {
    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    if (Test-Path 'C:\Program Files\Amazon\AWSCLIV2\aws.exe') {
        return 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    }

    if (Test-Path 'C:\Program Files\Amazon\AWSCLI\bin\aws.exe') {
        return 'C:\Program Files\Amazon\AWSCLI\bin\aws.exe'
    }

    return $null
}

function Get-InstanceRegion {
    param([string]$Token)

    $envCandidates = @(
        $env:SCALEWORLD_AWS_REGION,
        $env:AWS_REGION,
        $env:AWS_DEFAULT_REGION
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($envCandidates.Count -gt 0) {
        return $envCandidates[0].Trim()
    }

    $identityDocument = Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers @{
        'X-aws-ec2-metadata-token' = $Token
    }
    if ($identityDocument -and -not [string]::IsNullOrWhiteSpace($identityDocument.region)) {
        return $identityDocument.region.Trim()
    }

    return $null
}

function Normalize-DeliveryMode {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'None') {
        return $null
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    switch ($normalized) {
        { $_ -in @('git_ref', 'git-ref', 'git', 'repo', 'repo_sync') } { return 'git_ref' }
        { $_ -in @('runtime_artifact', 'runtime-artifact', 'artifact', 'runtime') } { return 'runtime_artifact' }
        'auto' { return 'auto' }
        default {
            Write-Error "Unsupported ScaleWorldPixelStreamingDeliveryMode value '$Value'. Use git_ref, runtime_artifact, or auto."
            exit 2
        }
    }
}

try {
    $aws = Get-AwsCliPath
    if (-not $aws) {
        Write-Error "AWS CLI was not found while resolving ScaleWorldPixelStreamingDeliveryMode."
        exit 2
    }

    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{
        'X-aws-ec2-metadata-token-ttl-seconds' = '21600'
    }
    $instanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{
        'X-aws-ec2-metadata-token' = $token
    }).Trim()
    $region = Get-InstanceRegion -Token $token
    if ([string]::IsNullOrWhiteSpace($region)) {
        Write-Error "Failed to resolve the EC2 instance region while resolving ScaleWorldPixelStreamingDeliveryMode."
        exit 2
    }

    $tagValue = & $aws ec2 describe-tags `
        --region $region `
        --filters "Name=resource-id,Values=$instanceId" "Name=key,Values=ScaleWorldPixelStreamingDeliveryMode,ScaleWorldPixelStreamingDeliverymode" `
        --query 'Tags[0].Value' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to query the ScaleWorldPixelStreamingDeliveryMode instance tag in region '$region'."
        exit 2
    }

    $deliveryMode = Normalize-DeliveryMode -Value $tagValue
    if ($deliveryMode) {
        Write-Output $deliveryMode
    }
    exit 0
} catch {
    Write-Error "Failed to resolve the ScaleWorldPixelStreamingDeliveryMode instance tag. $($_.Exception.Message)"
    exit 2
}
