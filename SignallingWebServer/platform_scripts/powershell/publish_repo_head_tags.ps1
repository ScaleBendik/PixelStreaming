[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,
    [Parameter(Mandatory = $true)]
    [string]$Region,
    [Parameter(Mandatory = $true)]
    [string]$CurrentRepoHead,
    [string]$CurrentVersion = '',
    [string]$AwsCliPath = $(if ($env:RUNTIME_STATUS_AWS_CLI_PATH) { $env:RUNTIME_STATUS_AWS_CLI_PATH } else { 'aws' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-RepoHeadTagLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [repo-head] $Message"
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

function Publish-TagPayload {
    param(
        [Parameter(Mandatory = $true)]
        [array]$TagPayload
    )

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            (ConvertTo-Json -InputObject @($TagPayload) -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $tagArgs = @(
            'ec2', 'create-tags',
            '--region', $Region,
            '--resources', $InstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )

        return Invoke-AwsCliCapture -AwsCli $AwsCliPath -Arguments $tagArgs
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-TagKeys {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$TagKeys
    )

    if ($TagKeys.Count -eq 0) {
        return $null
    }

    $tagPayload = $TagKeys | ForEach-Object {
        @{
            Key = $_
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
            'ec2', 'delete-tags',
            '--region', $Region,
            '--resources', $InstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )

        return Invoke-AwsCliCapture -AwsCli $AwsCliPath -Arguments $tagArgs
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

try {
    $normalizedHead = Normalize-TagValue $CurrentRepoHead
    if ([string]::IsNullOrWhiteSpace($normalizedHead)) {
        Write-RepoHeadTagLog 'No repo head was provided. Skipping repo head tag publish.' 'WARN'
        exit 2
    }

    $headTagPayload = @(
        @{
            Key = 'ScaleWorldRuntimeRepoHead'
            Value = $normalizedHead
        }
    )

    $headResult = Publish-TagPayload -TagPayload $headTagPayload
    if ($headResult.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($headResult.Combined)) {
            throw "AWS CLI exited with code $($headResult.ExitCode) while publishing ScaleWorldRuntimeRepoHead."
        }

        throw $headResult.Combined
    }

    $deliveryModeResult = Publish-TagPayload -TagPayload @(
        @{
            Key = 'ScaleWorldPixelStreamingDeliveryMode'
            Value = 'git_ref'
        }
    )
    if ($deliveryModeResult.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($deliveryModeResult.Combined)) {
            Write-RepoHeadTagLog "Published repo head '$normalizedHead', but failed to publish PixelStreaming delivery mode 'git_ref' for instance '$InstanceId'. AWS CLI exited with code $($deliveryModeResult.ExitCode)." 'WARN'
        } else {
            Write-RepoHeadTagLog "Published repo head '$normalizedHead', but failed to publish PixelStreaming delivery mode 'git_ref' for instance '$InstanceId'. $($deliveryModeResult.Combined)" 'WARN'
        }
    }

    $clearRuntimeIdentityResult = Remove-TagKeys -TagKeys @(
        'ScaleWorldPixelStreamingRuntimeBundleId',
        'ScaleWorldPixelStreamingRuntimeManifestKey',
        'ScaleWorldPixelStreamingRuntimeArtifactKey',
        'ScaleWorldPixelStreamingRuntimeSourceCommit',
        'ScaleWorldPixelStreamingRuntimeContractVersion'
    )
    if ($clearRuntimeIdentityResult -and $clearRuntimeIdentityResult.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($clearRuntimeIdentityResult.Combined)) {
            Write-RepoHeadTagLog "Published repo head '$normalizedHead', but failed to clear stale PixelStreaming runtime artifact identity tags for instance '$InstanceId'. AWS CLI exited with code $($clearRuntimeIdentityResult.ExitCode)." 'WARN'
        } else {
            Write-RepoHeadTagLog "Published repo head '$normalizedHead', but failed to clear stale PixelStreaming runtime artifact identity tags for instance '$InstanceId'. $($clearRuntimeIdentityResult.Combined)" 'WARN'
        }
    }

    $normalizedVersion = Normalize-TagValue $CurrentVersion
    if (-not [string]::IsNullOrWhiteSpace($normalizedVersion)) {
        $versionResult = Publish-TagPayload -TagPayload @(
            @{
                Key = 'ScaleWorldPixelStreamingVersion'
                Value = $normalizedVersion
            }
        )

        if ($versionResult.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($versionResult.Combined)) {
                Write-RepoHeadTagLog "Published repo head '$normalizedHead', but failed to publish PixelStreaming version '$normalizedVersion' for instance '$InstanceId'. AWS CLI exited with code $($versionResult.ExitCode)." 'WARN'
            } else {
                Write-RepoHeadTagLog "Published repo head '$normalizedHead', but failed to publish PixelStreaming version '$normalizedVersion' for instance '$InstanceId'. $($versionResult.Combined)" 'WARN'
            }
            exit 0
        }

        Write-RepoHeadTagLog "Published repo head '$normalizedHead' and PixelStreaming version '$normalizedVersion' for instance '$InstanceId'."
    } else {
        Write-RepoHeadTagLog "Published repo head '$normalizedHead' for instance '$InstanceId'."
    }
    exit 0
}
catch {
    Write-RepoHeadTagLog "Failed to publish repo head tags: $($_.Exception.Message)" 'ERROR'
    exit 1
}
