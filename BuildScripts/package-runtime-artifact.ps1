param(
    [string]$BundleId,
    [string]$OutputRoot,
    [string]$S3Bucket = "scaleworlddepot",
    [string]$S3Prefix = "PixelStreamingRuntime",
    [string]$Region = "eu-north-1",
    [ValidateSet("full", "runtime")]
    [string]$BuildScope = "full",
    [string]$ContractVersion,
    [string[]]$Capabilities = @("runtime-status-v1", "instance-agent-bootstrap-v1"),
    [switch]$SkipBuild,
    [switch]$SkipNodeModules,
    [switch]$AllowDirty,
    [switch]$Publish
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

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Robocopy {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExtraArguments = @()
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required source path '$Source' was not found."
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @($Source, $Destination, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:2", "/W:1") + $ExtraArguments
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
                    # Continue cleanup even if one stale staged file cannot be normalized.
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
        Write-Warning "Directory '$Path' could not be removed: $($_.Exception.Message)"
    }
}

function Grant-CurrentIdentityFullControl {
    param(
        [string]$Path,
        [switch]$Container
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $permission = if ($Container) { "${currentIdentity}:(OI)(CI)F" } else { "${currentIdentity}:F" }
        & icacls.exe $Path /grant $permission /C 1>$null 2>$null
        $global:LASTEXITCODE = 0
    } catch {
    }
}

function Copy-RequiredFile {
    param(
        [string]$RelativePath,
        [string]$DestinationRoot
    )

    $source = Join-Path $repoRootPath $RelativePath
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required file '$RelativePath' was not found."
    }

    $destination = Join-Path $DestinationRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Copy-FileContent {
    param(
        [string]$Source,
        [string]$Destination
    )

    $destinationDirectory = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Destination) {
        try {
            $item = Get-Item -LiteralPath $Destination -Force
            $item.Attributes = [System.IO.FileAttributes]::Normal
        } catch {
        }
    }

    $sourceStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $destinationStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $sourceStream.CopyTo($destinationStream)
        } finally {
            $destinationStream.Dispose()
        }
    } finally {
        $sourceStream.Dispose()
    }
}

function Copy-OptionalFile {
    param(
        [string]$RelativePath,
        [string]$DestinationRoot
    )

    $source = Join-Path $repoRootPath $RelativePath
    if (-not (Test-Path -LiteralPath $source)) {
        return
    }

    $destination = Join-Path $DestinationRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Copy-RequiredDirectory {
    param(
        [string]$RelativePath,
        [string]$DestinationRoot,
        [string[]]$ExtraRobocopyArguments = @()
    )

    $source = Join-Path $repoRootPath $RelativePath
    $destination = Join-Path $DestinationRoot $RelativePath
    Invoke-Robocopy -Source $source -Destination $destination -ExtraArguments $ExtraRobocopyArguments
}

function Copy-RuntimeWorkspacePackage {
    param(
        [string]$WorkspaceRelativePath,
        [string]$PackageName,
        [string]$StageRoot
    )

    $packageRoot = Join-Path $repoRootPath $WorkspaceRelativePath
    $destination = Join-Path $StageRoot ("node_modules\@epicgames-ps\$PackageName")
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $packageRoot "package.json") -Destination (Join-Path $destination "package.json") -Force
    Invoke-Robocopy -Source (Join-Path $packageRoot "dist") -Destination (Join-Path $destination "dist")
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

    Invoke-External -FilePath $aws.Source -Arguments @("s3", "cp", $Source, $Destination, "--region", $AwsRegion)
}

function Get-NpmVersionOrNull {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        $npm = Get-Command npm -ErrorAction SilentlyContinue
    }

    if (-not $npm) {
        return $null
    }

    $version = & $npm.Source --version
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        return $null
    }

    return ($version | Out-String).Trim()
}

function Get-GitValue {
    param([string[]]$Arguments)

    $output = & git -C $repoRootPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return ($output | Out-String).Trim()
}

