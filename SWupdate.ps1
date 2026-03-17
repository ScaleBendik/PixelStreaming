[CmdletBinding()]
param(
    [int]$DataDiskNumber = 1,
    [string]$BucketName = $(if ($env:SCALEWORLD_UPDATE_BUCKET) { $env:SCALEWORLD_UPDATE_BUCKET } else { 'scaleworlddepot' }),
    [string]$ZipKey = '',
    [string]$InstallBasePath = $(if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }),
    [string]$ActiveInstallName = $(if ($env:SCALEWORLD_ACTIVE_INSTALL_NAME) { $env:SCALEWORLD_ACTIVE_INSTALL_NAME } else { 'WindowsNoEditor' }),
    [string]$ExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
    [switch]$RollbackToPrevious,
    [switch]$ForceStopProcesses,
    [switch]$SkipRuntimeStatus,
    [switch]$AllowUnchanged,
    [bool]$FreeSpaceByRemovingCurrentRelease = $(if ($env:SCALEWORLD_DELETE_CURRENT_RELEASE_BEFORE_ACTIVATE) { [System.Boolean]::Parse($env:SCALEWORLD_DELETE_CURRENT_RELEASE_BEFORE_ACTIVATE) } else { $true }),
    [switch]$PrepareOnly,
    [switch]$PrepareReleaseOnly,
    [switch]$ActivatePreparedRelease
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

function Set-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [hashtable]$Tags
    )

    if (-not $Tags -or $Tags.Count -eq 0) {
        return
    }

    $tagPayload = foreach ($key in $Tags.Keys) {
        @{
            Key = [string]$key
            Value = Normalize-TagValue ([string]$Tags[$key])
        }
    }

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            ($tagPayload | ConvertTo-Json -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $args = @(
            'ec2', 'create-tags',
            '--region', $Region,
            '--resources', $InstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )
        $result = Invoke-AwsCliCapture -AwsCli $AwsCli -Arguments $args
        if ($result.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                throw "Failed to set EC2 tags for $InstanceId. AWS CLI exited with code $($result.ExitCode)."
            }

            throw "Failed to set EC2 tags for $InstanceId. $($result.Combined)"
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
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
        Set-InstanceTags -AwsCli $script:AwsCliPath -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
            ScaleWorldRuntimeStatus = $Status
            ScaleWorldRuntimeStatusAtUtc = $timestamp
            ScaleWorldRuntimeStatusHeartbeatAtUtc = $timestamp
            ScaleWorldRuntimeStatusSource = 'unreal-updater'
            ScaleWorldRuntimeStatusReason = $Reason
            ScaleWorldRuntimeStatusVersion = ''
        }
    } catch {
        Write-UpdateLog "Failed to publish runtime status '$Status': $($_.Exception.Message)" 'WARN'
    }
}

