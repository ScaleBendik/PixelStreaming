[CmdletBinding()]
param(
    [int]$DelaySeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-StopLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [delayed-stop] $Message"
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

function Invoke-LocalShutdownFallback {
    Write-StopLog 'Falling back to local OS shutdown.' 'WARN'
    & shutdown.exe /s /t 0 /f
    if ($LASTEXITCODE -ne 0) {
        Write-StopLog "shutdown.exe exited with code $LASTEXITCODE; trying Stop-Computer." 'WARN'
        Stop-Computer -Force
    }
}

$awsCli = $null
$identity = $null
try {
    $awsCli = Get-AwsCliPath
    $identity = Get-InstanceIdentity
} catch {
    Write-StopLog "Unable to initialize AWS stop request: $($_.Exception.Message)" 'WARN'
}

if ($identity) {
    Write-StopLog "Scheduled instance stop in $DelaySeconds seconds for $($identity.InstanceId)."
} else {
    Write-StopLog "Scheduled local shutdown fallback in $DelaySeconds seconds."
}
Start-Sleep -Seconds $DelaySeconds
if ($awsCli -and $identity) {
    try {
        & $awsCli ec2 stop-instances --region $identity.Region --instance-ids $identity.InstanceId *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "AWS CLI exited with code $LASTEXITCODE."
        }

        Write-StopLog "Issued stop for $($identity.InstanceId)."
        exit 0
    } catch {
        Write-StopLog "Failed to issue EC2 stop request: $($_.Exception.Message)" 'WARN'
    }
}

Invoke-LocalShutdownFallback
