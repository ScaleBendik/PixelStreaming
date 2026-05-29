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

function Assert-MatchesText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not [regex]::IsMatch($Content, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        throw $Message
    }
}

$cmdRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\cmd')
$stackLauncherPath = Join-Path $cmdRoot 'start_streamer_stack.bat'
$stackRecycleLauncherPath = Join-Path $cmdRoot 'start_stack_recycle.bat'
$startDevTurnPath = Join-Path $cmdRoot 'start_dev_turn.bat'
$startWatchdogPath = Join-Path $cmdRoot 'start_watchdog.bat'
$commonCmdPath = Join-Path $cmdRoot 'common.bat'
$stackRecycleScriptPath = Join-Path $PSScriptRoot 'invoke_stack_recycle.ps1'
$unrealLauncherPath = Join-Path $PSScriptRoot 'start_scaleworld.ps1'
$watchdogPath = Join-Path $PSScriptRoot 'watchdog.ps1'
$viewerIdleStopPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\src\viewer-idle-stop.ts')
$connectTicketAuthPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\src\ConnectTicketAuth.ts')
$connectTicketRuntimeStatePath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\src\connect-ticket-runtime-state.ts')
$instanceAgentPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\src\instance-agent.ts')
$repoSyncPath = Join-Path $PSScriptRoot 'ensure_repo_current.ps1'
$repoHeadPublisherPath = Join-Path $PSScriptRoot 'publish_repo_head_tags.ps1'
$deliveryModeResolverPath = Join-Path $PSScriptRoot 'resolve_pixelstreaming_delivery_mode_from_instance_tag.ps1'
$runtimeInstallerPath = Join-Path $PSScriptRoot 'install_pixelstreaming_runtime.ps1'
$updateModePath = Join-Path $PSScriptRoot 'invoke_update_mode.ps1'
$stopSupersededRootPath = Join-Path $PSScriptRoot 'stop_superseded_root_processes.ps1'

$stackLauncher = [System.IO.File]::ReadAllText($stackLauncherPath)
$stackRecycleLauncher = [System.IO.File]::ReadAllText($stackRecycleLauncherPath)
$startDevTurn = [System.IO.File]::ReadAllText($startDevTurnPath)
$startWatchdog = [System.IO.File]::ReadAllText($startWatchdogPath)
$commonCmd = [System.IO.File]::ReadAllText($commonCmdPath)
$stackRecycleScript = [System.IO.File]::ReadAllText($stackRecycleScriptPath)
$unrealLauncher = [System.IO.File]::ReadAllText($unrealLauncherPath)
$watchdog = [System.IO.File]::ReadAllText($watchdogPath)
$viewerIdleStop = [System.IO.File]::ReadAllText($viewerIdleStopPath)
$connectTicketAuth = [System.IO.File]::ReadAllText($connectTicketAuthPath)
$connectTicketRuntimeState = [System.IO.File]::ReadAllText($connectTicketRuntimeStatePath)
$instanceAgent = [System.IO.File]::ReadAllText($instanceAgentPath)
$repoSync = [System.IO.File]::ReadAllText($repoSyncPath)
$repoHeadPublisher = [System.IO.File]::ReadAllText($repoHeadPublisherPath)
$deliveryModeResolver = [System.IO.File]::ReadAllText($deliveryModeResolverPath)
$runtimeInstaller = [System.IO.File]::ReadAllText($runtimeInstallerPath)
$updateMode = [System.IO.File]::ReadAllText($updateModePath)
$stopSupersededRoot = [System.IO.File]::ReadAllText($stopSupersededRootPath)

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
    -Expected 'if not defined STACK_LAUNCH_UNREAL_BEFORE_WILBUR set "STACK_LAUNCH_UNREAL_BEFORE_WILBUR=true"' `
    -Message 'Stack launcher should start Unreal before waiting for Wilbur by default while preserving the env override.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "STACK_LAUNCH_EXIT=0"' `
    -Message 'Stack launcher must track component startup failures instead of exiting before watchdog scheduling.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=git_ref"' `
    -Message 'Dev startup must keep the fast git-target-ref delivery path as the default.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=auto"' `
    -Message 'Stage/Prod startup should preserve runtime-artifact delegation while retaining git-ref fallback during migration.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'if /i not "%STACK_MODE%"=="validation" if /i "%STACK_ENABLE_ACTIVE_RUNTIME_DELEGATION%"=="true"' `
    -Message 'Active runtime delegation must run for normal and recovery starts so bootstrap-root watchdog recovery cannot bypass the active runtime.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'if /i "!ACTIVE_RUNTIME_DELEGATED!"=="true" exit /b !ACTIVE_RUNTIME_DELEGATE_EXIT!' `
    -Message 'A successful active runtime delegation must be a terminal handoff so the bootstrap checkout cannot launch a second stack.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_RESTART_COMMAND=""!ACTIVE_RUNTIME_SCRIPT_DIR!start_streamer_stack.bat"" --recovery"' `
    -Message 'Delegated active runtime startup must bind watchdog stack recovery to the active runtime launcher, not the bootstrap checkout.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_WILBUR_RESTART_COMMAND=""!ACTIVE_RUNTIME_SCRIPT_DIR!start_dev_turn.bat"""' `
    -Message 'Delegated active runtime startup must bind Wilbur recovery to the active runtime launcher directory.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_UNREAL_RESTART_COMMAND=""!ACTIVE_RUNTIME_SCRIPT_DIR!start_unreal.bat"""' `
    -Message 'Delegated active runtime startup must bind Unreal recovery to the active runtime launcher directory.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'stop_superseded_root_processes.ps1' `
    -Message 'Delegated active runtime startup must retire superseded bootstrap-root supervisors before handing off.'

