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

try {
    $aws = Get-AwsCliPath
    if (-not $aws) {
        return
    }

    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{
        'X-aws-ec2-metadata-token-ttl-seconds' = '21600'
    }
    $instanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{
        'X-aws-ec2-metadata-token' = $token
    }).Trim()
    $region = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{
        'X-aws-ec2-metadata-token' = $token
    }).Trim()

    $tagValue = & $aws ec2 describe-tags `
        --region $region `
        --filters "Name=resource-id,Values=$instanceId" "Name=key,Values=ScaleWorldLane,ScaleWorldlane" `
        --query 'Tags[0].Value' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($tagValue) -or $tagValue -eq 'None') {
        return
    }

    Write-Output $tagValue.Trim().ToLowerInvariant()
} catch {
}
