param(
    [string]$BucketName = "scaleworlddepot",
    [string]$ManifestS3Key,
    [string]$ManifestPath,
    [string]$RuntimeZipPath,
    [string]$Region = "eu-north-1",
    [string]$InstallRoot = "C:\PixelStreaming",
    [string]$ResultPath,
    [switch]$Activate,
    [switch]$ForceReinstall
)

$ErrorActionPreference = "Stop"

trap {
    Write-Error "Runtime installer failed: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) {
        Write-Error $_.ScriptStackTrace
    }
    exit 1
}

function Normalize-Optional {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim()
}

function Assert-ChildPath {
    param(
        [string]$Parent,
        [string]$Child
    )

    $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $resolvedChild = [System.IO.Path]::GetFullPath($Child)
    if (-not $resolvedChild.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$resolvedChild' is outside expected parent '$resolvedParent'."
    }
}

function Invoke-AwsS3Copy {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$AwsRegion
    )

    $aws = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $aws) {
        $aws = Get-Command aws -ErrorAction SilentlyContinue
    }

    if (-not $aws) {
        throw "AWS CLI was not found."
    }

    Write-Host "Copying '$Source' to '$Destination'..."
    $output = & $aws.Source s3 cp $Source $Destination --region $AwsRegion --only-show-errors --no-progress 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Host ([string]$line)
        }
    }

    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) {
        throw "aws s3 cp failed for '$Source'."
    }
}

function Test-RuntimeZipChecksum {
    param(
        [string]$Path,
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        return $actualSha256 -eq $ExpectedSha256
    } catch {
        return $false
    }
}

function Invoke-Robocopy {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required source path '$Source' was not found."
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @($Source, $Destination, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:2", "/W:1")
    & robocopy.exe @arguments | Out-Host
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed copying '$Source' to '$Destination' with exit code $LASTEXITCODE."
    }

    $global:LASTEXITCODE = 0
}

function Remove-DirectoryBestEffort {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $_.Attributes = [System.IO.FileAttributes]::Normal
                } catch {
                    # Continue cleanup even if one extracted file cannot be normalized.
                }
            }

        try {
            $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            & icacls.exe $Path /grant "${currentIdentity}:(OI)(CI)F" /T /C 1>$null 2>$null
            $global:LASTEXITCODE = 0
        } catch {
        }

        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Runtime staging directory '$Path' could not be removed: $($_.Exception.Message)"
    }
}

function Expand-RuntimeZipArchive {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Runtime ZIP '$SourcePath' was not found."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    Write-Host "Extracting runtime ZIP to '$DestinationPath'..."
    [System.IO.Compression.ZipFile]::ExtractToDirectory(
        [System.IO.Path]::GetFullPath($SourcePath),
        [System.IO.Path]::GetFullPath($DestinationPath))
}

function Read-RuntimeManifest {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Runtime manifest '$Path' was not found."
    }

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (($manifest.artifactType -as [string]) -ne "pixelstreaming_runtime") {
        throw "Runtime manifest artifactType must be 'pixelstreaming_runtime'."
    }

    $bundleId = Normalize-Optional ($manifest.bundleId -as [string])
    $runtimeZipKey = Normalize-Optional ($manifest.runtimeZipKey -as [string])
    $runtimeZipSha256 = Normalize-Optional ($manifest.runtimeZipSha256 -as [string])

    if (-not $bundleId) {
        throw "Runtime manifest is missing bundleId."
    }

    if (-not $runtimeZipKey) {
        throw "Runtime manifest is missing runtimeZipKey."
    }

    if (-not $runtimeZipSha256) {
        throw "Runtime manifest is missing runtimeZipSha256."
    }

    if ($bundleId -match '[\\/:*?"<>|]') {
        throw "Runtime manifest bundleId '$bundleId' contains invalid path characters."
    }

    [pscustomobject]@{
        BundleId = $bundleId
        RuntimeZipKey = $runtimeZipKey
        RuntimeZipSha256 = $runtimeZipSha256.ToLowerInvariant()
        SourceCommit = Normalize-Optional ($manifest.pixelStreamingRepoCommit -as [string])
        ContractVersion = Normalize-Optional ($manifest.scaleWorldContractVersion -as [string])
    }
}