Assert-ContainsText `
    -Content $stopSupersededRoot `
    -Expected 'Get-SupersededProcessMatches' `
    -Message 'Superseded root cleanup helper must enumerate old-root processes before active-runtime handoff.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '-AllRoots -WaitSeconds 3' `
    -Message 'Active-runtime stack launches must sweep stale supervisors from any non-active PixelStreaming root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'call :stop_superseded_runtime_roots_before_stack_launch' `
    -Message 'Active-runtime cleanup must run for auto and explicit runtime-artifact launches.'

Assert-MatchesText `
    -Content $stackLauncher `
    -Pattern 'if not defined WATCHDOG_RESTART_COMMAND set "WATCHDOG_RESTART_COMMAND=.*?\r?\n\r?\ncall :stop_superseded_runtime_roots_before_stack_launch' `
    -Message 'Active-runtime cleanup must not be gated on exact runtime_artifact mode because stage auto mode also delegates to the active runtime.'

Assert-ContainsText `
    -Content $stopSupersededRoot `
    -Expected '[switch]$AllRoots' `
    -Message 'Superseded root cleanup helper must support active-runtime all-root cleanup.'

Assert-ContainsText `
    -Content $stopSupersededRoot `
    -Expected '$activeRootTargetPath' `
    -Message 'All-root cleanup must preserve processes launched through the active runtime junction target.'

Assert-ContainsText `
    -Content $stopSupersededRoot `
    -Expected 'start_watchdog.bat' `
    -Message 'Superseded root cleanup helper must retire old-root watchdog launchers.'

Assert-ContainsText `
    -Content $stopSupersededRoot `
    -Expected "-or (Test-CommandLineContainsPath -CommandLine `$commandLine -Path `$currentWatchdogLauncher)" `
    -Message 'Superseded root cleanup helper must retire delayed PowerShell watchdog launchers before they start a stale root.'

Assert-ContainsText `
    -Content $stopSupersededRoot `
    -Expected 'start_dev_turn.bat' `
    -Message 'Superseded root cleanup helper must retire old-root Wilbur launchers.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '$watchdogScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ''..\powershell\watchdog.ps1''))' `
    -Message 'Watchdog duplicate detection must be scoped to the current launcher root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '$watchdogLauncher = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ''start_watchdog.bat''))' `
    -Message 'Watchdog launcher duplicate detection must be scoped to the current launcher root.'

Assert-DoesNotContainText `
    -Content $stackLauncher `
    -Unexpected "CommandLine -like '*watchdog.ps1*'" `
    -Message 'Watchdog duplicate detection must not treat another PixelStreaming root as equivalent.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected "Global\ScaleWorldWatchdog" `
    -Message 'Watchdog must use an instance-global mutex so bootstrap and active runtime roots cannot run concurrent supervisors.'