function Get-ZipMetadata {
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
        Source = 'zip-key'
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

function Get-PendingReleaseState {
    return Read-StateMetadata -Path $script:PendingReleaseStatePath
}

function Set-PendingReleaseState {
    param([object]$Pending)

    Write-StateMetadata -Path $script:PendingReleaseStatePath -Value $Pending
}

function Set-ReleaseState {
    param(
        [object]$Current,
        [object]$Previous
    )

    Write-StateMetadata -Path $script:CurrentReleaseStatePath -Value $Current
    Write-StateMetadata -Path $script:PreviousReleaseStatePath -Value $Previous
}

function Remove-CurrentReleaseForUpdate {
    param(
        [object]$CurrentReleaseState
    )

    if (-not $CurrentReleaseState) {
        return
    }

    $rollbackBackup = New-RollbackBackupState -CurrentReleaseState $CurrentReleaseState

    if (Test-Path -LiteralPath $script:ActiveInstallPath) {
        if (Test-IsReparsePoint -Path $script:ActiveInstallPath) {
            cmd /c rmdir "$script:ActiveInstallPath" | Out-Null
        } else {
            Remove-Item -LiteralPath $script:ActiveInstallPath -Recurse -Force
        }
    }

    if ($CurrentReleaseState.ReleasePath -and (Test-Path -LiteralPath $CurrentReleaseState.ReleasePath)) {
        Remove-Item -LiteralPath $CurrentReleaseState.ReleasePath -Recurse -Force
    }

    Set-ReleaseState -Current $null -Previous $null
    Write-UpdateLog "Removed current active release '$($CurrentReleaseState.BuildId)' to free space before activation." 'WARN'
    return $rollbackBackup
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

    $legacyBuildId = 'legacy-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $legacyReleasePath = Join-Path $script:ReleasesRoot $legacyBuildId
    Move-Item -LiteralPath $script:ActiveInstallPath -Destination $legacyReleasePath -Force
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

function Get-RollbackBackupRoot {
    return Join-Path $script:DownloadRoot 'rollback'
}

function New-RollbackBackupState {
    param(
        [object]$CurrentReleaseState
    )

    if (-not $CurrentReleaseState -or -not $CurrentReleaseState.ReleasePath -or -not (Test-Path -LiteralPath $CurrentReleaseState.ReleasePath)) {
        return $null
    }

    $backupRoot = Get-RollbackBackupRoot
    New-DirectoryIfMissing -Path $backupRoot

    $backupName = "{0}-{1}" -f (Get-SafeReleaseName -BuildId $CurrentReleaseState.BuildId), (Get-Date -Format 'yyyyMMddHHmmss')
    $backupPath = Join-Path $backupRoot $backupName
    Copy-Item -LiteralPath $CurrentReleaseState.ReleasePath -Destination $backupPath -Recurse -Force

    $backupState = [pscustomobject]@{
        BuildId = $CurrentReleaseState.BuildId
        ZipKey = $CurrentReleaseState.ZipKey
        Source = 'rollback-backup'
        ReleasePath = $backupPath
        ActivatedAtUtc = $CurrentReleaseState.ActivatedAtUtc
        BackedUpAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        CreatedAtUtc = if ($CurrentReleaseState.PSObject.Properties.Name -contains 'CreatedAtUtc') { $CurrentReleaseState.CreatedAtUtc } else { '' }
        DownloadedAtUtc = if ($CurrentReleaseState.PSObject.Properties.Name -contains 'DownloadedAtUtc') { $CurrentReleaseState.DownloadedAtUtc } else { '' }
        Sha256 = if ($CurrentReleaseState.PSObject.Properties.Name -contains 'Sha256') { $CurrentReleaseState.Sha256 } else { '' }
    }
    Write-ReleaseMetadata -ReleasePath $backupPath -Metadata $backupState
    Write-UpdateLog "Copied active release '$($CurrentReleaseState.BuildId)' to rollback backup '$backupPath'."
    return $backupState
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
        [string]$DestinationPath,
        [object]$Metadata
    )

    $leafName = Split-Path -Leaf $DestinationPath
    $stagingRoot = Join-Path $script:ScratchRoot ('_staging-' + $leafName)

    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    Expand-Archive -Path $ArchivePath -DestinationPath $stagingRoot -Force

    $matchedExecutables = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File -Filter $ExecutableName -ErrorAction Stop)
    if ($matchedExecutables.Count -eq 1) {
        $contentSource = Split-Path -Parent $matchedExecutables[0].FullName
    } elseif ($matchedExecutables.Count -gt 1) {
        throw "Archive '$ArchivePath' contains multiple '$ExecutableName' candidates. Refusing to continue."
    } else {
        $topLevel = @(Get-ChildItem -LiteralPath $stagingRoot -Force)
        if ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer) {
            $contentSource = $topLevel[0].FullName
        } else {
            $contentSource = $stagingRoot
        }
    }

    if ($contentSource -ne $stagingRoot) {
        Move-Item -LiteralPath $contentSource -Destination $DestinationPath -Force
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        Get-ChildItem -LiteralPath $stagingRoot -Force | Move-Item -Destination $DestinationPath -Force
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }

    Assert-ExecutableExists -ReleasePath $DestinationPath -Executable $ExecutableName
    Write-ReleaseMetadata -ReleasePath $DestinationPath -Metadata $Metadata

    return $DestinationPath
}

function Prepare-ReleaseArchive {
    param(
        [object]$BuildMetadata,
        [bool]$AllowSameBuild
    )

    Set-PendingReleaseState -Pending $null

    $releaseName = Get-SafeReleaseName -BuildId $BuildMetadata.BuildId
    $current = Get-CurrentReleaseState

    if (-not $AllowSameBuild `
        -and $current `
        -and $current.BuildId -eq $BuildMetadata.BuildId `
        -and $current.ZipKey -eq $BuildMetadata.ZipKey `
        -and (Test-Path -LiteralPath $current.ReleasePath)) {
        Set-PendingReleaseState -Pending $null
        Write-UpdateLog "Build '$($BuildMetadata.BuildId)' is already active. No update required."
        return $null
    }

    $archivePath = Get-DownloadDestination -FileName ("{0}.zip" -f $releaseName)
    Invoke-Download -Bucket $BucketName -ObjectKey $BuildMetadata.ZipKey -DestinationPath $archivePath
    Assert-Checksum -Path $archivePath -ExpectedSha256 $BuildMetadata.Sha256

    $preparedRoot = Join-Path $script:ScratchRoot ('prepared-' + $releaseName)
    $preparedState = [pscustomobject]@{
        BuildId = $BuildMetadata.BuildId
        ZipKey = $BuildMetadata.ZipKey
        Source = $BuildMetadata.Source
        ReleaseName = $releaseName
        PreparedPath = ''
        ActivatedAtUtc = ''
        CreatedAtUtc = $BuildMetadata.CreatedAtUtc
        DownloadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Sha256 = $BuildMetadata.Sha256
    }

    $preparedPath = Expand-ReleaseArchive -ArchivePath $archivePath -DestinationPath $preparedRoot -Metadata $preparedState
    $preparedState.PreparedPath = $preparedPath
    Write-ReleaseMetadata -ReleasePath $preparedPath -Metadata $preparedState
    Set-PendingReleaseState -Pending $preparedState
    Write-UpdateLog "Prepared build '$($preparedState.BuildId)' at '$preparedPath'."
    return $preparedState
}

