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

    $tagPayload = @(
        @{
            Key = 'ScaleWorldCurrentBuild'
            Value = Normalize-TagValue $buildName
        }
    )

    $activatedAtUtc = [string]$state.ActivatedAtUtc
    if (-not [string]::IsNullOrWhiteSpace($activatedAtUtc)) {
        $tagPayload += @{
            Key = 'ScaleWorldLastUpdatedAtUtc'
            Value = Normalize-TagValue $activatedAtUtc
        }
    }

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            (ConvertTo-Json -InputObject @($tagPayload) -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $tagArgs = @(
            'ec2', 'create-tags',
            '--region', $Region,
            '--resources', $InstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )

        $result = Invoke-AwsCliCapture -AwsCli $AwsCliPath -Arguments $tagArgs
        if ($result.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                throw "AWS CLI exited with code $($result.ExitCode)."
            }

            throw $result.Combined
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }

    Write-BuildTagLog "Published build tag '$buildName' for instance '$InstanceId'."
    exit 0
}
catch {
    Write-BuildTagLog "Failed to publish current build tags: $($_.Exception.Message)" 'ERROR'
    exit 1
}
