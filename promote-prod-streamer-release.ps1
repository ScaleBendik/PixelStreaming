[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$RemoteName = 'origin',
    [string]$Region = '',
    [string]$TargetRefParameterName = '/pixelstreaming/prod/git-target-ref',
    [string]$TagName = '',
    [datetime]$PromotionDate = (Get-Date),
    [string]$LedgerPath = '',
    [string]$Notes = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = $scriptRoot
}

if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
    $LedgerPath = Join-Path $scriptRoot 'Docs\prod-promotions.md'
}

function Write-PromotionLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [prod-promotion] $Message"
}

function Get-GitCliPath {
    $candidate = Get-Command git -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "Git ('git') was not found."
}

function Get-AwsCliPath {
    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
        'C:\Program Files\Amazon\AWSCLI\bin\aws.exe'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "AWS CLI ('aws') was not found."
}

function Resolve-Region {
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:AWS_REGION)) {
        return $env:AWS_REGION.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:AWS_DEFAULT_REGION)) {
        return $env:AWS_DEFAULT_REGION.Trim()
    }

    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
    return (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
}

function Invoke-ExternalCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
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

function Invoke-GitText {
    param(
        [string]$GitCli,
        [string[]]$Arguments,
        [string]$ErrorMessage
    )

    $result = Invoke-ExternalCapture -FilePath $GitCli -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($result.Combined)) {
            throw $ErrorMessage
        }

        throw "$ErrorMessage $($result.Combined)"
    }

    return $result.StdOut
}

function Get-RepoRelativePath {
    param(
        [string]$RepoRoot,
        [string]$Path
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    $targetFullPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }

    $rootPrefix = $rootFullPath + '\'
    if (-not $targetFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' is outside repo root '$RepoRoot'."
    }

    return ($targetFullPath.Substring($rootPrefix.Length) -replace '\\', '/')
}

