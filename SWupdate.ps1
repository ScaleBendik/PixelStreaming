[CmdletBinding()]
param(
    [int]$DataDiskNumber = 1,
    [string]$BucketName = $(if ($env:SCALEWORLD_UPDATE_BUCKET) { $env:SCALEWORLD_UPDATE_BUCKET } else { 'scaleworlddepot' }),
    [string]$ManifestKey = $(if ($env:SCALEWORLD_UPDATE_MANIFEST_KEY) { $env:SCALEWORLD_UPDATE_MANIFEST_KEY } else { 'Scaleworld_001/latest.json' }),
    [string]$BuildKey = $(if ($env:SCALEWORLD_UPDATE_BUILD_KEY) { $env:SCALEWORLD_UPDATE_BUILD_KEY } else { 'Scaleworld_001/ScaleWorld_Latest.zip' }),
    [string]$ZipKey = '',
    [string]$InstallBasePath = $(if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }),
    [string]$ActiveInstallName = $(if ($env:SCALEWORLD_ACTIVE_INSTALL_NAME) { $env:SCALEWORLD_ACTIVE_INSTALL_NAME } else { 'WindowsNoEditor' }),
    [string]$ExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
    [string[]]$PreserveTopLevelFiles = @('runScaleWorld.bat', 'Start_ScaleWorldWithparams.ps1'),
    [switch]$RollbackToPrevious,
    [switch]$ForceStopProcesses,
    [switch]$SkipRuntimeStatus,
    [switch]$AllowUnchanged,
    [switch]$PrepareOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-UpdateLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [swupdate] $Message"
}

function New-DirectoryIfMissing {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
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

    throw "AWS CLI ('aws') was not found in PATH or standard install directories."
}

function Get-OrCreate-DataVolume {
    param([int]$DiskNumber)

    if ($DiskNumber -le 0) {
        return $null
    }

    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    } catch {
        Write-UpdateLog "Disk $DiskNumber was not found. Falling back to local storage." 'WARN'
        return $null
    }

    if ($disk.IsOffline) {
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
        $disk = Get-Disk -Number $DiskNumber
    }

    if ($disk.IsReadOnly) {
        Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction Stop
        $disk = Get-Disk -Number $DiskNumber
    }

    if ($disk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop
        $disk = Get-Disk -Number $DiskNumber
    }

    $partition = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -ne 'Reserved' } |
        Select-Object -First 1

    if (-not $partition) {
        $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    }

    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
    if (-not $volume -or -not $volume.FileSystem) {
        $volume = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel ("ScaleWorldData{0}" -f $DiskNumber) -Confirm:$false -ErrorAction Stop
    }

    if (-not $volume.DriveLetter) {
        throw "Data volume on disk $DiskNumber has no drive letter."
    }

    return $volume
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

function Get-InstanceIdentity {
    try {
        $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
        return [pscustomobject]@{
            InstanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
            Region = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
        }
    } catch {
        return $null
    }
}

function Publish-RuntimeStatus {
    param(
        [string]$Status,
        [string]$Reason
    )

    if ($SkipRuntimeStatus.IsPresent) {
        return
    }

    if ($env:RUNTIME_STATUS_ENABLED -and $env:RUNTIME_STATUS_ENABLED.Trim().ToLowerInvariant() -in @('0', 'false', 'no', 'off')) {
        return
    }

    $identity = Get-InstanceIdentity
    if (-not $identity) {
        return
    }

    try {
        $timestamp = (Get-Date).ToUniversalTime().ToString('o')
        $args = @(
            'ec2', 'create-tags',
            '--region', $identity.Region,
            '--resources', $identity.InstanceId,
            '--tags',
            ("Key=ScaleWorldRuntimeStatus,Value={0}" -f (Normalize-TagValue $Status)),
            ("Key=ScaleWorldRuntimeStatusAtUtc,Value={0}" -f $timestamp),
            ("Key=ScaleWorldRuntimeStatusHeartbeatAtUtc,Value={0}" -f $timestamp),
            ("Key=ScaleWorldRuntimeStatusSource,Value={0}" -f 'unreal-updater'),
            ("Key=ScaleWorldRuntimeStatusReason,Value={0}" -f (Normalize-TagValue $Reason)),
            ("Key=ScaleWorldRuntimeStatusVersion,Value={0}" -f '')
        )
        & $script:AwsCliPath @args *> $null
    } catch {
        Write-UpdateLog "Failed to publish runtime status '$Status': $($_.Exception.Message)" 'WARN'
    }
}