Assert-DoesNotContainText `
    -Content $watchdog `
    -Unexpected 'ScaleWorldWatchdog-$watchdogMutexHash' `
    -Message 'Watchdog mutex must not be root-scoped; root-scoped mutexes allow bootstrap and active runtime supervisors to coexist.'

Assert-ContainsText `
    -Content $startWatchdog `
    -Expected 'set "WATCHDOG_WILBUR_RESTART_COMMAND=%WATCHDOG_RESTART_COMMAND%"' `
    -Message 'Default Wilbur recovery must use stack recovery so bootstrap-root watchdogs cannot bypass active-runtime delegation.'

Assert-DoesNotContainText `
    -Content $startWatchdog `
    -Unexpected 'set "WATCHDOG_WILBUR_RESTART_COMMAND=""%SCRIPT_DIR%start_dev_turn.bat"""' `
    -Message 'Default Wilbur recovery must not directly launch the current root because bootstrap roots can bypass active-runtime delegation.'

Assert-ContainsText `
    -Content $startWatchdog `
    -Expected 'set "WATCHDOG_UNREAL_RESTART_COMMAND=%WATCHDOG_RESTART_COMMAND%"' `
    -Message 'Default Unreal recovery must use stack recovery so bootstrap-root watchdogs cannot bypass active-runtime delegation.'

Assert-DoesNotContainText `
    -Content $startWatchdog `
    -Unexpected 'set "WATCHDOG_UNREAL_RESTART_COMMAND=""%SCRIPT_DIR%start_unreal.bat"""' `
    -Message 'Default Unreal recovery must not directly launch the current root because bootstrap roots can bypass active-runtime delegation.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'Invoke-ActiveRuntimeSupersededRootCleanup -Force' `
    -Message 'Active-runtime watchdog startup must proactively retire stale non-active root supervisors.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'Invoke-ActiveRuntimeSupersededRootCleanup' `
    -Message 'Active-runtime watchdog must periodically retire stale non-active root supervisors after startup ordering races.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '-AllRoots -WaitSeconds 1' `
    -Message 'Active-runtime watchdog cleanup must use all-root cleanup without blocking the health loop for long.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$cleanupIntervalSeconds = 15' `
    -Message 'Active-runtime watchdog cleanup must run frequently enough to retire old per-root supervisors from already-deployed artifacts.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'Test-CurrentRootIsActiveRuntime' `
    -Message 'Superseded root cleanup must only run from the active runtime watchdog, not from bootstrap or legacy roots.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'PixelStreaming delivery mode runtime_artifact requires an installed active runtime' `
    -Message 'Explicit runtime-artifact mode must fail closed when the active runtime is missing.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WILBUR_COMMANDLINE_PATTERN=%PIXELSTREAMING_ROOT%\SignallingWebServer"' `
    -Message 'Wilbur detection must be scoped to the runtime root so stale bootstrap-root Wilbur cannot satisfy active-runtime startup.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WILBUR_LAUNCHER_PATTERN=%SCRIPT_DIR%start_dev_turn.bat"' `
    -Message 'Wilbur launcher detection must be scoped to the runtime root so stale bootstrap-root launchers cannot satisfy active-runtime startup.'

Assert-DoesNotContainText `
    -Content $stackLauncher `
    -Unexpected 'set "WILBUR_COMMANDLINE_PATTERN=index.js"' `
    -Message 'Normal startup must not use broad Wilbur detection across PixelStreaming roots.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$currentWilburLauncher = Join-Path $script:SignallingWebServerRoot ''platform_scripts\cmd\start_dev_turn.bat''' `
    -Message 'Watchdog launcher grace checks must be scoped to the current runtime root.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'CommandLinePattern = $currentWilburLauncher' `
    -Message 'Watchdog must not treat another root''s Wilbur launcher as recovery progress.'

