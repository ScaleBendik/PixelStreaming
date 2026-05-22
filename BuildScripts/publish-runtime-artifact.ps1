param(
    [string]$BundlePrefix = "pixelstreaming-runtime",
    [string]$DateStamp,
    [string]$OutputRoot,
    [string]$S3Bucket = "scaleworlddepot",
    [string]$S3Prefix = "PixelStreamingRuntime",
    [string]$Region = "eu-north-1",
    [ValidateSet("full", "runtime")]
    [string]$BuildScope = "full",
    [string]$ContractVersion,
    [string[]]$Capabilities = @("runtime-status-v1", "instance-agent-bootstrap-v1"),
    [int]$MaxSequence = 999,
    [switch]$SkipBuild,
    [switch]$SkipNodeModules,
    [switch]$AllowDirty,
    [switch]$NoPublish,
    [switch]$LocalOnlyNameScan
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$repoRootPath = $repoRoot.Path

function Normalize-Optional {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim()
}

function Get-AwsCliPath {
    $candidate = Get-Command aws.exe -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    return $null
}

function Get-LocalBundleIds {
    param(
        [string]$Root,
        [string]$Prefix,
        [string]$BuildDate
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    $pattern = "^$([regex]::Escape("$Prefix-$BuildDate-"))(?<Sequence>\d{3})$"
    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        ForEach-Object { $_.Name }
}

function Get-S3BundleIds {
    param(
        [string]$AwsCli,
        [string]$Bucket,
        [string]$Prefix,
        [string]$BundlePrefixValue,
        [string]$BuildDate,
        [string]$AwsRegion
    )

    $normalizedPrefix = (Normalize-Optional $Prefix)
    if (-not $normalizedPrefix) {
        $normalizedPrefix = "PixelStreamingRuntime"
    }

    $normalizedPrefix = $normalizedPrefix.Trim("/")
    $bundleKeyPrefix = "$normalizedPrefix/$BundlePrefixValue-$BuildDate-"
    $output = & $AwsCli s3api list-objects-v2 `
        --bucket $Bucket `
        --prefix $bundleKeyPrefix `
        --region $AwsRegion `
        --query "Contents[].Key" `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        Write-Warning "Could not list existing runtime artifacts in s3://$Bucket/$bundleKeyPrefix. Falling back to local artifact names. AWS output: $message"
        $global:LASTEXITCODE = 0
        return @()
    }

    $keys = @()
    $json = ($output | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        $keys = @($json | ConvertFrom-Json -ErrorAction Stop)
    }

    $manifestPattern = "^$([regex]::Escape("$normalizedPrefix/"))(?<BundleId>$([regex]::Escape("$BundlePrefixValue-$BuildDate-"))\d{3})/manifest\.json$"
    $keys |
        Where-Object { $_ -match $manifestPattern } |
        ForEach-Object { [regex]::Match($_, $manifestPattern).Groups["BundleId"].Value }
}

function Test-S3ManifestExists {
    param(
        [string]$AwsCli,
        [string]$Bucket,
        [string]$Prefix,
        [string]$BundleId,
        [string]$AwsRegion
    )

    $normalizedPrefix = (Normalize-Optional $Prefix)
    if (-not $normalizedPrefix) {
        $normalizedPrefix = "PixelStreamingRuntime"
    }

    $normalizedPrefix = $normalizedPrefix.Trim("/")
    $manifestKey = "$normalizedPrefix/$BundleId/manifest.json"
    $output = & $AwsCli s3api head-object `
        --bucket $Bucket `
        --key $manifestKey `
        --region $AwsRegion 2>&1

    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    $message = ($output | Out-String).Trim()
    $global:LASTEXITCODE = 0
    if ($message -match '404|Not Found|NoSuchKey') {
        return $false
    }

    Write-Warning "Could not verify whether s3://$Bucket/$manifestKey exists. Continuing with the locally selected bundle id. AWS output: $message"
    return $null
}

function Get-NextBundleId {
    param(
        [string[]]$BundleIds,
        [string]$Prefix,
        [string]$BuildDate,
        [int]$MaximumSequence
    )

    $pattern = "^$([regex]::Escape("$Prefix-$BuildDate-"))(?<Sequence>\d{3})$"
    $maxSeen = 0

    foreach ($bundleId in $BundleIds) {
        $match = [regex]::Match($bundleId, $pattern)
        if (-not $match.Success) {
            continue
        }

        $sequence = [int]$match.Groups["Sequence"].Value
        if ($sequence -gt $maxSeen) {
            $maxSeen = $sequence
        }
    }

    $nextSequence = $maxSeen + 1
    if ($nextSequence -gt $MaximumSequence) {
        throw "No bundle sequence is available for $Prefix-$BuildDate. Increase MaxSequence or choose another DateStamp."
    }

    return "{0}-{1}-{2:D3}" -f $Prefix, $BuildDate, $nextSequence
}

$bundlePrefix = (Normalize-Optional $BundlePrefix)
if (-not $bundlePrefix) {
    throw "BundlePrefix cannot be empty."
}

if ($bundlePrefix -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "BundlePrefix '$bundlePrefix' contains unsupported characters. Use letters, numbers, dot, underscore, or hyphen."
}

$dateStamp = (Normalize-Optional $DateStamp)
if (-not $dateStamp) {
    $dateStamp = (Get-Date).ToString("yyyyMMdd")
}

if ($dateStamp -notmatch '^\d{8}$') {
    throw "DateStamp '$dateStamp' must use yyyyMMdd format."
}

if ($MaxSequence -lt 1 -or $MaxSequence -gt 999) {
    throw "MaxSequence must be between 1 and 999."
}

$outputRoot = Normalize-Optional $OutputRoot
if (-not $outputRoot) {
    $outputRoot = Join-Path $repoRootPath "BuildArtifacts\PixelStreamingRuntime"
}

$outputRoot = [System.IO.Path]::GetFullPath($outputRoot)
$bundleIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($bundleId in Get-LocalBundleIds -Root $outputRoot -Prefix $bundlePrefix -BuildDate $dateStamp) {
    [void]$bundleIds.Add($bundleId)
}

$aws = $null
if (-not $LocalOnlyNameScan) {
    $aws = Get-AwsCliPath
    if ($aws) {
        foreach ($bundleId in Get-S3BundleIds `
            -AwsCli $aws `
            -Bucket $S3Bucket `
            -Prefix $S3Prefix `
            -BundlePrefixValue $bundlePrefix `
            -BuildDate $dateStamp `
            -AwsRegion $Region) {
            [void]$bundleIds.Add($bundleId)
        }
    } else {
        Write-Warning "AWS CLI was not found. Runtime artifact name selection will use local artifacts only."
    }
}

$selectedBundleId = Get-NextBundleId `
    -BundleIds @($bundleIds) `
    -Prefix $bundlePrefix `
    -BuildDate $dateStamp `
    -MaximumSequence $MaxSequence

if (-not $NoPublish -and -not $LocalOnlyNameScan -and $aws) {
    while ($true) {
        $exists = Test-S3ManifestExists `
            -AwsCli $aws `
            -Bucket $S3Bucket `
            -Prefix $S3Prefix `
            -BundleId $selectedBundleId `
            -AwsRegion $Region

        if ($exists -eq $true) {
            [void]$bundleIds.Add($selectedBundleId)
            $selectedBundleId = Get-NextBundleId `
                -BundleIds @($bundleIds) `
                -Prefix $bundlePrefix `
                -BuildDate $dateStamp `
                -MaximumSequence $MaxSequence
            continue
        }

        break
    }
}

Write-Host "Selected PixelStreaming runtime bundle id: $selectedBundleId" -ForegroundColor Cyan

$packageScript = Join-Path $PSScriptRoot "package-runtime-artifact.ps1"
$packageArguments = @{
    BundleId = $selectedBundleId
    OutputRoot = $outputRoot
    S3Bucket = $S3Bucket
    S3Prefix = $S3Prefix
    Region = $Region
    BuildScope = $BuildScope
}

if (-not [string]::IsNullOrWhiteSpace($ContractVersion)) {
    $packageArguments.ContractVersion = $ContractVersion
}

if ($Capabilities.Count -gt 0) {
    $packageArguments.Capabilities = $Capabilities
}

if ($SkipBuild) {
    $packageArguments.SkipBuild = $true
}

if ($SkipNodeModules) {
    $packageArguments.SkipNodeModules = $true
}

if ($AllowDirty) {
    $packageArguments.AllowDirty = $true
}

if (-not $NoPublish) {
    $packageArguments.Publish = $true
}

& $packageScript @packageArguments
