param(
    [ValidateSet("dev", "stage", "prod", "nonprod")]
    [string]$Track = "dev",
    [string]$TargetRef,
    [string]$ParameterName,
    [string]$Region = "eu-north-1",
    [switch]$UseHeadSha,
    [switch]$CreateTag,
    [string]$DateStamp,
    [switch]$SkipFetchTags,
    [switch]$AllowDirty,
    [switch]$DryRun,
    [switch]$Force
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

function Invoke-NativeCommandCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $stdout = if (Test-Path -LiteralPath $stdoutPath) {
            (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
        } else {
            ""
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
        } else {
            ""
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

function Invoke-GitCapture {
    param([string[]]$Arguments)

    $git = Get-Command git -ErrorAction Stop
    $result = Invoke-NativeCommandCapture -FilePath $git.Source -Arguments (@("-C", $repoRootPath) + $Arguments)
    if ($result.ExitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed. $($result.Combined)"
    }

    return $result.StdOut.Trim()
}

function Try-Invoke-GitCapture {
    param([string[]]$Arguments)

    try {
        return Invoke-GitCapture -Arguments $Arguments
    } catch {
        return $null
    }
}

function Get-NormalizedDateStamp {
    param([string]$ExplicitDateStamp)

    $normalized = Normalize-Optional $ExplicitDateStamp
    if ($normalized) {
        if ($normalized -notmatch '^\d{8}$') {
            throw "DateStamp '$normalized' must use yyyyMMdd format."
        }

        return $normalized
    }

    return Get-Date -Format "yyyyMMdd"
}

function Get-NextTargetTagName {
    param(
        [string]$DeploymentTrack,
        [string]$ExplicitDateStamp
    )

    $datePart = Get-NormalizedDateStamp -ExplicitDateStamp $ExplicitDateStamp
    $tagBase = "pixelstreaming-$DeploymentTrack-$datePart"
    $existingTagsText = Invoke-GitCapture -Arguments @("tag", "--list", "$tagBase*")
    $existingTags = @()
    if (-not [string]::IsNullOrWhiteSpace($existingTagsText)) {
        $existingTags = $existingTagsText -split "(`r`n|`n|`r)" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    }

    $pattern = "^$([regex]::Escape($tagBase))([a-z])$"
    $maxIndex = -1
    foreach ($tag in $existingTags) {
        $match = [regex]::Match($tag.Trim(), $pattern)
        if (-not $match.Success) {
            continue
        }

        $suffix = $match.Groups[1].Value
        $index = [int][char]$suffix - [int][char]'a'
        if ($index -gt $maxIndex) {
            $maxIndex = $index
        }
    }

    $nextIndex = $maxIndex + 1
    if ($nextIndex -gt 25) {
        throw "All tag suffixes for '$tagBase' are already used."
    }

    $nextSuffix = [char]([int][char]'a' + $nextIndex)
    return "$tagBase$nextSuffix"
}

function Confirm-ProdTargetRefUpdate {
    param(
        [string]$TargetRefValue,
        [switch]$WillCreateTag
    )

    if ($WillCreateTag) {
        Write-Warning "This will create and push '$TargetRefValue', then update the prod PixelStreaming git-target-ref SSM parameter."
        $tagConfirmation = Read-Host "Type the exact tag name to continue"
        if ($tagConfirmation -cne $TargetRefValue) {
            throw "Prod target ref update cancelled."
        }
    } else {
        Write-Warning "This will update the prod PixelStreaming git-target-ref SSM parameter to '$TargetRefValue'."
    }

    $confirmation = Read-Host "Type PROD to update prod"
    if ($confirmation -cne "PROD") {
        throw "Prod target ref update cancelled."
    }
}

function Get-DefaultParameterName {
    param([string]$DeploymentTrack)

    switch ($DeploymentTrack) {
        "dev" { return "/pixelstreaming/dev/git-target-ref" }
        "stage" { return "/pixelstreaming/stage/git-target-ref" }
        "prod" { return "/pixelstreaming/prod/git-target-ref" }
        "nonprod" { return "/pixelstreaming/nonprod/git-target-ref" }
        default { throw "Unsupported deployment track '$DeploymentTrack'." }
    }
}

function Resolve-TargetRef {
    param(
        [string]$ExplicitTargetRef,
        [switch]$PreferHeadSha
    )

    $normalized = Normalize-Optional $ExplicitTargetRef
    if ($normalized) {
        return $normalized
    }

    if ($PreferHeadSha) {
        return Invoke-GitCapture -Arguments @("rev-parse", "HEAD")
    }

    $branch = Invoke-GitCapture -Arguments @("branch", "--show-current")
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        return $branch
    }

    return Invoke-GitCapture -Arguments @("rev-parse", "HEAD")
}

$parameterNameValue = Normalize-Optional $ParameterName
if (-not $parameterNameValue) {
    $parameterNameValue = Get-DefaultParameterName -DeploymentTrack $Track
}

if ($parameterNameValue -notmatch '^/pixelstreaming/.+/git-target-ref$') {
    throw "ParameterName '$parameterNameValue' must be a PixelStreaming git-target-ref parameter."
}

$currentCommit = Invoke-GitCapture -Arguments @("rev-parse", "HEAD")
$currentBranch = Invoke-GitCapture -Arguments @("branch", "--show-current")
$workingTreeStatus = Invoke-GitCapture -Arguments @("status", "--porcelain")

if ($CreateTag) {
    if (Normalize-Optional $TargetRef) {
        throw "Do not pass TargetRef when CreateTag is set. The script generates the next git target tag automatically."
    }

    if ($UseHeadSha) {
        throw "UseHeadSha cannot be combined with CreateTag."
    }

    if (-not $SkipFetchTags -and -not $DryRun) {
        Write-Host "Fetching tags from origin before selecting the next target ref..."
        Invoke-GitCapture -Arguments @("fetch", "origin", "--tags", "--prune") | Out-Null
    }

    $targetRefValue = Get-NextTargetTagName -DeploymentTrack $Track -ExplicitDateStamp $DateStamp
} else {
    $targetRefValue = Resolve-TargetRef -ExplicitTargetRef $TargetRef -PreferHeadSha:$UseHeadSha
}

if ($targetRefValue -notmatch '^[A-Za-z0-9._/\-]+$') {
    throw "Target ref '$targetRefValue' contains unsupported characters. Use a branch, tag, or commit-like ref."
}

Write-Host "PixelStreaming repo: $repoRootPath"
Write-Host "Current commit: $currentCommit"
Write-Host "Selected target ref: $targetRefValue" -ForegroundColor Cyan
Write-Host "Target parameter: $parameterNameValue"
Write-Host "AWS region: $Region"

if (-not [string]::IsNullOrWhiteSpace($workingTreeStatus)) {
    if ($CreateTag -and -not $AllowDirty) {
        throw "The PixelStreaming working tree has uncommitted changes. Commit or stash them before creating a new target tag, or pass -AllowDirty."
    }

    Write-Warning "The PixelStreaming working tree has uncommitted changes. Startup sync can only fetch committed code."
}

if (-not $CreateTag -and -not [string]::IsNullOrWhiteSpace($currentBranch) -and $targetRefValue -eq $currentBranch) {
    $upstream = Try-Invoke-GitCapture -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if ([string]::IsNullOrWhiteSpace($upstream)) {
        Write-Warning "Current branch '$currentBranch' has no configured upstream. Hosted instances may not be able to fetch it."
    } else {
        $aheadBehind = Try-Invoke-GitCapture -Arguments @("rev-list", "--left-right", "--count", "$upstream...HEAD")
        if (-not [string]::IsNullOrWhiteSpace($aheadBehind)) {
            $parts = $aheadBehind -split "\s+"
            if ($parts.Count -ge 2 -and [int]$parts[1] -gt 0) {
                Write-Warning "Current branch '$currentBranch' is $($parts[1]) commit(s) ahead of '$upstream'. Push the branch before expecting hosted instances to fetch those commits."
            }
        }
    }
}

if ($DryRun) {
    if ($CreateTag) {
        Write-Host "Dry run only. The tag was not created or pushed, and SSM was not updated." -ForegroundColor Yellow
    } else {
        Write-Host "Dry run only. SSM was not updated." -ForegroundColor Yellow
    }

    return
}

if ($Track -eq "prod" -and -not $Force) {
    Confirm-ProdTargetRefUpdate -TargetRefValue $targetRefValue -WillCreateTag:$CreateTag
}

if ($CreateTag) {
    Write-Host "Creating git tag '$targetRefValue' at $currentCommit..."
    Invoke-GitCapture -Arguments @("tag", $targetRefValue, $currentCommit) | Out-Null

    Write-Host "Pushing git tag '$targetRefValue' to origin..."
    Invoke-GitCapture -Arguments @("push", "origin", "refs/tags/$targetRefValue") | Out-Null
    Write-Host "Pushed git tag '$targetRefValue'." -ForegroundColor Green
}

$aws = Get-AwsCliPath
if (-not $aws) {
    throw "AWS CLI was not found. Install AWS CLI or add it to PATH."
}

$putResult = Invoke-NativeCommandCapture -FilePath $aws -Arguments @(
    "ssm",
    "put-parameter",
    "--name",
    $parameterNameValue,
    "--type",
    "String",
    "--value",
    $targetRefValue,
    "--overwrite",
    "--region",
    $Region)

if ($putResult.ExitCode -ne 0) {
    throw "Failed to update SSM parameter '$parameterNameValue'. $($putResult.Combined)"
}

Write-Host "Updated $parameterNameValue to $targetRefValue." -ForegroundColor Green

$getResult = Invoke-NativeCommandCapture -FilePath $aws -Arguments @(
    "ssm",
    "get-parameter",
    "--name",
    $parameterNameValue,
    "--region",
    $Region,
    "--query",
    "Parameter.Value",
    "--output",
    "text")

if ($getResult.ExitCode -eq 0) {
    Write-Host "Verified parameter value: $($getResult.StdOut.Trim())" -ForegroundColor Green
} else {
    Write-Warning "Parameter was updated, but verification read failed. AWS output: $($getResult.Combined)"
}