$bundleId = Normalize-Optional $BundleId
if (-not $bundleId) {
    $bundleId = "pixelstreaming-runtime-{0}" -f (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

if ($bundleId -match '[\\/:*?"<>|]') {
    throw "BundleId '$bundleId' contains invalid path characters."
}

$contractVersion = Normalize-Optional $ContractVersion
if (-not $contractVersion) {
    $contractVersion = "{0}.1" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
}

$outputRoot = Normalize-Optional $OutputRoot
if (-not $outputRoot) {
    $outputRoot = Join-Path $repoRootPath "BuildArtifacts\PixelStreamingRuntime"
}

$outputRoot = [System.IO.Path]::GetFullPath($outputRoot)
$bundleOutputRoot = Join-Path $outputRoot $bundleId
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "scaleworld-pixelstreaming-runtime-$bundleId-$PID"
$runtimeZipPath = Join-Path $bundleOutputRoot "runtime.zip"
$manifestPath = Join-Path $bundleOutputRoot "manifest.json"
$s3Prefix = Normalize-Optional $S3Prefix
if (-not $s3Prefix) {
    $s3Prefix = "PixelStreamingRuntime"
}
$s3Prefix = $s3Prefix.Trim("/")
$runtimeZipKey = "$s3Prefix/$bundleId/runtime.zip"
$manifestKey = "$s3Prefix/$bundleId/manifest.json"

Assert-ChildPath -Parent $outputRoot -Child $bundleOutputRoot

$sourceCommit = Get-GitValue -Arguments @("rev-parse", "HEAD")
$sourceRef = Get-GitValue -Arguments @("branch", "--show-current")
$dirtyStatus = Get-GitValue -Arguments @("status", "--porcelain")
$isDirty = -not [string]::IsNullOrWhiteSpace($dirtyStatus)
if ($isDirty -and -not $AllowDirty) {
    throw "PixelStreaming working tree is dirty. Commit/stash changes or pass -AllowDirty for non-promotable local artifacts."
}

if (-not $SkipBuild) {
    Invoke-External -FilePath "powershell.exe" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $PSScriptRoot "build-all.ps1"),
        "-BuildScope",
        $BuildScope)
}

$npmVersion = Get-NpmVersionOrNull

$requiredDirectories = @(
    "Common\dist",
    "Signalling\dist",
    "SignallingWebServer\dist",
    "SignallingWebServer\www",
    "SignallingWebServer\platform_scripts"
)

foreach ($relativePath in $requiredDirectories) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRootPath $relativePath))) {
        throw "Required runtime path '$relativePath' was not found. Run the build first."
    }
}

Remove-DirectoryBestEffort -Path $stageRoot
New-Item -ItemType Directory -Path $bundleOutputRoot -Force | Out-Null
Grant-CurrentIdentityFullControl -Path $bundleOutputRoot -Container
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

Copy-RequiredFile -RelativePath "NODE_VERSION" -DestinationRoot $stageRoot
Copy-OptionalFile -RelativePath "RELEASE_VERSION" -DestinationRoot $stageRoot
Copy-RequiredFile -RelativePath "package.json" -DestinationRoot $stageRoot
Copy-RequiredFile -RelativePath "package-lock.json" -DestinationRoot $stageRoot

Copy-RequiredFile -RelativePath "Common\package.json" -DestinationRoot $stageRoot
Copy-RequiredDirectory -RelativePath "Common\dist" -DestinationRoot $stageRoot

Copy-RequiredFile -RelativePath "Signalling\package.json" -DestinationRoot $stageRoot
Copy-RequiredDirectory -RelativePath "Signalling\dist" -DestinationRoot $stageRoot

Copy-RequiredFile -RelativePath "SignallingWebServer\package.json" -DestinationRoot $stageRoot
Copy-RequiredFile -RelativePath "SignallingWebServer\config.json" -DestinationRoot $stageRoot
Copy-RequiredFile -RelativePath "SignallingWebServer\peer_options.player.json" -DestinationRoot $stageRoot
Copy-RequiredFile -RelativePath "SignallingWebServer\peer_options.streamer.json" -DestinationRoot $stageRoot
Copy-RequiredDirectory -RelativePath "SignallingWebServer\dist" -DestinationRoot $stageRoot
Copy-RequiredDirectory -RelativePath "SignallingWebServer\www" -DestinationRoot $stageRoot
Copy-RequiredDirectory -RelativePath "SignallingWebServer\platform_scripts" -DestinationRoot $stageRoot -ExtraRobocopyArguments @("/XD", "node", "coturn")
Copy-OptionalFile -RelativePath "SignallingWebServer\README.md" -DestinationRoot $stageRoot

$nodeRuntimeSource = Join-Path $repoRootPath "SignallingWebServer\platform_scripts\cmd\node"
$containsPortableNode = Test-Path -LiteralPath $nodeRuntimeSource
if ($containsPortableNode) {
    Copy-RequiredDirectory -RelativePath "SignallingWebServer\platform_scripts\cmd\node" -DestinationRoot $stageRoot
}

$coturnSource = Join-Path $repoRootPath "SignallingWebServer\platform_scripts\cmd\coturn"
$containsCoturn = Test-Path -LiteralPath $coturnSource
if ($containsCoturn) {
    Copy-RequiredDirectory -RelativePath "SignallingWebServer\platform_scripts\cmd\coturn" -DestinationRoot $stageRoot
}