function Convert-ManifestToBuildMetadata {
    param(
        [object]$Manifest,
        [string]$FallbackBuildKey
    )

    $buildId = @($Manifest.buildId, $Manifest.buildID, $Manifest.version, $Manifest.id) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $zipKey = @($Manifest.zipKey, $Manifest.key, $Manifest.objectKey) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $checksum = @($Manifest.sha256, $Manifest.sha256Hex, $Manifest.checksum) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $createdAt = @($Manifest.createdAtUtc, $Manifest.createdAt, $Manifest.created) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($zipKey)) {
        $zipKey = $FallbackBuildKey
    }

    if ([string]::IsNullOrWhiteSpace($buildId) -or [string]::IsNullOrWhiteSpace($zipKey)) {
        return $null
    }

    return [pscustomobject]@{
        BuildId = [string]$buildId
        ZipKey = [string]$zipKey
        Sha256 = [string]$checksum
        CreatedAtUtc = [string]$createdAt
        Source = 'manifest'
    }
}

function Get-ExplicitZipMetadata {
    param(
        [string]$Bucket,
        [string]$ObjectKey
    )

    $headJson = & $script:AwsCliPath s3api head-object --bucket $Bucket --key $ObjectKey --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read metadata for s3://$Bucket/$ObjectKey."
    }

    $head = ($headJson | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $etag = ([string]$head.ETag).Trim('"')
    $buildId = if (-not [string]::IsNullOrWhiteSpace($etag)) { $etag } else { [IO.Path]::GetFileNameWithoutExtension($ObjectKey) }
    return [pscustomobject]@{
        BuildId = $buildId
        ZipKey = $ObjectKey
        Sha256 = ''
        CreatedAtUtc = [string]$head.LastModified
        Source = 'explicit-zip-key'
    }
}
function Get-BuildMetadata {
    param(
        [string]$Bucket,
        [string]$ManifestObjectKey,
        [string]$FallbackObjectKey
    )

    if (-not [string]::IsNullOrWhiteSpace($ManifestObjectKey)) {
        try {
            $manifestJson = & $script:AwsCliPath s3 cp ("s3://{0}/{1}" -f $Bucket, $ManifestObjectKey) - --no-progress
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($manifestJson | Out-String))) {
                $manifest = ($manifestJson | Out-String) | ConvertFrom-Json -ErrorAction Stop
                $converted = Convert-ManifestToBuildMetadata -Manifest $manifest -FallbackBuildKey $FallbackObjectKey
                if ($converted) {
                    return $converted
                }
            }
        } catch {
            Write-UpdateLog "Manifest lookup failed for s3://$Bucket/$ManifestObjectKey. Falling back to legacy build key." 'WARN'
        }
    }

    $headJson = & $script:AwsCliPath s3api head-object --bucket $Bucket --key $FallbackObjectKey --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read metadata for s3://$Bucket/$FallbackObjectKey."
    }

    $head = ($headJson | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $etag = ([string]$head.ETag).Trim('"')
    if ([string]::IsNullOrWhiteSpace($etag)) {
        throw "S3 object metadata for s3://$Bucket/$FallbackObjectKey did not include an ETag."
    }

    return [pscustomobject]@{
        BuildId = $etag
        ZipKey = $FallbackObjectKey
        Sha256 = ''
        CreatedAtUtc = [string]$head.LastModified
        Source = 'legacy-build-key'
    }
}

function Get-SafeReleaseName {
    param([string]$BuildId)

    $safe = ($BuildId -replace '[^A-Za-z0-9._-]', '-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'release-' + (Get-Date -Format 'yyyyMMddHHmmss')
    }

    return $safe
}

function Get-ReleaseMetadataFilePath {
    param([string]$ReleasePath)

    return Join-Path $ReleasePath 'scaleworld-release.json'
}

function Write-ReleaseMetadata {
    param(
        [string]$ReleasePath,
        [object]$Metadata
    )

    $json = $Metadata | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Get-ReleaseMetadataFilePath -ReleasePath $ReleasePath) -Value $json -Encoding UTF8
}

function Read-StateMetadata {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}

function Write-StateMetadata {
    param(
        [string]$Path,
        [object]$Value
    )

    if (-not $Value) {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        return
    }

    Set-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Depth 6) -Encoding UTF8
}

