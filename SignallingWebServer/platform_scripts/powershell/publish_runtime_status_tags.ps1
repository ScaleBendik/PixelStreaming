[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,
    [Parameter(Mandatory = $true)]
    [string]$Region,
    [Parameter(Mandatory = $true)]
    [string]$Status,
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Reason,
    [string]$Version = '',
    [string]$StatusAtUtc = '',
    [string]$AwsCliPath = $(if ($env:RUNTIME_STATUS_AWS_CLI_PATH) { $env:RUNTIME_STATUS_AWS_CLI_PATH } else { 'aws' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-RuntimeStatusLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [runtime-status-tags] $Message"
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

try {
    $heartbeatAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $effectiveStatusAtUtc =
        if ([string]::IsNullOrWhiteSpace($StatusAtUtc)) {
            $heartbeatAtUtc
        } else {
            $StatusAtUtc
        }

    Set-InstanceTags -AwsCli $AwsCliPath -TargetRegion $Region -TargetInstanceId $InstanceId -Tags @{
        ScaleWorldRuntimeStatus = $Status
        ScaleWorldRuntimeStatusAtUtc = $effectiveStatusAtUtc
        ScaleWorldRuntimeStatusHeartbeatAtUtc = $heartbeatAtUtc
        ScaleWorldRuntimeStatusSource = $Source
        ScaleWorldRuntimeStatusReason = $Reason
        ScaleWorldRuntimeStatusVersion = $Version
    }

    Write-RuntimeStatusLog "Published runtime status '$Status' for instance '$InstanceId'."
    exit 0
} catch {
    Write-RuntimeStatusLog "Failed to publish runtime status '$Status': $($_.Exception.Message)" 'ERROR'
    exit 1
}