function Test-TrackedWorktreeClean {
    param(
        [string]$GitCli,
        [string[]]$IgnoredPaths = @()
    )

    $diff = Invoke-GitText -GitCli $GitCli -Arguments @('diff', '--name-only', '--relative', 'HEAD') -ErrorMessage 'Failed to inspect git worktree state.'
    $changedPaths = @($diff -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_ -replace '\\', '/').Trim() })
    if ($changedPaths.Count -eq 0) {
        return $true
    }

    $ignored = @{}
    foreach ($path in $IgnoredPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $ignored[$path.Trim().Replace('\', '/')] = $true
    }

    $remaining = @($changedPaths | Where-Object { -not $ignored.ContainsKey($_) })
    return $remaining.Count -eq 0
}

function Get-NextPromotionTagName {
    param(
        [string]$GitCli,
        [datetime]$Date
    )

    $dateToken = $Date.ToString('ddMMyyyy')
    $prefix = "pixelstreaming-prod-$dateToken"
    $rawTags = Invoke-GitText -GitCli $GitCli -Arguments @('tag', '--list', "$prefix*") -ErrorMessage "Failed to list existing promotion tags for $dateToken."
    $tags = @($rawTags -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $highestLetter = $null
    foreach ($tag in $tags) {
        if ($tag -match "^pixelstreaming-prod-$dateToken(?<suffix>[a-z])$") {
            $candidate = [char]$Matches['suffix']
            if (-not $highestLetter -or [int][char]$candidate -gt [int][char]$highestLetter) {
                $highestLetter = $candidate
            }
        }
    }

    if (-not $highestLetter) {
        return "$prefix" + 'a'
    }

    if ($highestLetter -eq 'z') {
        throw "Tag sequence for $dateToken is exhausted. Manual tag name required."
    }

    $nextLetter = [char]([int][char]$highestLetter + 1)
    return "$prefix$nextLetter"
}

function Validate-TagName {
    param([string]$Value)

    if ($Value -notmatch '^pixelstreaming-prod-\d{8}[a-z]$') {
        throw "Tag name '$Value' does not match the required format 'pixelstreaming-prod-ddmmyyyy<letter>'."
    }
}

function Ensure-LedgerFile {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return
    }

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $header = @(
        '# Prod Streamer Promotions',
        '',
        'Canonical promotion log for the SSM-backed prod streamer target ref.',
        '',
        '| PromotedAtUtc | Tag | Commit | Region | SSM Parameter | SourceMachine | Notes |',
        '| --- | --- | --- | --- | --- | --- | --- |'
    )
    [System.IO.File]::WriteAllLines($Path, $header, (New-Object System.Text.UTF8Encoding($false)))
}

function Append-LedgerEntry {
    param(
        [string]$Path,
        [datetime]$PromotedAtUtc,
        [string]$Tag,
        [string]$Commit,
        [string]$Region,
        [string]$ParameterName,
        [string]$SourceMachine,
        [string]$Notes
    )

    Ensure-LedgerFile -Path $Path

    $safeNotes = if ([string]::IsNullOrWhiteSpace($Notes)) { '' } else { (($Notes -replace '\|', '/') -replace "[\r\n]+", '<br>') }
    $line = "| {0} | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | {6} |" -f `
        $PromotedAtUtc.ToString('yyyy-MM-dd HH:mm:ss'), `
        $Tag, `
        $Commit, `
        $Region, `
        $ParameterName, `
        $SourceMachine, `
        $safeNotes

    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

$gitCli = Get-GitCliPath
$awsCli = Get-AwsCliPath
$resolvedRepoRoot = (Resolve-Path $RepoRoot).Path
$resolvedRegion = Resolve-Region -Value $Region
$promotedAtUtc = (Get-Date).ToUniversalTime()
$ledgerRelativePath = Get-RepoRelativePath -RepoRoot $resolvedRepoRoot -Path $LedgerPath

Push-Location $resolvedRepoRoot
try {
    $isRepo = Invoke-ExternalCapture -FilePath $gitCli -Arguments @('rev-parse', '--is-inside-work-tree')
    if ($isRepo.ExitCode -ne 0 -or ($isRepo.StdOut | Out-String).Trim() -ne 'true') {
        throw "PixelStreaming root '$resolvedRepoRoot' is not a git repository."
    }

    if (-not (Test-TrackedWorktreeClean -GitCli $gitCli -IgnoredPaths @($ledgerRelativePath))) {
        throw 'Tracked local changes are present. Commit or discard them before promoting a prod streamer release.'
    }

    Write-PromotionLog "Fetching tags from remote '$RemoteName' before promotion."
    $fetchResult = Invoke-ExternalCapture -FilePath $gitCli -Arguments @('fetch', $RemoteName, '--prune', '--tags')
    if ($fetchResult.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($fetchResult.Combined)) {
            throw "Failed to fetch tags from remote '$RemoteName'."
        }

        throw "Failed to fetch tags from remote '$RemoteName'. $($fetchResult.Combined)"
    }

    $headCommit = Invoke-GitText -GitCli $gitCli -Arguments @('rev-parse', 'HEAD') -ErrorMessage 'Failed to resolve current HEAD commit.'
    if ([string]::IsNullOrWhiteSpace($TagName)) {
        $TagName = Get-NextPromotionTagName -GitCli $gitCli -Date $PromotionDate
    }

    Validate-TagName -Value $TagName

    $existingTag = Invoke-ExternalCapture -FilePath $gitCli -Arguments @('rev-parse', '--verify', '--quiet', "refs/tags/$TagName")
    if ($existingTag.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingTag.StdOut)) {
        throw "Tag '$TagName' already exists."
    }

    $annotation = @(
        "Promote PixelStreaming prod release $TagName",
        '',
        "Commit: $headCommit",
        "SSM parameter: $TargetRefParameterName",
        "Region: $resolvedRegion",
        "Promoted at (UTC): $($promotedAtUtc.ToString('o'))"
    ) -join "`n"

    $annotationPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($annotationPath, $annotation, (New-Object System.Text.UTF8Encoding($false)))

        Write-PromotionLog "Creating annotated prod promotion tag '$TagName' for HEAD $headCommit."
        $tagResult = Invoke-ExternalCapture -FilePath $gitCli -Arguments @('tag', '-a', $TagName, $headCommit, '-F', $annotationPath)
        if ($tagResult.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($tagResult.Combined)) {
                throw "Failed to create git tag '$TagName'."
            }

            throw "Failed to create git tag '$TagName'. $($tagResult.Combined)"
        }
    } finally {
        Remove-Item -LiteralPath $annotationPath -Force -ErrorAction SilentlyContinue
    }

    try {
        Write-PromotionLog "Pushing tag '$TagName' to remote '$RemoteName'."
        $pushResult = Invoke-ExternalCapture -FilePath $gitCli -Arguments @('push', $RemoteName, "refs/tags/$TagName")
        if ($pushResult.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($pushResult.Combined)) {
                throw "Failed to push tag '$TagName' to remote '$RemoteName'."
            }

            throw "Failed to push tag '$TagName' to remote '$RemoteName'. $($pushResult.Combined)"
        }

        Write-PromotionLog "Updating SSM parameter '$TargetRefParameterName' to '$TagName' in region '$resolvedRegion'."
        $putResult = Invoke-ExternalCapture -FilePath $awsCli -Arguments @(
            'ssm',
            'put-parameter',
            '--region', $resolvedRegion,
            '--name', $TargetRefParameterName,
            '--type', 'String',
            '--value', $TagName,
            '--overwrite'
        )
        if ($putResult.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($putResult.Combined)) {
                throw "Failed to update SSM parameter '$TargetRefParameterName'."
            }

            throw "Failed to update SSM parameter '$TargetRefParameterName'. $($putResult.Combined)"
        }
    } catch {
        Write-PromotionLog "Promotion failed after local tag creation. Leaving local tag '$TagName' in place for inspection." 'ERROR'
        throw
    }

    Append-LedgerEntry -Path $LedgerPath -PromotedAtUtc $promotedAtUtc -Tag $TagName -Commit $headCommit -Region $resolvedRegion -ParameterName $TargetRefParameterName -SourceMachine $env:COMPUTERNAME -Notes $Notes

    Write-PromotionLog "Prod promotion complete. Tag '$TagName' now backs SSM parameter '$TargetRefParameterName'."
} finally {
    Pop-Location
}
