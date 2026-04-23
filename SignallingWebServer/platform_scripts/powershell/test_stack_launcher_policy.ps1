[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ContainsText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Content.Contains($Expected)) {
        throw $Message
    }
}

function Assert-DoesNotContainText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Unexpected,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Content.Contains($Unexpected)) {
        throw $Message
    }
}

$cmdRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\cmd')
$stackLauncherPath = Join-Path $cmdRoot 'start_streamer_stack.bat'
$unrealLauncherPath = Join-Path $PSScriptRoot 'start_scaleworld.ps1'

$stackLauncher = [System.IO.File]::ReadAllText($stackLauncherPath)
$unrealLauncher = [System.IO.File]::ReadAllText($unrealLauncherPath)

Assert-DoesNotContainText `
    -Content $stackLauncher `
    -Unexpected 'set "STACK_START_WATCHDOG=false"' `
    -Message 'Recovery mode must not disable watchdog supervision.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'if not defined SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS set "SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS=120"' `
    -Message 'Stack launcher must give the strict Unreal runtime process enough time to appear.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "STACK_LAUNCH_EXIT=0"' `
    -Message 'Stack launcher must track component startup failures instead of exiting before watchdog scheduling.'
Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '-LauncherGraceSeconds %SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS%' `
    -Message 'Launcher freshness detection must use the same window as the strict Unreal runtime wait.'


Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'Watchdog was scheduled when enabled for recovery.' `
    -Message 'Component startup failures must flow past watchdog scheduling before exit.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected 'else { 120 }' `
    -Message 'Direct Unreal launcher default runtime wait must match the stack launcher default.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected 'Stopped ScaleWorld launcher process PID' `
    -Message 'Failed strict Unreal launches must clean up the launcher process.'

Write-Output 'Stack launcher policy tests passed.'
