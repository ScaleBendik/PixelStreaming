[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,
    [Parameter(Mandatory = $true)]
    [string]$Region,
    [Parameter(Mandatory = $true)]
    [string]$StateFilePath,
    [Parameter(Mandatory = $true)]
    [string]$StopFilePath,
    [string]$AwsCliPath = 'aws',
    [int]$IntervalSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HeartbeatLog {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [startup-heartbeat] $Message"
}

function Read-StateFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ($line -match '^(?<Key>[^=]+)=(?<Value>.*)$') {
            $map[$matches.Key] = $matches.Value
        }
    }

    if (-not $map.ContainsKey('status') -or [string]::IsNullOrWhiteSpace($map.status)) {
        return $null
    }

    return [pscustomobject]@{
        Status = [string]$map.status
        Source = [string]$map.source
        Reason = [string]$map.reason
        Version = [string]$map.version
        StatusAtUtc = [string]$map.status_at_utc
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

function Publish-Heartbeat {
    param([pscustomobject]$State)

    if (-not $State) {
        return
    }

    $heartbeatAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $statusAtUtc = if ([string]::IsNullOrWhiteSpace($State.StatusAtUtc)) { $heartbeatAtUtc } else { $State.StatusAtUtc }

    $args = @(
        'ec2', 'create-tags',
        '--region', $Region,
        '--resources', $InstanceId,
        '--tags',
        ("Key=ScaleWorldRuntimeStatus,Value={0}" -f (Normalize-TagValue $State.Status)),
        ("Key=ScaleWorldRuntimeStatusAtUtc,Value={0}" -f $statusAtUtc),
        ("Key=ScaleWorldRuntimeStatusHeartbeatAtUtc,Value={0}" -f $heartbeatAtUtc),
        ("Key=ScaleWorldRuntimeStatusSource,Value={0}" -f (Normalize-TagValue $State.Source)),
        ("Key=ScaleWorldRuntimeStatusReason,Value={0}" -f (Normalize-TagValue $State.Reason)),
        ("Key=ScaleWorldRuntimeStatusVersion,Value={0}" -f (Normalize-TagValue $State.Version))
    )

    $output = & $AwsCliPath @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output | Out-String).Trim()
    }
}

Write-HeartbeatLog "Watching startup status file '$StateFilePath' every $IntervalSeconds seconds."

try {
    while (-not (Test-Path -LiteralPath $StopFilePath)) {
        $state = Read-StateFile -Path $StateFilePath
        if ($state) {
            Publish-Heartbeat -State $state
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
} catch {
    Write-HeartbeatLog $_.Exception.Message 'WARN'
} finally {
    Write-HeartbeatLog 'Startup heartbeat loop stopped.'
}
