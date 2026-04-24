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
$stackRecycleLauncherPath = Join-Path $cmdRoot 'start_stack_recycle.bat'
$stackRecycleScriptPath = Join-Path $PSScriptRoot 'invoke_stack_recycle.ps1'
$unrealLauncherPath = Join-Path $PSScriptRoot 'start_scaleworld.ps1'
$watchdogPath = Join-Path $PSScriptRoot 'watchdog.ps1'
$viewerIdleStopPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\src\viewer-idle-stop.ts')
$instanceAgentPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\src\instance-agent.ts')

$stackLauncher = [System.IO.File]::ReadAllText($stackLauncherPath)
$stackRecycleLauncher = [System.IO.File]::ReadAllText($stackRecycleLauncherPath)
$stackRecycleScript = [System.IO.File]::ReadAllText($stackRecycleScriptPath)
$unrealLauncher = [System.IO.File]::ReadAllText($unrealLauncherPath)
$watchdog = [System.IO.File]::ReadAllText($watchdogPath)
$viewerIdleStop = [System.IO.File]::ReadAllText($viewerIdleStopPath)
$instanceAgent = [System.IO.File]::ReadAllText($instanceAgentPath)

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

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'LauncherGraceSeconds' `
    -Message 'Watchdog must expose a launcher grace window before declaring the runtime missing.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'Get-FreshLauncherMatchesForRule' `
    -Message 'Watchdog must treat fresh component launchers as startup in progress.'
Assert-ContainsText `
    -Content $watchdog `
    -Expected "PSObject.Properties['CreationDate']" `
    -Message 'Watchdog must tolerate process-like objects without CreationDate under StrictMode.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'foreach ($match in $launcherMatches)' `
    -Message 'Watchdog must not wrap empty launcher match arrays as process matches.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'Waiting for in-progress launcher before declaring a missing process' `
    -Message 'Watchdog must log launcher waits instead of reporting the stack healthy.'

Assert-ContainsText `
    -Content $stackRecycleLauncher `
    -Expected 'start "ScaleWorld Stack Recycle" /min powershell' `
    -Message 'Stack recycle must be launched through cmd start so it survives Wilbur exit.'

Assert-ContainsText `
    -Content $stackRecycleLauncher `
    -Expected 'stack-recycle-launch.log' `
    -Message 'Stack recycle launcher must leave a launch breadcrumb for runtime diagnosis.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'start_stack_recycle.bat' `
    -Message 'Viewer idle stop must launch the Windows recycle launcher instead of relying on a Node-owned helper process.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'exited before it could be stopped' `
    -Message 'Stack recycle must tolerate process-exit races while terminating launcher processes.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'if ($remaining)' `
    -Message 'Stack recycle must still fail when a process remains after Stop-Process fails.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected '$matches = @(Get-RecycleProcessMatches' `
    -Message 'Stack recycle process absence checks must keep scalar results array-shaped under StrictMode.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected '$matches = @(Get-RecycleUnrealProcessMatches' `
    -Message 'Stack recycle Unreal checks must keep scalar results array-shaped under StrictMode.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'recoveredRecycleTokenAtStartup' `
    -Message 'Viewer idle stop must remember recycle tokens recovered with a recycle marker.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'Treating it as already launched and waiting for instance-agent completion' `
    -Message 'Viewer idle stop must not re-arm a token from an already launched recycle.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'Ignoring recovered recycle request token' `
    -Message 'Viewer idle stop must ignore stale recovered recycle tokens after startup refreshes.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'shouldSuppressNoViewerIdleAutomation' `
    -Message 'Viewer idle stop must have an explicit guard for warm-held no-viewer idle automation.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'without first-viewer/no-viewer stop or recycle' `
    -Message 'Warm-held instances must not stop or recycle only because no viewer is present.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'warm hold will wait for an explicit teardown command before recycling' `
    -Message 'Warm-held reconnect grace must wait for explicit teardown instead of self-recycling.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'const readActiveCommand = () =>' `
    -Message 'Viewer idle stop must refresh active command state from the instance agent before acting on recycle intent.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'activeCommand = options.instanceAgentClient.getActiveCommand();' `
    -Message 'Viewer idle stop must not keep stale recovered commands after the instance agent clears its command journal.'
Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'recoveredActiveCommandId' `
    -Message 'Instance agent must distinguish commands recovered from the command journal from newly received commands.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected "activeCommand.instanceCommandId !== recoveredActiveCommandId" `
    -Message 'Recovered command finalization must not complete a newly received recycle command against a stale ready snapshot.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected "activeCommand.status !== 'running'" `
    -Message 'Recovered command finalization must only complete commands that were already running before restart.'
Write-Output 'Stack launcher policy tests passed.'
