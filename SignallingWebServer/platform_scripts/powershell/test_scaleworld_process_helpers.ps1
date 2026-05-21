[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperScriptPath = Join-Path $PSScriptRoot 'scaleworld_process_helpers.ps1'
. $helperScriptPath

function Assert-ScaleWorldTrue {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ScaleWorldFalse {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        throw $Message
    }
}

function New-FakeProcess {
    param(
        [string]$Name,
        [string]$CommandLine,
        [string]$ExecutablePath
    )

    return [pscustomobject]@{
        Name = $Name
        CommandLine = $CommandLine
        ExecutablePath = $ExecutablePath
        ProcessId = 1234
        CreationDate = $null
    }
}

$installRoot = 'C:\PixelStreaming\WindowsNoEditor'
$strictMatcher = Get-ScaleWorldRuntimeProcessMatcher -InstallRoot $installRoot -ExecutableName 'ScaleWorld.exe' -RuntimeProcessPattern '' -IncludeLauncherExecutable $false
$broadMatcher = Get-ScaleWorldRuntimeProcessMatcher -InstallRoot $installRoot -ExecutableName 'ScaleWorld.exe' -RuntimeProcessPattern '' -IncludeLauncherExecutable $true

$launcherProcess = New-FakeProcess -Name 'ScaleWorld.exe' -CommandLine '"C:\PixelStreaming\WindowsNoEditor\ScaleWorld.exe" -PixelStreamingPort=8888' -ExecutablePath 'C:\PixelStreaming\WindowsNoEditor\ScaleWorld.exe'
$shippingProcess = New-FakeProcess -Name 'ScaleWorld-Win64-Shipping.exe' -CommandLine '"C:\PixelStreaming\WindowsNoEditor\ScaleWorld\Binaries\Win64\ScaleWorld-Win64-Shipping.exe" -PixelStreamingPort=8888' -ExecutablePath 'C:\PixelStreaming\WindowsNoEditor\ScaleWorld\Binaries\Win64\ScaleWorld-Win64-Shipping.exe'

Assert-ScaleWorldFalse (Test-ScaleWorldRuntimeProcessMatch -Process $launcherProcess -Matcher $strictMatcher) 'Strict matcher must not treat the root ScaleWorld.exe launcher as a live Unreal runtime.'
Assert-ScaleWorldTrue (Test-ScaleWorldRuntimeProcessMatch -Process $shippingProcess -Matcher $strictMatcher) 'Strict matcher should detect the packaged Win64 Unreal runtime process.'
Assert-ScaleWorldTrue (Test-ScaleWorldRuntimeProcessMatch -Process $launcherProcess -Matcher $broadMatcher) 'Broad matcher should still include the launcher so recycle can terminate it.'
$missingCreationDateProcess = [pscustomobject]@{
    Name = 'cmd.exe'
}
Assert-ScaleWorldTrue ($null -eq (Get-ScaleWorldProcessCreationUtcDateTime -Process $missingCreationDateProcess)) 'Creation date helper must tolerate process-like objects without CreationDate.'

$dateTimeCreationDateProcess = [pscustomobject]@{
    CreationDate = [DateTime]::SpecifyKind([DateTime]'2026-04-24T06:45:00Z', [DateTimeKind]::Utc)
}
Assert-ScaleWorldTrue ($null -ne (Get-ScaleWorldProcessCreationUtcDateTime -Process $dateTimeCreationDateProcess)) 'Creation date helper must tolerate DateTime CreationDate values.'

Write-Output 'ScaleWorld process helper tests passed.'