$containsNodeModules = $false
if (-not $SkipNodeModules) {
    $nodeModulesSource = Join-Path $repoRootPath "node_modules"
    if (-not (Test-Path -LiteralPath $nodeModulesSource)) {
        throw "Root node_modules was not found. Run npm ci or pass -SkipNodeModules for a non-promotable local artifact."
    }

    Invoke-Robocopy `
        -Source $nodeModulesSource `
        -Destination (Join-Path $stageRoot "node_modules") `
        -ExtraArguments @("/XJ", "/XD", ".cache", "@epicgames-ps")

    New-Item -ItemType Directory -Path (Join-Path $stageRoot "node_modules\@epicgames-ps") -Force | Out-Null
    Copy-RuntimeWorkspacePackage `
        -WorkspaceRelativePath "Common" `
        -PackageName "lib-pixelstreamingcommon-ue5.7" `
        -StageRoot $stageRoot
    Copy-RuntimeWorkspacePackage `
        -WorkspaceRelativePath "Signalling" `
        -PackageName "lib-pixelstreamingsignalling-ue5.7" `
        -StageRoot $stageRoot

    $containsNodeModules = $true
}

$promotable = (-not $isDirty) -and $containsNodeModules
$embeddedMetadata = [ordered]@{
    schemaVersion = 1
    artifactType = "pixelstreaming_runtime_bundle"
    bundleId = $bundleId
    pixelStreamingRepoCommit = $sourceCommit
    sourceRef = $sourceRef
    builtAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    builtBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    nodeVersion = (Get-Content -LiteralPath (Join-Path $repoRootPath "NODE_VERSION") -Raw).Trim()
    npmVersion = $npmVersion
    scaleWorldContractVersion = $contractVersion
    capabilities = $Capabilities
    containsNodeModules = $containsNodeModules
    containsPortableNode = $containsPortableNode
    containsCoturn = $containsCoturn
    promotable = $promotable
}

($embeddedMetadata | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $stageRoot "runtime-bundle-metadata.json") -Encoding ASCII

$temporaryRuntimeZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "scaleworld-pixelstreaming-runtime-$bundleId-$([guid]::NewGuid().ToString('N')).zip"
try {
    Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $temporaryRuntimeZipPath -Force
    Copy-FileContent -Source $temporaryRuntimeZipPath -Destination $runtimeZipPath
} finally {
    Remove-Item -LiteralPath $temporaryRuntimeZipPath -Force -ErrorAction SilentlyContinue
}
$runtimeZipSha256 = (Get-FileHash -LiteralPath $runtimeZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$runtimeZipSizeBytes = (Get-Item -LiteralPath $runtimeZipPath).Length

$manifest = [ordered]@{
    schemaVersion = 1
    artifactType = "pixelstreaming_runtime"
    bundleId = $bundleId
    runtimeZipKey = $runtimeZipKey
    runtimeZipSha256 = $runtimeZipSha256
    runtimeZipSizeBytes = $runtimeZipSizeBytes
    pixelStreamingRepoCommit = $sourceCommit
    sourceRef = $sourceRef
    sourceDirty = $isDirty
    builtAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    builtBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    nodeVersion = (Get-Content -LiteralPath (Join-Path $repoRootPath "NODE_VERSION") -Raw).Trim()
    npmVersion = $npmVersion
    buildScope = $BuildScope
    scaleWorldContractVersion = $contractVersion
    capabilities = $Capabilities
    containsNodeModules = $containsNodeModules
    containsPortableNode = $containsPortableNode
    containsCoturn = $containsCoturn
    compatibility = [ordered]@{
        api = [ordered]@{
            advisoryMinContractVersion = $contractVersion
        }
        unreal = [ordered]@{
            advisoryKnownGoodBuildKeys = @()
        }
    }
    promotable = $promotable
}

($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $manifestPath -Encoding ASCII
Remove-DirectoryBestEffort -Path $stageRoot

if ($Publish) {
    if (-not $promotable) {
        throw "Refusing to publish a non-promotable runtime artifact. Build from a clean tree with node_modules included."
    }

    Invoke-AwsS3Copy -Source $runtimeZipPath -Destination "s3://$S3Bucket/$runtimeZipKey" -AwsRegion $Region
    Invoke-AwsS3Copy -Source $manifestPath -Destination "s3://$S3Bucket/$manifestKey" -AwsRegion $Region
}

[pscustomobject]@{
    BundleId = $bundleId
    ManifestPath = $manifestPath
    RuntimeZipPath = $runtimeZipPath
    ManifestS3Key = $manifestKey
    RuntimeZipS3Key = $runtimeZipKey
    RuntimeZipSha256 = $runtimeZipSha256
    RuntimeZipSizeBytes = $runtimeZipSizeBytes
    SourceCommit = $sourceCommit
    SourceRef = $sourceRef
    SourceDirty = $isDirty
    Promotable = $promotable
    Published = [bool]$Publish
} | ConvertTo-Json -Depth 4
