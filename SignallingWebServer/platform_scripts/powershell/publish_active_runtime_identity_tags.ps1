[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$AwsCliPath = $(if ($env:RUNTIME_STATUS_AWS_CLI_PATH) { $env:RUNTIME_STATUS_AWS_CLI_PATH } else { 'aws' }),
    [switch]$Required
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ActiveRuntimeIdentityLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [active-runtime-identity] $Message"
}

function Normalize-TagValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = ($Value -replace '\s+', ' ').Trim()
    if ($normalized.Length -gt 256) {
        return $normalized.Substring(0, 256)
    }

    return $normalized
}

function Add-OptionalTag {
    param(
        [System.Collections.Generic.List[hashtable]]$Tags,
        [string]$Key,
        [string]$Value
    )

    $normalizedValue = Normalize-TagValue -Value $Value
    if ([string]::IsNullOrWhiteSpace($normalizedValue)) {
        return
    }

    $Tags.Add(@{
        Key = $Key
        Value = $normalizedValue
    })
}

function Get-JsonPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-InstanceIdentity {
    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{
        'X-aws-ec2-metadata-token-ttl-seconds' = '21600'
    }

    $instanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{
        'X-aws-ec2-metadata-token' = $token
    }).Trim()

    $region = $null
    foreach ($candidate in @($env:SCALEWORLD_AWS_REGION, $env:AWS_REGION, $env:AWS_DEFAULT_REGION)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $region = $candidate.Trim()
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($region)) {
        $identityDocument = Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers @{
            'X-aws-ec2-metadata-token' = $token
        }
        if ($identityDocument -and -not [string]::IsNullOrWhiteSpace($identityDocument.region)) {
            $region = $identityDocument.region.Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($instanceId) -or [string]::IsNullOrWhiteSpace($region)) {
        throw "Failed to resolve instance id or region from EC2 metadata."
    }

    return [pscustomobject]@{
        InstanceId = $instanceId
        Region = $region
    }
}

function Invoke-AwsCliCapture {
    param(
        [string]$AwsCli,
        [string[]]$Arguments
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath $AwsCli -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
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
            Combined = (@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    }

    $runtimeRootFull = (Resolve-Path -LiteralPath $RuntimeRoot -ErrorAction Stop).Path
    $metadataPath = Join-Path $runtimeRootFull 'runtime-bundle-metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        $message = "Runtime bundle metadata was not found at '$metadataPath'."
        if ($Required) {
            throw $message
        }

        Write-ActiveRuntimeIdentityLog "$message Skipping active runtime identity publish." 'WARN'
        exit 0
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $bundleId = Normalize-TagValue -Value ([string](Get-JsonPropertyValue -InputObject $metadata -Name 'bundleId'))
    if ([string]::IsNullOrWhiteSpace($bundleId)) {
        $message = "Runtime bundle metadata at '$metadataPath' has no bundleId."
        if ($Required) {
            throw $message
        }

        Write-ActiveRuntimeIdentityLog "$message Skipping active runtime identity publish." 'WARN'
        exit 0
    }

    $runtimeZipKey = Normalize-TagValue -Value ([string](Get-JsonPropertyValue -InputObject $metadata -Name 'runtimeZipKey'))
    if ([string]::IsNullOrWhiteSpace($runtimeZipKey)) {
        $runtimeZipKey = "PixelStreamingRuntime/$bundleId/runtime.zip"
    }

    $manifestKey = Normalize-TagValue -Value ([string](Get-JsonPropertyValue -InputObject $metadata -Name 'manifestKey'))
    if ([string]::IsNullOrWhiteSpace($manifestKey)) {
        $manifestKey = "PixelStreamingRuntime/$bundleId/manifest.json"
    }

    $identity = Get-InstanceIdentity
    $tags = [System.Collections.Generic.List[hashtable]]::new()
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingDeliveryMode' -Value 'runtime_artifact'
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingRuntimeManifestKey' -Value $manifestKey
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingRuntimeBundleId' -Value $bundleId
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingRuntimeArtifactKey' -Value $runtimeZipKey
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingRuntimeSourceCommit' -Value ([string](Get-JsonPropertyValue -InputObject $metadata -Name 'pixelStreamingRepoCommit'))
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingRuntimeContractVersion' -Value ([string](Get-JsonPropertyValue -InputObject $metadata -Name 'scaleWorldContractVersion'))
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingVersion' -Value $bundleId
    Add-OptionalTag -Tags $tags -Key 'ScaleWorldPixelStreamingUpdateCapabilities' -Value 'pixelstreaming_runtime,combined_runtime_unreal'

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            (ConvertTo-Json -InputObject @($tags) -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $result = Invoke-AwsCliCapture -AwsCli $AwsCliPath -Arguments @(
            'ec2', 'create-tags',
            '--region', $identity.Region,
            '--resources', $identity.InstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )
        if ($result.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                throw "AWS CLI exited with code $($result.ExitCode)."
            }

            throw $result.Combined
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }

    Write-ActiveRuntimeIdentityLog "Published active runtime identity '$bundleId' for instance '$($identity.InstanceId)'."
    exit 0
} catch {
    Write-ActiveRuntimeIdentityLog "Failed to publish active runtime identity tags: $($_.Exception.Message)" 'WARN'
    if ($Required) {
        exit 1
    }

    exit 0
}
