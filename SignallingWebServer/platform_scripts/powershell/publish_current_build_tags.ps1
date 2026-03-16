[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,
    [Parameter(Mandatory = $true)]
    [string]$Region,
    [string]$AwsCliPath = $(if ($env:RUNTIME_STATUS_AWS_CLI_PATH) { $env:RUNTIME_STATUS_AWS_CLI_PATH } else { 'aws' }),
    [string]$CurrentReleaseStatePath = $(if ($env:SCALEWORLD_CURRENT_RELEASE_STATE_PATH) { $env:SCALEWORLD_CURRENT_RELEASE_STATE_PATH } else { 'C:\PixelStreaming\state\current-release.json' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-BuildTagLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [current-build] $Message"
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

try {
    if (-not (Test-Path -LiteralPath $CurrentReleaseStatePath)) {
        Write-BuildTagLog "No current release state found at '$CurrentReleaseStatePath'. Skipping build tag publish." 'WARN'
        exit 2
    }

    $state = Get-Content -LiteralPath $CurrentReleaseStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $zipKey = [string]$state.ZipKey
    if ([string]::IsNullOrWhiteSpace($zipKey)) {
        Write-BuildTagLog "Current release state at '$CurrentReleaseStatePath' has no ZipKey. Skipping build tag publish." 'WARN'
        exit 2
    }

    $buildName = Split-Path -Leaf $zipKey
    if ([string]::IsNullOrWhiteSpace($buildName)) {
        Write-BuildTagLog "Could not derive build name from ZipKey '$zipKey'. Skipping build tag publish." 'WARN'
        exit 2
    }

    $tagArgs = @(
        'ec2', 'create-tags',
        '--region', $Region,
        '--resources', $InstanceId,
        '--tags',
        ("Key=ScaleWorldCurrentBuild,Value={0}" -f (Normalize-TagValue $buildName))
    )

    $activatedAtUtc = [string]$state.ActivatedAtUtc
    if (-not [string]::IsNullOrWhiteSpace($activatedAtUtc)) {
        $tagArgs += ("Key=ScaleWorldLastUpdatedAtUtc,Value={0}" -f (Normalize-TagValue $activatedAtUtc))
    }

    & $AwsCliPath @tagArgs *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI exited with code $LASTEXITCODE."
    }

    Write-BuildTagLog "Published build tag '$buildName' for instance '$InstanceId'."
    exit 0
}
catch {
    Write-BuildTagLog "Failed to publish current build tags: $($_.Exception.Message)" 'ERROR'
    exit 1
}
