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
            ($TagPayload | ConvertTo-Json -Compress -Depth 4),
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
