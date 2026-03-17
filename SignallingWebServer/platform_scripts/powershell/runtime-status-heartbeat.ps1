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
            StdOut = $stdout
            StdErr = $stderr
            Combined = (@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$TargetRegion,
        [string]$TargetInstanceId,
        [hashtable]$Tags
    )

    if (-not $Tags -or $Tags.Count -eq 0) {
        return
    }

    $tagPayload = foreach ($key in $Tags.Keys) {
        @{
            Key = [string]$key
            Value = Normalize-TagValue ([string]$Tags[$key])
        }
    }

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            ($tagPayload | ConvertTo-Json -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $args = @(
            'ec2', 'create-tags',
            '--region', $TargetRegion,
            '--resources', $TargetInstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )

        $result = Invoke-AwsCliCapture -AwsCli $AwsCli -Arguments $args
        if ($result.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                throw "Failed to set EC2 tags for $TargetInstanceId. AWS CLI exited with code $($result.ExitCode)."
            }

            throw "Failed to set EC2 tags for $TargetInstanceId. $($result.Combined)"
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Publish-Heartbeat {
    param([pscustomobject]$State)

    if (-not $State) {
        return
    }

    $heartbeatAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $statusAtUtc = if ([string]::IsNullOrWhiteSpace($State.StatusAtUtc)) { $heartbeatAtUtc } else { $State.StatusAtUtc }
    Set-InstanceTags -AwsCli $AwsCliPath -TargetRegion $Region -TargetInstanceId $InstanceId -Tags @{
        ScaleWorldRuntimeStatus = $State.Status
        ScaleWorldRuntimeStatusAtUtc = $statusAtUtc
        ScaleWorldRuntimeStatusHeartbeatAtUtc = $heartbeatAtUtc
        ScaleWorldRuntimeStatusSource = $State.Source
        ScaleWorldRuntimeStatusReason = $State.Reason
        ScaleWorldRuntimeStatusVersion = $State.Version
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
