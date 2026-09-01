[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AwsCliPath {
    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
        'C:\Program Files\Amazon\AWSCLI\bin\aws.exe')) {
        if (Test-Path $path) {
            return $path
        }
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
    return $identityDocument.region.Trim()
}

try {
    $aws = Get-AwsCliPath
    if (-not $aws) {
        throw 'AWS CLI was not found.'
    }

    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{
        'X-aws-ec2-metadata-token-ttl-seconds' = '21600'
    }
    $instanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{
        'X-aws-ec2-metadata-token' = $token
    }).Trim()
    $region = Get-InstanceRegion -Token $token
    $tagValue = & $aws ec2 describe-tags `
        --region $region `
        --filters "Name=resource-id,Values=$instanceId" "Name=key,Values=ScaleWorldServiceClass" `
        --query 'Tags[0].Value' `
        --output text
    if ($LASTEXITCODE -ne 0) {
        throw "EC2 tag lookup failed in region '$region'."
    }

    $normalized = if ([string]::IsNullOrWhiteSpace($tagValue) -or $tagValue -eq 'None') {
        'standard'
    } else {
        $tagValue.Trim().ToLowerInvariant()
    }
    if ($normalized -notin @('standard', 'premium')) {
        throw "Unsupported ScaleWorldServiceClass '$normalized'."
    }

    Write-Output $normalized
} catch {
    Write-Error "Failed to resolve ScaleWorldServiceClass. $($_.Exception.Message)"
    exit 2
}
