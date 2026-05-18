[CmdletBinding()]
param(
    [string]$Region = 'eu-north-1',
    [string]$RemoteName = 'origin',
    [string]$Notes = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tagPrefix = 'pixelstreaming-dev'
$targetRefParameterName = '/pixelstreaming/dev/git-target-ref'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-PromoteDevLog {
    param([string]$Message)

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [promote-dev-tag] $Message"
}

function Get-NextDevTagName {
    param([string]$Prefix)

    $dateToken = Get-Date -Format 'yyyyMMdd'
    $existingTags = @(git tag --list "$Prefix-$dateToken*" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to list existing git tags.'
    }

    $highestSuffix = $null
    $escapedPrefix = [Regex]::Escape($Prefix)
    foreach ($tag in $existingTags) {
        if ($tag -match "^$escapedPrefix-$dateToken(?<suffix>[a-z])$") {
            $suffix = [char]$Matches['suffix']
            if (-not $highestSuffix -or [int][char]$suffix -gt [int][char]$highestSuffix) {
                $highestSuffix = $suffix
            }
        }
    }

    if (-not $highestSuffix) {
        return "$Prefix-$dateToken" + 'a'
    }

    if ($highestSuffix -eq [char]'z') {
        throw "No available tag suffix remains for $Prefix-$dateToken."
    }

    return "$Prefix-$dateToken" + [char]([int][char]$highestSuffix + 1)
}

Push-Location $scriptRoot
try {
    $isRepo = (git rev-parse --is-inside-work-tree).Trim()
    if ($LASTEXITCODE -ne 0 -or $isRepo -ne 'true') {
        throw "Script root '$scriptRoot' is not inside a git repository."
    }

    Write-PromoteDevLog "Fetching tags from '$RemoteName'."
    git fetch $RemoteName --prune --tags
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch tags from '$RemoteName'."
    }

    $tagName = Get-NextDevTagName -Prefix $tagPrefix
    $commit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'Failed to resolve HEAD.'
    }

    $message = "PixelStreaming dev target $tagName"
    if (-not [string]::IsNullOrWhiteSpace($Notes)) {
        $message = "$message`n`n$Notes"
    }

    Write-PromoteDevLog "Creating annotated tag '$tagName' at $commit."
    git tag -a $tagName -m $message
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create git tag '$tagName'."
    }

    Write-PromoteDevLog "Pushing tag '$tagName' to '$RemoteName'."
    git push $RemoteName "refs/tags/$tagName"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to push git tag '$tagName'."
    }

    Write-PromoteDevLog "Updating SSM parameter '$targetRefParameterName' to '$tagName'."
    aws ssm put-parameter `
        --region $Region `
        --name $targetRefParameterName `
        --type String `
        --value $tagName `
        --overwrite
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update SSM parameter '$targetRefParameterName'."
    }

    Write-PromoteDevLog "Done. $targetRefParameterName = $tagName"
} finally {
    Pop-Location
}