Assert-DoesNotContainText `
    -Content $watchdog `
    -Unexpected "else { 'index.js' }" `
    -Message 'Watchdog must not use broad Wilbur process detection when invoked directly.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected 'function Stop-ExistingStreamerStackForValidation' `
    -Message 'Update mode must stop the previous streamer stack before runtime-artifact validation.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected 'Stop-ExistingStreamerStackForValidation' `
    -Message 'Runtime-artifact validation must not be blocked by a pre-existing git-ref stack.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'Using deployment-track default delivery mode.' `
    -Message 'Missing optional delivery-mode tags must fall back immediately instead of adding retry delay to normal startup.'

Assert-ContainsText `
    -Content $commonCmd `
    -Expected 'Root node_modules found...skipping dependency install after NodeJS download.' `
    -Message 'Runtime artifact startup must not run npm install just because portable Node was missing.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected '[System.IO.Compression.ZipFile]::ExtractToDirectory' `
    -Message 'Runtime artifact installer should use the faster .NET ZIP extraction path.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "Key = 'ScaleWorldPixelStreamingDeliveryMode'" `
    -Message 'Git-ref startup must publish its delivery mode for Fleet status.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "'ScaleWorldPixelStreamingRuntimeBundleId'" `
    -Message 'Git-ref startup must clear stale runtime artifact identity tags.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "preserved runtime artifact delivery tags" `
    -Message 'Repo-head publishing must not overwrite runtime-artifact delivery identity after an artifact update.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "Leaving PixelStreaming delivery identity unchanged" `
    -Message 'Repo-head publishing must fail non-destructively when it cannot confirm git-ref delivery.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "runtime artifact-like delivery tags" `
    -Message 'Repo-head publishing must preserve runtime artifact identity unless git-ref delivery is explicit.'

Assert-ContainsText `
    -Content $deliveryModeResolver `
    -Expected "ScaleWorldPixelStreamingRuntimeBundleId" `
    -Message 'Delivery-mode resolution must infer runtime-artifact mode from existing runtime identity tags when the mode tag is absent.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '-LauncherGraceSeconds %SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS%' `
    -Message 'Launcher freshness detection must use the same window as the strict Unreal runtime wait.'


Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'Watchdog was scheduled when enabled for recovery.' `
    -Message 'Component startup failures must flow past watchdog scheduling before exit.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected ':load_runtime_parameters' `
    -Message 'Wilbur startup must batch runtime parameter loading into one SSM request.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'ssm get-parameters --names %RUNTIME_PARAMETER_NAMES%' `
    -Message 'Wilbur startup must use SSM get-parameters instead of serial get-parameter calls.'

Assert-DoesNotContainText `
    -Content $startDevTurn `
    -Unexpected 'get-parameter --name "%TURN_USER_PARAM%"' `
    -Message 'Wilbur startup must not read the TURN username with a separate SSM request.'

Assert-DoesNotContainText `
    -Content $startDevTurn `
    -Unexpected 'get-parameter --name "%TURN_CREDENTIAL_PARAM%"' `
    -Message 'Wilbur startup must not read the TURN credential with a separate SSM request.'

Assert-DoesNotContainText `
    -Content $startDevTurn `
    -Unexpected 'get-parameter --name "%CONNECT_TICKET_SIGNING_KEY_PARAM%"' `
    -Message 'Wilbur startup must not read the connect-ticket signing key with a separate SSM request.'

Assert-DoesNotContainText `
    -Content $startDevTurn `
    -Unexpected 'get-parameter --name "%INSTANCE_AGENT_API_BASE_URL_PARAM%"' `
    -Message 'Wilbur startup must not read the instance-agent API URL with a separate SSM request.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/dev/instance-agent-control-plane-env' `
    -Message 'Wilbur startup must support a Dev deployment-track control-plane env parameter.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'call :resolve_instance_agent_control_plane_env' `
    -Message 'Wilbur startup must resolve the instance-agent control-plane env before loading the bootstrap secret.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL' `
    -Message 'Wilbur startup must infer the control-plane env from known hosted API URLs to keep URL and secret paired.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM=/pixelstreaming/dev/instance-agent-bootstrap-shared-secret' `
    -Message 'Wilbur startup must derive the Dev bootstrap secret path from the effective control-plane env.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'Stage deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/stage/git-target-ref controls startup.' `
    -Message 'Canonical stack startup must force Stage off stale upstream git sync overrides.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'Stage deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/stage/git-target-ref controls startup.' `
    -Message 'Wilbur startup must force Stage off stale upstream git sync overrides.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'Prod deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/prod/git-target-ref controls startup.' `
    -Message 'Canonical stack startup must force Prod off upstream git sync overrides.'

