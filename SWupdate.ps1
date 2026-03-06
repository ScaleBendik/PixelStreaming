<#
.SYNOPSIS
Setter opp Disk 1 som data-disk (simple volume) og bruker den til å lagre UE5-build ZIP fra S3,
og oppdaterer UE5-spillet.

KJØRES SOM ADMINISTRATOR
#>

[CmdletBinding()]
param(
    # Hvilken fysisk disk som skal brukes til data/staging (standard: Disk 1)
    [int]$DataDiskNumber = 1,


    # UE5 / S3-konfig
    [string]$BucketName      = "scaleworlddepot",
    [string]$BuildKey        = "Scaleworld_001/ScaleWorld_Latest.zip",   # juster etter ditt oppsett
    [string]$GameInstallPath = "C:\PixelStreaming\WindowsNoEditor",      # hvor builden skal pakkes ut
    [string]$ServiceName     = "ScaleWorld"                  # tjenesten/prosessen din
)

function Get-OrCreate-DataVolume {
    param(
        [int]$DiskNumber
    )

    if ($DiskNumber -eq 0) {
        throw "Av sikkerhetsgrunner opererer dette skriptet aldri på Disk 0 (systemdisk). Endre DataDiskNumber hvis du er HELT sikker."
    }

    Write-Host "Ser etter Disk $DiskNumber..." -ForegroundColor Cyan

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

    # Sørg for at disken er online og skrivbar
    if ($disk.IsOffline) {
        Write-Host "Disk $DiskNumber er offline, setter online..." -ForegroundColor Yellow
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
        $disk = Get-Disk -Number $DiskNumber
    }

    if ($disk.IsReadOnly) {
        Write-Host "Disk $DiskNumber er read-only, skrur av read-only..." -ForegroundColor Yellow
        Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction Stop
        $disk = Get-Disk -Number $DiskNumber
    }

    # Initialiser disk om den er RAW (dvs. helt ny)
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Host "Disk $DiskNumber er RAW, initialiserer som GPT..." -ForegroundColor Yellow
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop
        $disk = Get-Disk -Number $DiskNumber
    }

    # Finn eksisterende data-partisjon (som ikke er reserved) om den finnes
    $partition = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                 Where-Object { $_.Type -ne 'Reserved' } |
                 Select-Object -First 1

    if (-not $partition) {
        Write-Host "Fant ingen data-partisjon på Disk $DiskNumber. Oppretter ny simple volume..." -ForegroundColor Yellow
        $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    }

    # Finn eller opprett filsystem/volume
    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue

    if (-not $volume -or -not $volume.FileSystem) {
        Write-Host "Partition på Disk $DiskNumber mangler filsystem. Formaterer som NTFS..." -ForegroundColor Yellow
        $volume = Format-Volume -Partition $partition `
                                -FileSystem NTFS `
                                -NewFileSystemLabel ("DataDisk{0}" -f $DiskNumber) `
                                -Confirm:$false `
                                -ErrorAction Stop
    }
    else {
        Write-Host ("Bruker eksisterende volume {0}: på Disk {1}" -f $volume.DriveLetter, $DiskNumber) -ForegroundColor Green
    }

    if (-not $volume.DriveLetter) {
        # I tilfelle det ikke ble tildelt drive-letter automatisk
        Write-Host "Volume mangler drive-letter. Setter én..." -ForegroundColor Yellow
        $partition = Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.PartitionNumber -eq $partition.PartitionNumber }
        $partition = $partition | Set-Partition -NewDriveLetter (
            (65..90 | ForEach-Object { [char]$_ }) | Where-Object {
                -not (Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter -eq $_)
            } | Select-Object -First 1
        )
        $volume = $partition | Get-Volume
    }

    Write-Host ("Data-disk klar: {0}: (Label: {1})" -f $volume.DriveLetter, $volume.FileSystemLabel) -ForegroundColor Green

    return $volume
}

function New-DirectoryIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}


try {
    Write-Host "=== UE5 update script using Disk $DataDiskNumber ===" -ForegroundColor Cyan

    # 1) Sett opp / hent data-volum på Disk 1
    $dataVolume = Get-OrCreate-DataVolume -DiskNumber $DataDiskNumber
    $dataDrive  = $dataVolume.DriveLetter

    # Mappe på data-disken der ZIP skal ligge
    $DownloadRoot = ("{0}:\ScaleWorldBuilds" -f $dataDrive)
    New-DirectoryIfMissing -Path $DownloadRoot

    $DownloadPath = Join-Path $DownloadRoot "ScaleWorld.zip"

    Write-Host ("ZIP vil lagres til: {0}" -f $DownloadPath) -ForegroundColor Cyan

    # 2) Sjekk at AWS CLI finnes
    $awsCmd = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $awsCmd) {
        throw "AWS CLI ('aws') ble ikke funnet i PATH. Installer AWS CLI v2 på denne instansen før du kjører skriptet."
    }