function Activate-PreparedRelease {
    param(
        [string]$ExpectedZipKey,
        [bool]$RemoveCurrentReleaseFirst
    )

    $prepared = Get-PendingReleaseState
    if (-not $prepared) {
        throw 'No prepared release metadata was found.'
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedZipKey) -and $prepared.ZipKey -ne $ExpectedZipKey) {
        throw "Prepared release zip '$($prepared.ZipKey)' did not match requested zip '$ExpectedZipKey'."
    }

    if (-not $prepared.PreparedPath -or -not (Test-Path -LiteralPath $prepared.PreparedPath)) {
        throw "Prepared release path '$($prepared.PreparedPath)' was not found."
    }

    $current = Get-CurrentReleaseState
    $rollbackBackup = $null
    if ($RemoveCurrentReleaseFirst -and $current -and (Test-Path -LiteralPath $current.ReleasePath)) {
        $rollbackBackup = Remove-CurrentReleaseForUpdate -CurrentReleaseState $current
        $current = $null
    }

    $releaseState = [pscustomobject]@{
        BuildId = $prepared.BuildId
        ZipKey = $prepared.ZipKey
        Source = $prepared.Source
        ReleasePath = ''
        ActivatedAtUtc = ''
        CreatedAtUtc = if ($prepared.PSObject.Properties.Name -contains 'CreatedAtUtc') { $prepared.CreatedAtUtc } else { '' }
        DownloadedAtUtc = if ($prepared.PSObject.Properties.Name -contains 'DownloadedAtUtc') { $prepared.DownloadedAtUtc } else { '' }
        Sha256 = if ($prepared.PSObject.Properties.Name -contains 'Sha256') { $prepared.Sha256 } else { '' }
    }

    $releasePath = Join-Path $script:ReleasesRoot $prepared.ReleaseName
    if (Test-Path -LiteralPath $releasePath) {
        Remove-Item -LiteralPath $releasePath -Recurse -Force
    }

    Move-Item -LiteralPath $prepared.PreparedPath -Destination $releasePath -Force
    $releaseState.ReleasePath = $releasePath
    $releaseState.ActivatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-ReleaseMetadata -ReleasePath $releasePath -Metadata $releaseState
    Switch-ActiveRelease -ReleaseState $releaseState
    if ($rollbackBackup) {
        Set-ReleaseState -Current $releaseState -Previous $rollbackBackup
    }

    Set-PendingReleaseState -Pending $null
    Write-UpdateLog "Activated prepared build '$($releaseState.BuildId)' from s3://$BucketName/$($releaseState.ZipKey)."
    return $releaseState
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
$script:CurrentReleaseStatePath = Join-Path $script:StateRoot 'current-release.json'
$script:PreviousReleaseStatePath = Join-Path $script:StateRoot 'previous-release.json'
$script:PendingReleaseStatePath = Join-Path $script:StateRoot 'pending-release.json'

New-DirectoryIfMissing -Path $InstallBasePath
New-DirectoryIfMissing -Path $script:ReleasesRoot
New-DirectoryIfMissing -Path $script:StateRoot

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
    $normalizedZipKey = $ZipKey.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedZipKey)) {
        throw 'ZipKey is required. Provide the exact S3 object key for the update ZIP.'
    }

    $buildMetadata = Get-ZipMetadata -Bucket $BucketName -ObjectKey $normalizedZipKey
    if ($PrepareReleaseOnly.IsPresent) {
        $prepared = Prepare-ReleaseArchive -BuildMetadata $buildMetadata -AllowSameBuild $AllowUnchanged.IsPresent
        if (-not $prepared) {
            exit 0
        }

        exit 0
    }

    if ($ActivatePreparedRelease.IsPresent) {
        $activated = Activate-PreparedRelease -ExpectedZipKey $normalizedZipKey -RemoveCurrentReleaseFirst $FreeSpaceByRemovingCurrentRelease
        if (-not $activated) {
            throw 'Prepared release activation did not return a release state.'
        }

        exit 0
    }

    $prepared = Prepare-ReleaseArchive -BuildMetadata $buildMetadata -AllowSameBuild $AllowUnchanged.IsPresent
    if (-not $prepared) {
        exit 0
    }

    $activated = Activate-PreparedRelease -ExpectedZipKey $normalizedZipKey -RemoveCurrentReleaseFirst $FreeSpaceByRemovingCurrentRelease
    if (-not $activated) {
        throw 'Prepared release activation did not return a release state.'
    }
} catch {
    $reason = if ($RollbackToPrevious.IsPresent) { 'ue_build_rollback_failed' } else { 'ue_build_update_failed' }
    Publish-RuntimeStatus -Status 'runtime_fault' -Reason $reason
    Write-Error "SWupdate failed: $($_.Exception.Message)"
    exit 1
}





