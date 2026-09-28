[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'prepare-for-ami-bake.ps1') -FunctionsOnly

function Assert-Fails {
    param([scriptblock]$Action)
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw 'Expected generalization to fail closed.' }
}

$script:events = [Collections.Generic.List[string]]::new()
$script:reads = 0
$parameters = @{
    Generalize = { $script:events.Add('generalize') }
    ReadImageState = { $script:reads++; if ($script:reads -eq 1) { 'IMAGE_STATE_COMPLETE' } else { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } }
    SysprepIsRunning = { $false }
    PublishReceipt = { param($state) if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw 'Wrong proof' }; $script:events.Add('receipt') }
    Shutdown = { $script:events.Add('shutdown') }
    Wait = { }
    MaximumPolls = 2
}
Complete-VerifiedAmiGeneralization @parameters
if (($script:events -join ',') -ne 'generalize,receipt,shutdown') { throw 'Receipt must precede shutdown.' }

$script:events.Clear(); $script:reads = 0
$parameters.PublishReceipt = { throw 'S3 unavailable' }
Assert-Fails { Complete-VerifiedAmiGeneralization @parameters }
if ($script:events.Contains('shutdown')) { throw 'Shutdown occurred without durable proof.' }

$script:events.Clear(); $script:reads = 0
$parameters.PublishReceipt = { param($state) $script:events.Add('receipt') }
$parameters.Generalize = { throw 'Sysprep exit code 1' }
Assert-Fails { Complete-VerifiedAmiGeneralization @parameters }
if ($script:events.Count -ne 0) { throw 'Failure must not publish or shut down.' }

$script:events.Clear(); $script:reads = 0
$parameters.Generalize = { $script:events.Add('generalize') }
$parameters.ReadImageState = { 'IMAGE_STATE_UNDEPLOYABLE' }
Assert-Fails { Complete-VerifiedAmiGeneralization @parameters }
if (($script:events -join ',') -ne 'generalize') { throw 'Non-generalized state was accepted.' }

$script:events.Clear()
$parameters.ReadImageState = { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
Assert-Fails { Complete-VerifiedAmiGeneralization @parameters }
if ($script:events.Count -ne 0) { throw 'Stale generalization evidence must prevent rerun.' }

$script:reads = 0
$parameters.ReadImageState = { $script:reads++; if ($script:reads -eq 1) { 'IMAGE_STATE_COMPLETE' } else { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } }
$parameters.SysprepIsRunning = { $true }
Assert-Fails { Complete-VerifiedAmiGeneralization @parameters }
if (($script:events -join ',') -ne 'generalize') { throw 'An active Sysprep process was accepted.' }
Write-Output 'AMI generalization harness passed (6 scenarios; no Windows or AWS mutations).'