<#
    # 3) Stopp UE5-tjenesten (om den finnes)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') {
            Write-Host "Stopper tjeneste '$ServiceName'..." -ForegroundColor Yellow
            Stop-Service -Name $ServiceName -Force -ErrorAction Continue
            $svc.WaitForStatus('Stopped', '00:00:30')
        }
        else {
            Write-Host "Tjeneste '$ServiceName' er allerede stoppet." -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Host "Fant ingen Windows-tjeneste med navn '$ServiceName'. Hopper over stopp av tjeneste." -ForegroundColor DarkYellow
    }
#>
    # 4) Last ned build fra S3 til data-disken
    Write-Host ("Laster ned s3://{0}/{1} til {2} ..." -f $BucketName, $BuildKey, $DownloadPath) -ForegroundColor Cyan

    # Slett gammel ZIP hvis den finnes
    if (Test-Path $DownloadPath) {
        Write-Host "Sletter eksisterende ZIP på $DownloadPath..." -ForegroundColor DarkYellow
        Remove-Item $DownloadPath -Force
    }

    aws s3 cp ("s3://{0}/{1}" -f $BucketName, $BuildKey) $DownloadPath --no-progress
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DownloadPath)) {
        throw "aws s3 cp feilet (exit code $LASTEXITCODE) eller filen ble ikke lastet ned."
    }

    Write-Host "Nedlasting fullført." -ForegroundColor Green

    # 5) Klargjør mappe for selve spillet
    New-DirectoryIfMissing -Path $GameInstallPath

Write-Host ("Renser gammel build i {0}..." -f $GameInstallPath) -ForegroundColor Yellow

# Ting du vil BEHOLDE i rotmappa
$keepTopLevel = @(
    'runScaleWorld.bat',       # mappe
    'Start_ScaleWorldWithparams.ps1'    # fil
)

Get-ChildItem -Path $GameInstallPath -Force |
    Where-Object { $keepTopLevel -notcontains $_.Name } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # 6) Pakk ut ny build
    Write-Host ("Pakker ut ZIP (uten ekstra rotmappe)..." -f $GameInstallPath) -ForegroundColor Cyan

    # Midlertidig extract-mappe på data-disken
    $tempExtractRoot = Join-Path $DownloadRoot "extract_tmp"
    
    # Rydd opp gammel temp hvis den finnes
    if (Test-Path $tempExtractRoot) {
        Remove-Item $tempExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    New-Item -ItemType Directory -Path $tempExtractRoot -Force | Out-Null
    
    # 1) Pakk ut til temp-mappe
    Expand-Archive -Path $DownloadPath -DestinationPath $tempExtractRoot -Force
    
    # 2) Finn hvor innholdet faktisk ligger
    #    (typisk: én rotmappe inni zippet, f.eks. "MyGameBuild\...")
    $innerItems = Get-ChildItem -Path $tempExtractRoot -Force
    
    if ($innerItems.Count -eq 1 -and $innerItems[0].PSIsContainer) {
        # ZIP-en har én toppmappe - bruk INNHOLDET inni den
        $contentSource = $innerItems[0].FullName
        Write-Host ("Fant enkelt rotfolder i zip: {0} - flytter kun innholdet." -f $innerItems[0].Name) -ForegroundColor DarkCyan
    }
    else {
        # ZIP-en har flere ting i root - bruk alt direkte
        $contentSource = $tempExtractRoot
        Write-Host "Zip har flere elementer i rot - flytter alt innhold direkte." -ForegroundColor DarkCyan
    }
    
    # 3) Flytt innholdet til install-mappa (uten ekstra rotmappe)
    Get-ChildItem -Path $contentSource -Force |
        Move-Item -Destination $GameInstallPath -Force
    
    # 4) Rydd opp temp-mappa
    Remove-Item $tempExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host "Utpakking fullført (uten ekstra rotmappe)." -ForegroundColor Green
    

    # 7) Start tjenesten igjen (hvis den fantes)
    if ($svc) {
        Write-Host "Starter tjeneste '$ServiceName'..." -ForegroundColor Yellow
        Start-Service -Name $ServiceName -ErrorAction Continue
    }

    Write-Host "=== UE5 update fullført OK ===" -ForegroundColor Green
}
catch {
    Write-Error "FEIL under UE5 update: $($_.Exception.Message)"
    exit 1
}
