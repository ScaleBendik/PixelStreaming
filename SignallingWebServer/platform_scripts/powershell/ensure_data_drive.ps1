[CmdletBinding()]
param(
    [int]$DataDiskNumber = $(if ($env:SCALEWORLD_DATA_DISK_NUMBER) { [int]$env:SCALEWORLD_DATA_DISK_NUMBER } else { 1 }),
    [string]$PreferredDriveLetter = $(if ($env:SCALEWORLD_DATA_DRIVE_LETTER) { $env:SCALEWORLD_DATA_DRIVE_LETTER } else { 'D' }),
    [switch]$SkipIfUnavailable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PrepLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [data-drive] $Message"
}

function New-DirectoryIfMissing {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-OrCreate-PreparedVolume {
    param(
        [int]$DiskNumber,
        [string]$PreferredLetter
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

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
        if (-not [string]::IsNullOrWhiteSpace($PreferredLetter) -and -not (Get-Volume -DriveLetter $PreferredLetter -ErrorAction SilentlyContinue)) {
            $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter $PreferredLetter -ErrorAction Stop
        } else {
            $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        }
    }

    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
    if (-not $volume -or -not $volume.FileSystem) {
        $volume = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel ("ScaleWorldData{0}" -f $DiskNumber) -Confirm:$false -ErrorAction Stop
    }

    if (-not $volume.DriveLetter) {
        if (-not [string]::IsNullOrWhiteSpace($PreferredLetter) -and -not (Get-Volume -DriveLetter $PreferredLetter -ErrorAction SilentlyContinue)) {
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $PreferredLetter -ErrorAction Stop
            $volume = Get-Volume -DriveLetter $PreferredLetter -ErrorAction Stop
        } else {
            throw "Data volume on disk $DiskNumber has no drive letter."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($PreferredLetter) -and $volume.DriveLetter -ne $PreferredLetter) {
        if (-not (Get-Volume -DriveLetter $PreferredLetter -ErrorAction SilentlyContinue)) {
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $PreferredLetter -ErrorAction Stop
            $volume = Get-Volume -DriveLetter $PreferredLetter -ErrorAction Stop
        }
    }

    return $volume
}

try {
    $volume = Get-OrCreate-PreparedVolume -DiskNumber $DataDiskNumber -PreferredLetter $PreferredDriveLetter
    $root = "{0}:\ScaleWorldBuilds" -f $volume.DriveLetter
    $staging = Join-Path $root 'staging'
    New-DirectoryIfMissing -Path $root
    New-DirectoryIfMissing -Path $staging

    Write-PrepLog "Prepared data drive $($volume.DriveLetter): for ScaleWorld builds."
    Write-PrepLog "Build root: $root"
    Write-PrepLog "Scratch root: $staging"
    exit 0
} catch {
    if ($SkipIfUnavailable.IsPresent) {
        Write-PrepLog "Data drive preparation failed: $($_.Exception.Message)" 'WARN'
        exit 0
    }

    Write-Error "Data drive preparation failed: $($_.Exception.Message)"
    exit 1
}
