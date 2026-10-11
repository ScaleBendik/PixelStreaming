[CmdletBinding()]
param(
    [ValidateSet('all', 'lane', 'track', 'delivery')]
    [string]$Field = 'all'
)

$ErrorActionPreference = 'Stop'

# One launch-local read of initial routing metadata. This intentionally excludes
# maintenance, provisioning and update controls, which require their own fresh
# reads. The caller owns the existing per-field retry/fallback policies.
#
# Stdout contains three fixed tokens on a successful read, or one when -Field
# selects a field for a fresh retry. A failed lookup emits no tokens and exits 2.
# DELIVERY_INVALID represents the standalone
# delivery resolver's failure case; TRACK_MISSING also retains its legacy
# unsupported-value behavior. Never interpolate an instance tag into CMD.

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

    $envCandidates = @(@(
        $env:SCALEWORLD_AWS_REGION,
        $env:AWS_REGION,
        $env:AWS_DEFAULT_REGION
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

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

function Get-FirstStartupTagValue {
    param(
        [object[]]$Rows,
        [string[]]$Keys
    )

    # Match Tags[0].Value from the standalone lane and track resolvers: preserve
    # returned row order, including a missing first value, rather than preferring
    # one spelling or skipping to a later nonempty alias.
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        foreach ($key in $Keys) {
            if ([string]::Equals([string]$row.Key, $key, [StringComparison]::Ordinal)) {
                return [string]$row.Value
            }
        }
    }
    return $null
}

function Normalize-StartupTagValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'None') {
        return $null
    }
    return $Value.Trim()
}

function ConvertTo-StartupTagDictionary {
    param([object[]]$Rows)

    # The standalone delivery resolver uses a case-insensitive hashtable and
    # keeps the last nonempty row. Retain that behavior for delivery aliases and
    # runtime identity inference; lane and track use first-row semantics above.
    $tags = @{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $key = Normalize-StartupTagValue -Value ([string]$row.Key)
        $value = Normalize-StartupTagValue -Value ([string]$row.Value)
        if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($value)) { continue }
        $tags[$key] = $value
    }
    return $tags
}

function ConvertTo-StartupMetadataTokens {
    param([object[]]$Rows)

    $lane = Normalize-StartupTagValue -Value (Get-FirstStartupTagValue -Rows $Rows -Keys @('ScaleWorldLane', 'ScaleWorldlane'))
    if ($null -eq $lane) {
        $laneToken = 'LANE_MISSING'
    } else {
        switch ($lane.ToLowerInvariant()) {
            'nonprod' { $laneToken = 'LANE_NONPROD' }
            'prod' { $laneToken = 'LANE_PROD' }
            default { $laneToken = 'LANE_INVALID' }
        }
    }

    $track = Normalize-StartupTagValue -Value (Get-FirstStartupTagValue -Rows $Rows -Keys @('ScaleWorldDeploymentTrack', 'ScaleWorldDeploymenttrack'))
    $trackToken = 'TRACK_MISSING'
    if ($null -ne $track) {
        switch ($track.ToLowerInvariant()) {
            'dev' { $trackToken = 'TRACK_DEV' }
            'stage' { $trackToken = 'TRACK_STAGE' }
            'prod' { $trackToken = 'TRACK_PROD' }
        }
    }

    $tags = ConvertTo-StartupTagDictionary -Rows $Rows
    $deliveryToken = 'DELIVERY_MISSING'
    $delivery = if ($tags.ContainsKey('ScaleWorldPixelStreamingDeliveryMode')) {
        Normalize-StartupTagValue -Value ([string]$tags['ScaleWorldPixelStreamingDeliveryMode'])
    } else {
        $null
    }
    if ($null -ne $delivery) {
        switch ($delivery.ToLowerInvariant()) {
            { $_ -in @('git_ref', 'git-ref', 'git', 'repo', 'repo_sync') } { $deliveryToken = 'DELIVERY_GIT_REF' }
            { $_ -in @('runtime_artifact', 'runtime-artifact', 'artifact', 'runtime') } { $deliveryToken = 'DELIVERY_RUNTIME_ARTIFACT' }
            'auto' { $deliveryToken = 'DELIVERY_AUTO' }
            default { $deliveryToken = 'DELIVERY_INVALID' }
        }
    } else {
        foreach ($key in @(
            'ScaleWorldPixelStreamingRuntimeBundleId',
            'ScaleWorldPixelStreamingRuntimeManifestKey',
            'ScaleWorldPixelStreamingRuntimeArtifactKey'
        )) {
            if ($tags.ContainsKey($key)) {
                $deliveryToken = 'DELIVERY_RUNTIME_ARTIFACT'
                break
            }
        }
    }

    return @($laneToken, $trackToken, $deliveryToken)
}

function Invoke-StartupMetadataLookup {
    $aws = Get-AwsCliPath
    if (-not $aws) { throw 'AWS CLI was not found while resolving initial startup metadata.' }

    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{
        'X-aws-ec2-metadata-token-ttl-seconds' = '21600'
    }
    $instanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{
        'X-aws-ec2-metadata-token' = $token
    }).Trim()
    $region = Get-InstanceRegion -Token $token
    if ([string]::IsNullOrWhiteSpace($region)) { throw 'Failed to resolve the EC2 instance region while resolving initial startup metadata.' }

    $tagJson = & $aws ec2 describe-tags `
        --region $region `
        --filters "Name=resource-id,Values=$instanceId" "Name=key,Values=ScaleWorldLane,ScaleWorldlane,ScaleWorldDeploymentTrack,ScaleWorldDeploymenttrack,ScaleWorldPixelStreamingDeliveryMode,ScaleWorldPixelStreamingDeliverymode,ScaleWorldPixelStreamingRuntimeBundleId,ScaleWorldPixelStreamingRuntimeManifestKey,ScaleWorldPixelStreamingRuntimeArtifactKey" `
        --query 'Tags[].{Key:Key,Value:Value}' `
        --output json
    if ($LASTEXITCODE -ne 0) { throw "Failed to query initial startup metadata in region '$region'." }

    $tagRows = if ([string]::IsNullOrWhiteSpace(($tagJson -join "`n"))) { @() } else { @(($tagJson -join "`n") | ConvertFrom-Json) }
    return ConvertTo-StartupMetadataTokens -Rows $tagRows
}

try {
    # Collect every token before writing any output so transport/parse failures
    # cannot be mistaken for a partial successful snapshot by FOR /F.
    $tokens = @(Invoke-StartupMetadataLookup)
    switch ($Field) {
        'lane' { Write-Output $tokens[0] }
        'track' { Write-Output $tokens[1] }
        'delivery' { Write-Output $tokens[2] }
        'all' { Write-Output $tokens }
    }
    exit 0
} catch {
    Write-Error "Failed to resolve initial startup metadata. $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}
