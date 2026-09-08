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

$developmentPath = Join-Path $installRoot 'ScaleWorld\Binaries\Win64\ScaleWorld.exe'
$developmentProcess = New-FakeProcess -Name 'ScaleWorld.exe' -CommandLine ('"' + $developmentPath + '" -PixelStreamingPort=8888') -ExecutablePath $developmentPath
Assert-ScaleWorldTrue (Test-ScaleWorldRuntimeProcessMatch -Process $developmentProcess -Matcher $strictMatcher) 'Strict matcher must recognize the nested Development runtime.'
$unrelatedProcess = New-FakeProcess -Name 'ScaleWorld.exe' -CommandLine ('"C:\Other\ScaleWorld.exe" -reference="' + $developmentPath + '"') -ExecutablePath 'C:\Other\ScaleWorld.exe'
Assert-ScaleWorldFalse (Test-ScaleWorldRuntimeProcessMatch -Process $unrelatedProcess -Matcher $strictMatcher) 'An unrelated same-name executable must not count as Development runtime.'
$developmentProcess.ExecutablePath = $null
Assert-ScaleWorldTrue (Test-ScaleWorldRuntimeProcessMatch -Process $developmentProcess -Matcher $strictMatcher) 'The exact executable token should support CIM snapshots without ExecutablePath.'
$unrelatedProcess.ExecutablePath = $null
Assert-ScaleWorldFalse (Test-ScaleWorldRuntimeProcessMatch -Process $unrelatedProcess -Matcher $strictMatcher) 'An executable path in command arguments must not count as a live runtime.'
$launcherProcess.ExecutablePath = $null
Assert-ScaleWorldFalse (Test-ScaleWorldRuntimeProcessMatch -Process $launcherProcess -Matcher $strictMatcher) 'The root bootstrap must remain excluded when CIM only supplies its command line.'

# Exercise the watchdog's actual rule function without starting supervision.
$tokens = $null
$parseErrors = $null
$watchdogAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'watchdog.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw $parseErrors[0] }
foreach ($name in @('Test-NameMatch', 'Find-MatchingProcesses')) {
    $definition = $watchdogAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $definition) { throw "Missing watchdog function $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$rule = [pscustomobject]@{ ProcessName = 'ScaleWorld-Win64-*'; CommandLinePattern = ''; DevelopmentRuntimeMatcher = $strictMatcher }
Assert-ScaleWorldTrue ((Find-MatchingProcesses -Snapshot @($developmentProcess) -Rule $rule).Count -eq 1) 'The default watchdog rule must recognize Development.'
Assert-ScaleWorldTrue ((Find-MatchingProcesses -Snapshot @($shippingProcess) -Rule $rule).Count -eq 1) 'The watchdog must still recognize Shipping.'
Assert-ScaleWorldTrue ((Find-MatchingProcesses -Snapshot @($launcherProcess, $unrelatedProcess) -Rule $rule).Count -eq 0) 'The watchdog must reject root launchers and unrelated Development processes.'
$rule.CommandLinePattern = '-expected-filter'
Assert-ScaleWorldTrue ((Find-MatchingProcesses -Snapshot @($developmentProcess) -Rule $rule).Count -eq 0) 'Development must still respect the watchdog command-line filter.'
$rule.CommandLinePattern = ''
$rule.ProcessName = 'ScaleWorld-Win64-Shipping.exe'
Assert-ScaleWorldTrue ((Find-MatchingProcesses -Snapshot @($developmentProcess) -Rule $rule).Count -eq 0) 'An explicit Shipping-only watchdog pattern must remain Shipping-only.'

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$junctionTestRoot = Join-Path $tempRoot ('scaleworld-process-junction-' + [guid]::NewGuid().ToString('N'))
$physicalRoot = Join-Path $junctionTestRoot 'release'
$activeRoot = Join-Path $junctionTestRoot 'active'
try {
    New-Item -ItemType Directory -Path $physicalRoot -Force | Out-Null
    New-Item -ItemType Junction -Path $activeRoot -Target $physicalRoot | Out-Null
    $junctionMatcher = Get-ScaleWorldRuntimeProcessMatcher -InstallRoot $activeRoot -RuntimeProcessPattern '' -IncludeLauncherExecutable $false
    $physicalRuntimePath = Join-Path $physicalRoot 'ScaleWorld\Binaries\Win64\ScaleWorld.exe'
    $physicalProcess = New-FakeProcess -Name 'ScaleWorld.exe' -CommandLine ('"' + $physicalRuntimePath + '"') -ExecutablePath $physicalRuntimePath
    Assert-ScaleWorldTrue (Test-ScaleWorldRuntimeProcessMatch -Process $physicalProcess -Matcher $junctionMatcher) 'Development detection must accept the physical release behind the active junction.'
    $staleProcess = New-FakeProcess -Name 'ScaleWorld.exe' -CommandLine '' -ExecutablePath (Join-Path $junctionTestRoot 'old-release\ScaleWorld\Binaries\Win64\ScaleWorld.exe')
    Assert-ScaleWorldFalse (Test-ScaleWorldRuntimeProcessMatch -Process $staleProcess -Matcher $junctionMatcher) 'A different release must not satisfy Development liveness.'
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $junctionTestRoot).Path)
    if (-not $resolvedRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe junction test cleanup path.' }
    if (Test-Path -LiteralPath $activeRoot) { [IO.Directory]::Delete($activeRoot) }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
$missingCreationDateProcess = [pscustomobject]@{
    Name = 'cmd.exe'
}
Assert-ScaleWorldTrue ($null -eq (Get-ScaleWorldProcessCreationUtcDateTime -Process $missingCreationDateProcess)) 'Creation date helper must tolerate process-like objects without CreationDate.'

$dateTimeCreationDateProcess = [pscustomobject]@{
    CreationDate = [DateTime]::SpecifyKind([DateTime]'2026-04-24T06:45:00Z', [DateTimeKind]::Utc)
}
Assert-ScaleWorldTrue ($null -ne (Get-ScaleWorldProcessCreationUtcDateTime -Process $dateTimeCreationDateProcess)) 'Creation date helper must tolerate DateTime CreationDate values.'

Write-Output 'ScaleWorld process helper tests passed.'
