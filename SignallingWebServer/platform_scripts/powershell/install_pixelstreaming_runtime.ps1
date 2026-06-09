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
        SourceRef = Normalize-Optional ($manifest.sourceRef -as [string])
        ContractVersion = Normalize-Optional ($manifest.scaleWorldContractVersion -as [string])
    }
}

function Get-InstalledRuntimeMarkerPath {
    param([string]$BundleRoot)

    return Join-Path $BundleRoot ".scaleworld-runtime-installed.json"
}

function Test-RequiredRuntimeFile {
    param(
        [string]$BundleRoot,
        [string]$RelativePath
    )

    return Test-Path -LiteralPath (Join-Path $BundleRoot $RelativePath) -PathType Leaf
}

function Test-InstalledRuntimeBundle {
    param(
        [string]$BundleRoot,
        [object]$ExpectedManifest
    )

    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        return $false
    }

    $markerPath = Get-InstalledRuntimeMarkerPath -BundleRoot $BundleRoot
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-Host "Runtime bundle '$($ExpectedManifest.BundleId)' exists without an install completion marker. Reinstalling." -ForegroundColor Yellow
        return $false
    }

    $installedManifestPath = Join-Path $BundleRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
        Write-Host "Runtime bundle '$($ExpectedManifest.BundleId)' is missing manifest.json. Reinstalling." -ForegroundColor Yellow
        return $false
    }

    try {
        $installedManifest = Read-RuntimeManifest -Path $installedManifestPath
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Runtime bundle '$($ExpectedManifest.BundleId)' has unreadable install metadata. Reinstalling." -ForegroundColor Yellow
        return $false
    }

    $expectedRuntimeZipSha256 = ($ExpectedManifest.RuntimeZipSha256 -as [string])
    $installedRuntimeZipSha256 = ($installedManifest.RuntimeZipSha256 -as [string])
    $markerRuntimeZipSha256 = ($marker.runtimeZipSha256 -as [string])

    if (($installedManifest.BundleId -as [string]) -ne ($ExpectedManifest.BundleId -as [string]) -or
        ($installedManifest.RuntimeZipKey -as [string]) -ne ($ExpectedManifest.RuntimeZipKey -as [string]) -or
        $installedRuntimeZipSha256 -ne $expectedRuntimeZipSha256 -or
        ($marker.bundleId -as [string]) -ne ($ExpectedManifest.BundleId -as [string]) -or
        ($marker.runtimeZipKey -as [string]) -ne ($ExpectedManifest.RuntimeZipKey -as [string]) -or
        $markerRuntimeZipSha256 -ne $expectedRuntimeZipSha256) {
        Write-Host "Runtime bundle '$($ExpectedManifest.BundleId)' metadata does not match the requested manifest. Reinstalling." -ForegroundColor Yellow
        return $false
    }

    $requiredFiles = @(
        "runtime-bundle-metadata.json",
        "package.json",
        "SignallingWebServer\config.json",
        "SignallingWebServer\package.json",
        "SignallingWebServer\peer_options.player.json",
        "SignallingWebServer\peer_options.streamer.json",
        "SignallingWebServer\dist\index.js",
        "SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat",
        "SignallingWebServer\platform_scripts\cmd\start_dev_turn.bat",
        "SignallingWebServer\platform_scripts\powershell\watchdog.ps1"
    )

    foreach ($relativePath in $requiredFiles) {
        if (-not (Test-RequiredRuntimeFile -BundleRoot $BundleRoot -RelativePath $relativePath)) {
            Write-Host "Runtime bundle '$($ExpectedManifest.BundleId)' is missing '$relativePath'. Reinstalling." -ForegroundColor Yellow
            return $false
        }
    }

    return $true
}

