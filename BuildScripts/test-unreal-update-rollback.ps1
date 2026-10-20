# Parse production functions without running the operational entry point.
# All install/state dependencies below are in-memory mocks; no AWS, CMD or
# process operation is performed and no real release directory is modified.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'SWupdate.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'SWupdate.ps1 has parser errors.' }
foreach ($name in @('Get-SafeReleaseName', 'Get-RollbackBackupRoot', 'New-RollbackBackupState',
    'Get-CurrentReleaseState', 'Get-PreviousReleaseState', 'Get-PendingReleaseState',
    'Set-ReleaseState', 'Set-PendingReleaseState', 'Remove-CurrentReleaseForUpdate',
    'Activate-PreparedRelease', 'Invoke-Rollback')) {
    $definition = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        Where-Object Name -eq $name)
    if ($definition.Count -ne 1) { throw "Expected one source function $name." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

$script:CurrentReleaseStatePath = 'current-state'
$script:PreviousReleaseStatePath = 'previous-state'
$script:PendingReleaseStatePath = 'pending-state'
$script:ActiveInstallPath = 'memory:/active'
$script:DownloadRoot = 'memory:/downloads'
$script:ReleasesRoot = 'memory:/releases'
$BucketName = 'synthetic-bucket'

function Join-Path { param([string]$Path, [string]$ChildPath) return $Path.TrimEnd('/') + '/' + $ChildPath }
function Test-Path { param([string]$LiteralPath) return $script:Paths.Contains($LiteralPath) }
function New-DirectoryIfMissing { param([string]$Path) [void]$script:Paths.Add($Path) }
function Read-StateMetadata { param([string]$Path) return $script:States[$Path] }
function Write-StateMetadata {
    param([string]$Path, $Value)
    if ($script:InjectedFailureStage -eq 'backup-state' -and $Path -eq 'previous-state' -and $Value.Source -eq 'rollback-backup') {
        $script:InjectedFailureStage = ''
        throw 'Injected backup-state failure'
    }
    if ($script:InjectedFailureStage -eq 'current-state' -and $Path -eq 'current-state' -and $null -eq $Value) {
        $script:InjectedFailureStage = ''
        throw 'Injected current-state failure'
    }
    $script:States[$Path] = $Value
}
function Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force)
    if (-not $script:Paths.Contains($LiteralPath)) { throw 'Missing mock copy source.' }
    [void]$script:Paths.Add($Destination)
    $script:BackupPath = $Destination
}
function Remove-Item {
    param([string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    if ($LiteralPath -eq 'memory:/releases/old' -and (Get-PreviousReleaseState).ReleasePath -ne $script:BackupPath) {
        throw 'Rollback backup was not durably registered before removing the old release.'
    }
    $script:Removals.Add($LiteralPath)
    [void]$script:Paths.Remove($LiteralPath)
}
function Move-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    if ($script:InjectedFailureStage -eq 'move') { $script:InjectedFailureStage = ''; throw 'Injected move failure' }
    [void]$script:Paths.Remove($LiteralPath)
    [void]$script:Paths.Add($Destination)
}
function Write-ReleaseMetadata {
    param([string]$ReleasePath, $Metadata)
    if ($script:InjectedFailureStage -eq 'metadata' -and $ReleasePath -eq 'memory:/releases/new') {
        $script:InjectedFailureStage = ''; throw 'Injected metadata failure'
    }
}
function Switch-ActiveRelease {
    param($ReleaseState)
    if ($script:InjectedFailureStage -eq 'junction') { $script:InjectedFailureStage = ''; throw 'Injected junction failure' }
    if (-not (Test-Path -LiteralPath $ReleaseState.ReleasePath)) { throw 'Cannot switch to missing mock release.' }
    $current = Get-CurrentReleaseState
    $previous = if ($current -and $current.ReleasePath -ne $ReleaseState.ReleasePath) { $current } else { Get-PreviousReleaseState }
    Set-ReleaseState -Current $ReleaseState -Previous $previous
}
function Write-UpdateLog { param([string]$Message, [string]$Level) }
function Publish-RuntimeStatus { param([string]$Status, [string]$Reason) }
function Test-IsReparsePoint { param([string]$Path) throw 'Unexpected reparse-point operation.' }

foreach ($failure in @('move', 'metadata', 'junction', 'current-state', 'backup-state', '')) {
    $script:InjectedFailureStage = $failure
    $script:Paths = [System.Collections.Generic.HashSet[string]]::new()
    $script:Removals = [System.Collections.Generic.List[string]]::new()
    $script:BackupPath = ''
    $old = [pscustomobject]@{ BuildId = 'old'; ZipKey = 'old.zip'; ReleasePath = 'memory:/releases/old'; Source = 'fixture'; ActivatedAtUtc = '2026-10-11T00:00:00Z' }
    $script:States = @{
        'current-state' = $old
        'previous-state' = [pscustomobject]@{ BuildId = 'older'; ReleasePath = 'memory:/releases/older' }
        'pending-state' = [pscustomobject]@{ BuildId = 'new'; ZipKey = 'new.zip'; Source = 'fixture'; ReleaseName = 'new'; PreparedPath = 'memory:/prepared/new' }
    }
    [void]$script:Paths.Add($old.ReleasePath)
    [void]$script:Paths.Add('memory:/prepared/new')
    $activationError = $null
    try { Activate-PreparedRelease -ExpectedZipKey 'new.zip' -RemoveCurrentReleaseFirst $true | Out-Null }
    catch { $activationError = $_.Exception.Message }
    if ($failure) {
        if ($activationError -ne "Injected $failure failure") { throw "Wrong failure for ${failure}: $activationError" }
        if ($failure -eq 'backup-state') {
            if ($script:Removals.Count -ne 0 -or (Get-CurrentReleaseState).ReleasePath -ne $old.ReleasePath) {
                throw 'Failed backup persistence modified the active release.'
            }
        } else {
            if (-not (Test-Path -LiteralPath $script:BackupPath) -or (Get-PreviousReleaseState).ReleasePath -ne $script:BackupPath) {
                throw "Backup is not recoverable after $failure."
            }
            Invoke-Rollback
            if ((Get-CurrentReleaseState).ReleasePath -ne $script:BackupPath) { throw 'Rollback did not restore the backup.' }
        }
    } else {
        if ($activationError) { throw $activationError }
        if ((Get-CurrentReleaseState).BuildId -ne 'new' -or (Get-PreviousReleaseState).ReleasePath -ne $script:BackupPath) {
            throw 'Successful activation did not preserve its rollback backup.'
        }
        if ($null -ne (Get-PendingReleaseState)) { throw 'Successful activation did not clear pending state.' }
    }
    Write-Host "PASS: Unreal rollback state scenario '$failure'."
}