function Get-JunctionTarget {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $output = cmd /c dir /AL "$parent" 2>$null
    foreach ($line in $output) {
        if ($line -match ([regex]::Escape($leaf) + '\s+\[(.+)\]')) {
            return $matches[1]
        }
    }

    return $null
}

function Test-IsReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    return ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Copy-PreservedTopLevelFiles {
    param(
        [string]$SourcePath,
        [string]$SupportPath,
        [string[]]$FileNames
    )

    New-DirectoryIfMissing -Path $SupportPath
    foreach ($name in $FileNames) {
        $sourceFile = Join-Path $SourcePath $name
        if (Test-Path -LiteralPath $sourceFile) {
            Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $SupportPath $name) -Force
        }
    }
}

function Apply-PreservedTopLevelFiles {
    param(
        [string]$SupportPath,
        [string]$DestinationPath,
        [string[]]$FileNames
    )

    foreach ($name in $FileNames) {
        $supportFile = Join-Path $SupportPath $name
        if (-not (Test-Path -LiteralPath $supportFile)) {
            continue
        }

        $destinationFile = Join-Path $DestinationPath $name
        if (-not (Test-Path -LiteralPath $destinationFile)) {
            Copy-Item -LiteralPath $supportFile -Destination $destinationFile -Force
        }
    }
}

function Assert-ExecutableExists {
    param(
        [string]$ReleasePath,
        [string]$Executable
    )

    $candidate = Join-Path $ReleasePath $Executable
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "Expected executable '$Executable' was not found under '$ReleasePath'."
    }
}

function Get-CurrentReleaseState {
    return Read-StateMetadata -Path $script:CurrentReleaseStatePath
}

function Get-PreviousReleaseState {
    return Read-StateMetadata -Path $script:PreviousReleaseStatePath
}

function Set-ReleaseState {
    param(
        [object]$Current,
        [object]$Previous
    )

    Write-StateMetadata -Path $script:CurrentReleaseStatePath -Value $Current
    Write-StateMetadata -Path $script:PreviousReleaseStatePath -Value $Previous
}

function Switch-ActiveRelease {
    param(
        [object]$ReleaseState
    )

    Assert-ExecutableExists -ReleasePath $ReleaseState.ReleasePath -Executable $ExecutableName
    $current = Get-CurrentReleaseState
    $previous = if ($current -and $current.ReleasePath -ne $ReleaseState.ReleasePath) { $current } else { Get-PreviousReleaseState }

    if (Test-Path -LiteralPath $script:ActiveInstallPath) {
        if (Test-IsReparsePoint -Path $script:ActiveInstallPath) {
            cmd /c rmdir "$script:ActiveInstallPath" | Out-Null
        } else {
            throw "Active install path '$script:ActiveInstallPath' is a real directory. Run migration/bootstrap first."
        }
    }

    $mklinkOutput = cmd /c mklink /J "$script:ActiveInstallPath" "$($ReleaseState.ReleasePath)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create active junction '$script:ActiveInstallPath' -> '$($ReleaseState.ReleasePath)': $($mklinkOutput | Out-String)"
    }

    Set-ReleaseState -Current $ReleaseState -Previous $previous
}