function Write-InstalledRuntimeMarker {
    param(
        [string]$BundleRoot,
        [object]$Manifest
    )

    $markerPath = Get-InstalledRuntimeMarkerPath -BundleRoot $BundleRoot
    $marker = [ordered]@{
        schemaVersion = 1
        bundleId = $Manifest.BundleId
        runtimeZipKey = $Manifest.RuntimeZipKey
        runtimeZipSha256 = $Manifest.RuntimeZipSha256
        installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    ($marker | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $markerPath -Encoding ASCII
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

function Get-NormalizedFullPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-ActiveRuntimeTarget {
    param([string]$ActiveRoot)

    if (-not (Test-Path -LiteralPath $ActiveRoot)) {
        return $null
    }

    $activeItem = Get-Item -LiteralPath $ActiveRoot -Force
    if (($activeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        return Get-NormalizedFullPath -Path $ActiveRoot
    }

    $target = @($activeItem.Target | Select-Object -First 1)[0]
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    return Get-NormalizedFullPath -Path ([string]$target)
}

function Add-ProtectedRuntimeRoot {
    param(
        [hashtable]$Map,
        [string]$Path
    )

    $normalized = Get-NormalizedFullPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }

    $Map[$normalized.ToLowerInvariant()] = $true
}

function Test-ProtectedRuntimeRoot {
    param(
        [hashtable]$Map,
        [string]$Path
    )

    $normalized = Get-NormalizedFullPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    return $Map.ContainsKey($normalized.ToLowerInvariant())
}

function Get-LiveRuntimeReleaseRoots {
    param([string]$ReleasesRoot)

    $liveRoots = @{}
    $releaseDirectories = @(Get-ChildItem -LiteralPath $ReleasesRoot -Directory -ErrorAction SilentlyContinue)
    if ($releaseDirectories.Count -eq 0) {
        return $liveRoots
    }

    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        Write-Warning "Could not inspect live process command lines before runtime pruning: $($_.Exception.Message)"
        return $liveRoots
    }

    foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        foreach ($directory in $releaseDirectories) {
            $directoryFull = Get-NormalizedFullPath -Path $directory.FullName
            if ([string]::IsNullOrWhiteSpace($directoryFull)) {
                continue
            }

            if ($commandLine.IndexOf($directoryFull, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $liveRoots[$directoryFull.ToLowerInvariant()] = $true
            }
        }
    }

    return $liveRoots
}

function Clear-DirectoryChildrenBestEffort {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            if ($child.PSIsContainer) {
                Remove-DirectoryBestEffort -Path $child.FullName
            } else {
                try {
                    $child.Attributes = [System.IO.FileAttributes]::Normal
                } catch {
                }

                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning "Runtime cache item '$($child.FullName)' could not be removed: $($_.Exception.Message)"
        }
    }
}

function Prune-InactiveRuntimeArtifacts {
    param(
        [string]$InstallRoot,
        [string]$ReleasesRoot,
        [string]$ActiveRoot,
        [string]$KeepBundleRoot,
        [string]$ScratchRoot,
        [string]$StagingParentRoot
    )

    Assert-ChildPath -Parent $InstallRoot -Child $ReleasesRoot
    Assert-ChildPath -Parent $InstallRoot -Child $ScratchRoot

    $protectedRoots = @{}
    Add-ProtectedRuntimeRoot -Map $protectedRoots -Path $KeepBundleRoot
    Add-ProtectedRuntimeRoot -Map $protectedRoots -Path (Get-ActiveRuntimeTarget -ActiveRoot $ActiveRoot)

    $liveRuntimeRoots = Get-LiveRuntimeReleaseRoots -ReleasesRoot $ReleasesRoot
    foreach ($key in $liveRuntimeRoots.Keys) {
        $protectedRoots[$key] = $true
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $ReleasesRoot -Directory -ErrorAction SilentlyContinue)) {
        if (Test-ProtectedRuntimeRoot -Map $protectedRoots -Path $directory.FullName) {
            Write-Host "Preserving runtime release '$($directory.FullName)'."
            continue
        }

        Write-Host "Removing inactive runtime release '$($directory.FullName)'."
        Remove-DirectoryBestEffort -Path $directory.FullName
    }

    Clear-DirectoryChildrenBestEffort -Path $ScratchRoot
    $installRootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    $stagingParentFull = [System.IO.Path]::GetFullPath($StagingParentRoot).TrimEnd('\') + '\'
    if ($stagingParentFull.StartsWith($installRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Clear-DirectoryChildrenBestEffort -Path $StagingParentRoot
    } else {
        Write-Warning "Skipping external runtime staging cleanup for '$StagingParentRoot'."
    }
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

if ((-not $ForceReinstall) -and (Test-InstalledRuntimeBundle -BundleRoot $bundleRoot -ExpectedManifest $manifest)) {
    Write-Host "Runtime bundle '$($manifest.BundleId)' is already installed and verified. Skipping extraction." -ForegroundColor DarkCyan
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
        Remove-Item -LiteralPath (Get-InstalledRuntimeMarkerPath -BundleRoot $bundleRoot) -Force -ErrorAction SilentlyContinue
        Remove-DirectoryBestEffort -Path $bundleRoot
        if (Test-Path -LiteralPath $bundleRoot) {
            Write-Warning "Runtime bundle root '$bundleRoot' could not be fully removed. Overwriting files in place."
        }
    }

    Invoke-Robocopy -Source $stagingRoot -Destination $bundleRoot
    Write-InstalledRuntimeMarker -BundleRoot $bundleRoot -Manifest $manifest
    Remove-DirectoryBestEffort -Path $stagingRoot
}

if (-not (Test-InstalledRuntimeBundle -BundleRoot $bundleRoot -ExpectedManifest $manifest)) {
    throw "Runtime bundle '$($manifest.BundleId)' did not pass installed-bundle validation."
}

if ($Activate) {
    Set-ActiveRuntimePointer -ActiveRoot $activeRoot -TargetRoot $bundleRoot
    Prune-InactiveRuntimeArtifacts `
        -InstallRoot $installRootFull `
        -ReleasesRoot $releasesRoot `
        -ActiveRoot $activeRoot `
        -KeepBundleRoot $bundleRoot `
        -ScratchRoot $scratchRoot `
        -StagingParentRoot $stagingParentRoot
}

$result = [pscustomobject]@{
    BundleId = $manifest.BundleId
    RuntimeZipKey = $manifest.RuntimeZipKey
    ManifestS3Key = $manifestS3Key
    SourceCommit = $manifest.SourceCommit
    SourceRef = $manifest.SourceRef
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