function Set-ActiveRuntimePointer {
    param(
        [string]$ActiveRoot,
        [string]$TargetRoot
    )

    $targetRootFull = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    if (Test-Path -LiteralPath $ActiveRoot) {
        $activeItem = Get-Item -LiteralPath $ActiveRoot -Force
        if (($activeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
            throw "Active runtime root '$ActiveRoot' exists and is not a junction/symlink."
        }

        $existingTarget = @($activeItem.Target | Select-Object -First 1)[0]
        if (-not [string]::IsNullOrWhiteSpace($existingTarget)) {
            $existingTargetFull = [System.IO.Path]::GetFullPath([string]$existingTarget).TrimEnd('\')
            if ([string]::Equals($existingTargetFull, $targetRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }

        $activeItem.Delete()
    }

    New-Item -ItemType Junction -Path $ActiveRoot -Target $TargetRoot | Out-Null
}

$manifestS3Key = Normalize-Optional $ManifestS3Key
$manifestPath = Normalize-Optional $ManifestPath
$runtimeZipPathOverride = Normalize-Optional $RuntimeZipPath
if (-not $manifestS3Key -and -not $manifestPath) {
    throw "Provide ManifestS3Key or ManifestPath."
}

$installRootFull = [System.IO.Path]::GetFullPath($InstallRoot)
$releasesRoot = Join-Path $installRootFull "runtime-releases"
$scratchRoot = Join-Path $installRootFull "state\runtime-updates"
$stagingParentRoot = if ($env:SCALEWORLD_RUNTIME_STAGING_ROOT) {
    [System.IO.Path]::GetFullPath($env:SCALEWORLD_RUNTIME_STAGING_ROOT)
} else {
    Join-Path $installRootFull "rt-stage"
}
$activeRoot = Join-Path $installRootFull "PixelStreamingRuntime"

New-Item -ItemType Directory -Path $releasesRoot -Force | Out-Null
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
New-Item -ItemType Directory -Path $stagingParentRoot -Force | Out-Null

if (-not $manifestPath) {
    $safeManifestName = ($manifestS3Key -replace '[\\/]', '_')
    $manifestPath = Join-Path $scratchRoot $safeManifestName
    Invoke-AwsS3Copy `
        -Source "s3://$BucketName/$manifestS3Key" `
        -Destination $manifestPath `
        -AwsRegion $Region
}

$manifest = Read-RuntimeManifest -Path $manifestPath
$bundleRoot = Join-Path $releasesRoot $manifest.BundleId
$stagingRoot = Join-Path $stagingParentRoot "$($manifest.BundleId).staging-$PID"
$downloadedRuntimeZipPath = Join-Path $scratchRoot "$($manifest.BundleId).runtime.zip"

Assert-ChildPath -Parent $releasesRoot -Child $bundleRoot
Assert-ChildPath -Parent $stagingParentRoot -Child $stagingRoot
Assert-ChildPath -Parent $scratchRoot -Child $downloadedRuntimeZipPath

if ((Test-Path -LiteralPath $bundleRoot) -and -not $ForceReinstall) {
    Write-Host "Runtime bundle '$($manifest.BundleId)' is already installed. Skipping extraction." -ForegroundColor DarkCyan
} else {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-DirectoryBestEffort -Path $stagingRoot
        if (Test-Path -LiteralPath $stagingRoot) {
            throw "Runtime staging directory '$stagingRoot' already exists and could not be removed."
        }
    }

    $runtimeZipPath = if ($runtimeZipPathOverride) {
        [System.IO.Path]::GetFullPath($runtimeZipPathOverride)
    } elseif (Test-RuntimeZipChecksum -Path $downloadedRuntimeZipPath -ExpectedSha256 $manifest.RuntimeZipSha256) {
        Write-Host "Using existing runtime ZIP '$downloadedRuntimeZipPath' because its checksum already matches the manifest."
        $downloadedRuntimeZipPath
    } else {
        Invoke-AwsS3Copy `
            -Source "s3://$BucketName/$($manifest.RuntimeZipKey)" `
            -Destination $downloadedRuntimeZipPath `
            -AwsRegion $Region
        $downloadedRuntimeZipPath
    }

    if (-not (Test-Path -LiteralPath $runtimeZipPath)) {
        throw "Runtime ZIP '$runtimeZipPath' was not found."
    }

    $actualSha256 = (Get-FileHash -LiteralPath $runtimeZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $manifest.RuntimeZipSha256) {
        throw "Runtime ZIP checksum mismatch. Expected '$($manifest.RuntimeZipSha256)', got '$actualSha256'."
    }

    Expand-RuntimeZipArchive -SourcePath $runtimeZipPath -DestinationPath $stagingRoot
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stagingRoot "manifest.json") -Force

    if (Test-Path -LiteralPath $bundleRoot) {
        Remove-DirectoryBestEffort -Path $bundleRoot
        if (Test-Path -LiteralPath $bundleRoot) {
            Write-Warning "Runtime bundle root '$bundleRoot' could not be fully removed. Overwriting files in place."
        }
    }

    Invoke-Robocopy -Source $stagingRoot -Destination $bundleRoot
    Remove-DirectoryBestEffort -Path $stagingRoot
}

if ($Activate) {
    Set-ActiveRuntimePointer -ActiveRoot $activeRoot -TargetRoot $bundleRoot
}

$result = [pscustomobject]@{
    BundleId = $manifest.BundleId
    RuntimeZipKey = $manifest.RuntimeZipKey
    ManifestS3Key = $manifestS3Key
    SourceCommit = $manifest.SourceCommit
    ContractVersion = $manifest.ContractVersion
    InstalledRoot = $bundleRoot
    ActiveRoot = if ($Activate) { $activeRoot } else { $null }
}

$resultJson = $result | ConvertTo-Json -Depth 4
$resultPath = Normalize-Optional $ResultPath
if ($resultPath) {
    $resultDirectory = Split-Path -Parent $resultPath
    if (-not [string]::IsNullOrWhiteSpace($resultDirectory)) {
        New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
    }

    Set-Content -LiteralPath $resultPath -Value $resultJson -Encoding ASCII
}

$resultJson