Assert-MatchesText `
    -Content $startDevTurn `
    -Pattern 'else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" \(\s*set "INSTANCE_AGENT_API_BASE_URL_PARAM=/pixelstreaming/stage/instance-agent-api-base-url"\s*\) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev"' `
    -Message 'Stage instance-agent API URL resolution must not fall back to the legacy nonprod parameter.'

Assert-MatchesText `
    -Content $startDevTurn `
    -Pattern 'else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" \(\s*set "INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/stage/instance-agent-control-plane-env"\s*\) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev"' `
    -Message 'Stage instance-agent control-plane env resolution must not fall back to the legacy nonprod parameter.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected 'else { 120 }' `
    -Message 'Direct Unreal launcher default runtime wait must match the stack launcher default.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/dev/instance-agent-control-plane-env' `
    -Message 'Wilbur startup must support a Dev deployment-track control-plane env parameter.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'call :resolve_instance_agent_control_plane_env' `
    -Message 'Wilbur startup must resolve the instance-agent control-plane env before loading the bootstrap secret.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL' `
    -Message 'Wilbur startup must infer the control-plane env from known hosted API URLs to keep URL and secret paired.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM=/pixelstreaming/dev/instance-agent-bootstrap-shared-secret' `
    -Message 'Wilbur startup must derive the Dev bootstrap secret path from the effective control-plane env.'
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
    -Content $watchdog `
    -Expected 'StreamerHealthUnreadyRecoverySeconds' `
    -Message 'Watchdog must expose a bounded streamer-health recovery window.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'awaiting CPU stall confirmation or' `
    -Message 'Watchdog must preserve CPU stall confirmation while bounding indefinite unhealthy streamer states.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'streamer_health_file_stale' `
    -Message 'Watchdog must treat stale streamer health as a hard health fault.'

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
    -Expected 'Resolve-StackRecycleScriptRoot' `
    -Message 'Stack recycle must resolve its script root even when invoked without an explicit RepoRoot.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'return $hasNamePattern' `
    -Message 'Stack recycle process matching must not treat a process name match as sufficient when command-line filters are present.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected '$matches = @(Get-RecycleUnrealProcessMatches' `
    -Message 'Stack recycle Unreal checks must keep scalar results array-shaped under StrictMode.'
Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'Wait-ForStreamerHealthReadiness' `
    -Message 'Stack recycle must wait for streamer runtime readiness after restart.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'snapshot predates recycle restart' `
    -Message 'Stack recycle must not accept stale pre-recycle streamer health snapshots.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected '$status.Equals(''ready''' `
    -Message 'Stack recycle must require runtime ready status, not only a running Unreal process.'

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
    -Expected 'Recycling warm instance for post-session cleanup' `
    -Message 'Warm-held reconnect grace expiry must recycle for post-session cleanup even without an explicit teardown command.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'warm hold will recycle when grace expires unless an explicit teardown command arrives first' `
    -Message 'Warm-held reconnect grace must document that expiry triggers recycle unless a command arrives first.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'const readActiveCommand = (): RuntimeInstanceCommand | null =>' `
    -Message 'Viewer idle stop must refresh active command state from the instance agent before acting on recycle intent.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'activeCommand = options.instanceAgentClient.getActiveCommand();' `
    -Message 'Viewer idle stop must not keep stale recovered commands after the instance agent clears its command journal.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'Disconnecting viewers before teardown' `
    -Message 'Explicit teardown commands must disconnect active viewers instead of waiting for the browser tab to close.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'markConnectTicketTeardownStarted' `
    -Message 'Explicit teardown commands must revoke active connect tickets before disconnecting viewers.'

Assert-ContainsText `
    -Content $connectTicketAuth `
    -Expected 'runtimeGate?.rejectReasonForTicket' `
    -Message 'Player websocket auth must consult runtime teardown state before accepting a connect ticket.'

Assert-ContainsText `
    -Content $connectTicketRuntimeState `
    -Expected 'rejectTicketsIssuedAtOrBeforeEpochSeconds' `
    -Message 'Connect-ticket teardown revocation must persist a cutoff across Wilbur restarts.'
Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'if not defined INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF set "INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF=false"' `
    -Message 'Streamer startup must expose an opt-in hosted identity proof requirement.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected '--instance_agent_require_identity_proof="%INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF%"' `
    -Message 'Streamer startup must pass the hosted identity proof requirement to Wilbur.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS=3' `
    -Message 'Streamer startup must keep screenshot artifact metadata aligned with the three-day S3 lifecycle.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected '%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev' `
    -Message 'Streamer startup must derive the Dev instance-agent bootstrap secret path from deployment track.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected '/pixelstreaming/dev/instance-agent-bootstrap-shared-secret' `
    -Message 'Streamer startup must support the Dev-specific instance-agent bootstrap secret path.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected '/pixelstreaming/stage/instance-agent-bootstrap-shared-secret' `
    -Message 'Streamer startup must support the Stage-specific instance-agent bootstrap secret path.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF' `
    -Message 'Instance agent must read the hosted identity proof requirement.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'EC2 identity proof is required for instance-agent bootstrap' `
    -Message 'Instance agent must fail bootstrap when identity proof is required but unavailable.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'readInstanceAgentDesiredStateSnapshot(desiredStatePath, log)' `
    -Message 'Instance agent must preserve the cached desired state at startup until the control plane returns an authoritative state.'

Assert-DoesNotContainText `
    -Content $instanceAgent `
    -Unexpected 'writeInstanceAgentDesiredStateSnapshot(desiredStatePath, {}, log)' `
    -Message 'Instance agent startup must not clear desired-state recycle or warm-hold intent before bootstrap.'
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

Assert-ContainsText `
    -Content $repoSync `
    -Expected "Skipping git fetch" `
    -Message 'Pinned startup repo sync must skip fetch when local checkout and build artifacts already match the pinned ref.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected "git@github-pixelstreaming:" `
    -Message 'Repo sync must recognize the legacy SSH host alias that is unavailable to service-account startup.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected "remote set-url origin" `
    -Message 'Repo sync must normalize unusable service-account git remotes before fetching.'
Assert-ContainsText `
    -Content $repoSync `
    -Expected "repo_build_in_progress" `
    -Message 'Repo sync must publish a build-specific updating status for actual build work.'
Assert-ContainsText `
    -Content $repoSync `
    -Expected "repo_update_in_progress" `
    -Message 'Repo sync must publish an updating status when checkout/reset work is actually being applied.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected "Start-PostRepoSyncStackRelaunch" `
    -Message 'Repo sync must relaunch the mutable stack launcher after applying a new checkout.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected "STACK_ENABLE_BOOT_GIT_SYNC=false" `
    -Message 'Post-sync stack relaunch must disable boot git sync to avoid relaunch loops.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected 'set "WATCHDOG_RESTART_COMMAND=" && set "WATCHDOG_WILBUR_RESTART_COMMAND=" && set "WATCHDOG_UNREAL_RESTART_COMMAND="' `
    -Message 'Post-sync stack relaunch must clear root-bound watchdog restart commands before handing off to the updated checkout.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected "exit 42" `
    -Message 'Repo sync must use a distinct relaunch exit code for the parent batch.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '"!STACK_SYNC_EXIT!"=="42"' `
    -Message 'Stack launcher must treat post-sync relaunch as successful handoff.'


Assert-ContainsText `
    -Content $stackLauncher `
    -Expected '"%REPO_SYNC_EXIT%"=="42"' `
    -Message 'Repo sync subroutine must preserve the post-sync relaunch handoff exit code.'
Assert-ContainsText `
    -Content $startDevTurn `
    -Expected '"%REPO_SYNC_EXIT%"=="42"' `
    -Message 'Legacy Wilbur launcher must treat post-sync relaunch as successful handoff.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected '--instance_agent_screenshot_artifact_upload_enabled' `
    -Message 'Legacy Wilbur launcher must pass screenshot artifact upload settings to Wilbur.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED=%INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED%' `
    -Message 'Legacy Wilbur launcher must enable screenshot bundles when session artifact uploads are enabled.'
Write-Output 'Stack launcher policy tests passed.'