function Ensure-InstallTopology {
    $current = Get-CurrentReleaseState
    if ($current -and (Test-Path -LiteralPath $current.ReleasePath) -and (Test-IsReparsePoint -Path $script:ActiveInstallPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $script:ActiveInstallPath)) {
        return
    }

    if (Test-IsReparsePoint -Path $script:ActiveInstallPath) {
        $target = Get-JunctionTarget -Path $script:ActiveInstallPath
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw "Existing active junction '$script:ActiveInstallPath' has no tracked state and its target could not be resolved."
        }

        $bootstrappedState = [pscustomobject]@{
            BuildId = 'unknown-current'
            ZipKey = ''
            Source = 'bootstrapped-junction'
            ReleasePath = $target
            ActivatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Set-ReleaseState -Current $bootstrappedState -Previous $null
        return
    }

    Copy-PreservedTopLevelFiles -SourcePath $script:ActiveInstallPath -SupportPath $script:SupportPath -FileNames $PreserveTopLevelFiles

    $legacyBuildId = 'legacy-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $legacyReleasePath = Join-Path $script:ReleasesRoot $legacyBuildId
    Move-Item -LiteralPath $script:ActiveInstallPath -Destination $legacyReleasePath -Force
    Apply-PreservedTopLevelFiles -SupportPath $script:SupportPath -DestinationPath $legacyReleasePath -FileNames $PreserveTopLevelFiles
    Assert-ExecutableExists -ReleasePath $legacyReleasePath -Executable $ExecutableName

    $legacyState = [pscustomobject]@{
        BuildId = $legacyBuildId
        ZipKey = ''
        Source = 'legacy-active-install'
        ReleasePath = $legacyReleasePath
        ActivatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-ReleaseMetadata -ReleasePath $legacyReleasePath -Metadata $legacyState
    Switch-ActiveRelease -ReleaseState $legacyState
    Write-UpdateLog "Migrated existing active install to staged release '$legacyBuildId'."
}

function Stop-ScaleWorldProcessesIfNeeded {
    $processNames = @([IO.Path]::GetFileNameWithoutExtension($ExecutableName), 'ScaleWorld-Win64-Shipping') | Select-Object -Unique
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $processNames -contains $_.ProcessName })
    if ($running.Count -eq 0) {
        return
    }

    if (-not $ForceStopProcesses.IsPresent) {
        throw "ScaleWorld is still running. Stop the runtime first or rerun with -ForceStopProcesses."
    }

    foreach ($process in $running) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        Write-UpdateLog "Stopped running process '$($process.ProcessName)' (PID=$($process.Id))."
    }
}

function Get-DownloadDestination {
    param([string]$FileName)

    return Join-Path $script:DownloadRoot $FileName
}

function Invoke-Download {
    param(
        [string]$Bucket,
        [string]$ObjectKey,
        [string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    & $script:AwsCliPath s3 cp ("s3://{0}/{1}" -f $Bucket, $ObjectKey) $DestinationPath --no-progress
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $DestinationPath)) {
        throw "Failed to download s3://$Bucket/$ObjectKey to '$DestinationPath'."
    }
}

function Assert-Checksum {
    param(
        [string]$Path,
        [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-UpdateLog 'No SHA256 checksum provided; skipping checksum validation.' 'WARN'
        return
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($hash -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
        throw "Checksum mismatch for '$Path'. Expected $ExpectedSha256 but got $hash."
    }
}

function Expand-ReleaseArchive {
    param(
        [string]$ArchivePath,
        [string]$ReleaseName,
        [object]$Metadata
    )

    $stagingRoot = Join-Path $script:ScratchRoot ('_staging-' + $ReleaseName)
    $finalReleasePath = Join-Path $script:ReleasesRoot $ReleaseName

    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $finalReleasePath) {
        Remove-Item -LiteralPath $finalReleasePath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    Expand-Archive -Path $ArchivePath -DestinationPath $stagingRoot -Force

    $topLevel = @(Get-ChildItem -LiteralPath $stagingRoot -Force)
    if ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer) {
        $contentSource = $topLevel[0].FullName
    } else {
        $contentSource = $stagingRoot
    }

    if ($contentSource -ne $stagingRoot) {
        Move-Item -LiteralPath $contentSource -Destination $finalReleasePath -Force
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $finalReleasePath -Force | Out-Null
        Get-ChildItem -LiteralPath $stagingRoot -Force | Move-Item -Destination $finalReleasePath -Force
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }

    Apply-PreservedTopLevelFiles -SupportPath $script:SupportPath -DestinationPath $finalReleasePath -FileNames $PreserveTopLevelFiles
    Assert-ExecutableExists -ReleasePath $finalReleasePath -Executable $ExecutableName
    Write-ReleaseMetadata -ReleasePath $finalReleasePath -Metadata $Metadata

    return $finalReleasePath
}

function Invoke-Rollback {
    $current = Get-CurrentReleaseState
    $previous = Get-PreviousReleaseState
    if (-not $previous) {
        throw 'No previous release metadata was found; rollback is not possible.'
    }

    Publish-RuntimeStatus -Status 'updating_infra' -Reason 'ue_build_rollback'
    Switch-ActiveRelease -ReleaseState $previous
    Set-ReleaseState -Current $previous -Previous $current
    Write-UpdateLog "Rolled back active install to '$($previous.BuildId)'."
}

$script:AwsCliPath = Get-AwsCliPath
$activeInstallPath = Join-Path $InstallBasePath $ActiveInstallName
$script:ActiveInstallPath = $activeInstallPath
$script:ReleasesRoot = Join-Path $InstallBasePath 'releases'
$script:StateRoot = Join-Path $InstallBasePath 'state'
$script:SupportPath = Join-Path $InstallBasePath 'support'
$script:CurrentReleaseStatePath = Join-Path $script:StateRoot 'current-release.json'
$script:PreviousReleaseStatePath = Join-Path $script:StateRoot 'previous-release.json'

New-DirectoryIfMissing -Path $InstallBasePath
New-DirectoryIfMissing -Path $script:ReleasesRoot
New-DirectoryIfMissing -Path $script:StateRoot
New-DirectoryIfMissing -Path $script:SupportPath

$dataVolume = Get-OrCreate-DataVolume -DiskNumber $DataDiskNumber
$script:DownloadRoot = if ($dataVolume) {
    $downloadRoot = "{0}:\ScaleWorldBuilds" -f $dataVolume.DriveLetter
    New-DirectoryIfMissing -Path $downloadRoot
    $downloadRoot
} else {
    $fallbackRoot = Join-Path $InstallBasePath 'downloads'
    New-DirectoryIfMissing -Path $fallbackRoot
    $fallbackRoot
}
$script:ScratchRoot = if ($dataVolume) {
    $scratchRoot = Join-Path $script:DownloadRoot 'staging'
    New-DirectoryIfMissing -Path $scratchRoot
    $scratchRoot
} else {
    $fallbackScratchRoot = Join-Path $InstallBasePath 'scratch'
    New-DirectoryIfMissing -Path $fallbackScratchRoot
    $fallbackScratchRoot
}

Write-UpdateLog "Using AWS CLI: $script:AwsCliPath"
Write-UpdateLog "Using download root: $script:DownloadRoot"
Write-UpdateLog "Using scratch root: $script:ScratchRoot"

if ($PrepareOnly.IsPresent) {
    Write-UpdateLog 'Prepared update storage paths only.'
    exit 0
}

try {
    Ensure-InstallTopology
    Stop-ScaleWorldProcessesIfNeeded

    if ($RollbackToPrevious.IsPresent) {
        Invoke-Rollback
        exit 0
    }

    Publish-RuntimeStatus -Status 'updating_infra' -Reason 'ue_build_update'
    $buildMetadata = if (-not [string]::IsNullOrWhiteSpace($ZipKey)) {
        Get-ExplicitZipMetadata -Bucket $BucketName -ObjectKey $ZipKey
    } else {
        Get-BuildMetadata -Bucket $BucketName -ManifestObjectKey $ManifestKey -FallbackObjectKey $BuildKey
    }
    $releaseName = Get-SafeReleaseName -BuildId $buildMetadata.BuildId
    $current = Get-CurrentReleaseState

    if (-not $AllowUnchanged.IsPresent -and $current -and $current.BuildId -eq $buildMetadata.BuildId -and (Test-Path -LiteralPath $current.ReleasePath)) {
        Write-UpdateLog "Build '$($buildMetadata.BuildId)' is already active. No update required."
        exit 0
    }

    $archivePath = Get-DownloadDestination -FileName ("{0}.zip" -f $releaseName)
    Invoke-Download -Bucket $BucketName -ObjectKey $buildMetadata.ZipKey -DestinationPath $archivePath
    Assert-Checksum -Path $archivePath -ExpectedSha256 $buildMetadata.Sha256

    $releaseState = [pscustomobject]@{
        BuildId = $buildMetadata.BuildId
        ZipKey = $buildMetadata.ZipKey
        Source = $buildMetadata.Source
        ReleasePath = ''
        ActivatedAtUtc = ''
        CreatedAtUtc = $buildMetadata.CreatedAtUtc
        DownloadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Sha256 = $buildMetadata.Sha256
    }

    $releasePath = Expand-ReleaseArchive -ArchivePath $archivePath -ReleaseName $releaseName -Metadata $releaseState
    $releaseState.ReleasePath = $releasePath
    $releaseState.ActivatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-ReleaseMetadata -ReleasePath $releasePath -Metadata $releaseState
    Switch-ActiveRelease -ReleaseState $releaseState

    Write-UpdateLog "Activated build '$($releaseState.BuildId)' from s3://$BucketName/$($releaseState.ZipKey)."
} catch {
    $reason = if ($RollbackToPrevious.IsPresent) { 'ue_build_rollback_failed' } else { 'ue_build_update_failed' }
    Publish-RuntimeStatus -Status 'runtime_fault' -Reason $reason
    Write-Error "SWupdate failed: $($_.Exception.Message)"
    exit 1
}

