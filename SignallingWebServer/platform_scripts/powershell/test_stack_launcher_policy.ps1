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

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-SelectedFunctionModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string[]]$FunctionNames
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Could not parse policy source: $($parseErrors[0].Message)"
    }

    $definitions = New-Object System.Collections.Generic.List[string]
    foreach ($functionName in $FunctionNames) {
        $definition = $ast.Find({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                [string]::Equals($node.Name, $functionName, [System.StringComparison]::OrdinalIgnoreCase)
        }, $true)
        if ($null -eq $definition) {
            throw "Could not find function '$functionName' in policy source."
        }

        $definitions.Add($definition.Extent.Text)
    }

    return New-Module -ScriptBlock ([scriptblock]::Create(($definitions -join "`r`n`r`n")))
}

$cmdRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\cmd')
$buildScriptsRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\BuildScripts')
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
$signallingServerPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\Signalling\src\SignallingServer.ts')
$repoSyncPath = Join-Path $PSScriptRoot 'ensure_repo_current.ps1'
$repoHeadPublisherPath = Join-Path $PSScriptRoot 'publish_repo_head_tags.ps1'
$deliveryModeResolverPath = Join-Path $PSScriptRoot 'resolve_pixelstreaming_delivery_mode_from_instance_tag.ps1'
$maintenanceModeResolverPath = Join-Path $PSScriptRoot 'resolve_maintenance_mode_from_instance_tag.ps1'
$serviceClassResolverPath = Join-Path $PSScriptRoot 'resolve_service_class_from_instance_tag.ps1'
$activeRuntimeIdentityPublisherPath = Join-Path $PSScriptRoot 'publish_active_runtime_identity_tags.ps1'
$runtimeInstallerPath = Join-Path $PSScriptRoot 'install_pixelstreaming_runtime.ps1'
$updateModePath = Join-Path $PSScriptRoot 'invoke_update_mode.ps1'
$unrealPrerequisiteModulePath = Join-Path $PSScriptRoot 'unreal_prerequisite.psm1'
$unrealPrerequisiteTestPath = Join-Path $PSScriptRoot 'test_unreal_prerequisite.ps1'
$provisioningModePath = Join-Path $PSScriptRoot 'invoke_provisioning_mode.ps1'
$stopSupersededRootPath = Join-Path $PSScriptRoot 'stop_superseded_root_processes.ps1'
$packageRuntimeArtifactPath = Join-Path $buildScriptsRoot 'package-runtime-artifact.ps1'
$prepareForBakePath = Join-Path $buildScriptsRoot 'prepare-for-ami-bake.ps1'
$prepareScaleWorldS4ForBakePath = Join-Path $buildScriptsRoot 'prepare-scaleworld-s4-for-ami-bake.bat'
$prepareScaleWorldS4ForBakeViaSsmPath = Join-Path $buildScriptsRoot 'prepare-scaleworld-s4-for-ami-bake-via-ssm.bat'
$prepareScaleWorldS4ForBakeViaSsmScriptPath = Join-Path $buildScriptsRoot 'prepare-scaleworld-s4-for-ami-bake-via-ssm.ps1'
$prepareScaleWorldD1ForBakeViaSsmPath = Join-Path $buildScriptsRoot 'prepare-scaleworld-d1-for-ami-bake-via-ssm.bat'
$prepareScaleWorldD1ForBakeViaSsmScriptPath = Join-Path $buildScriptsRoot 'prepare-scaleworld-d1-for-ami-bake-via-ssm.ps1'

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
$signallingServer = [System.IO.File]::ReadAllText($signallingServerPath)
$repoSync = [System.IO.File]::ReadAllText($repoSyncPath)
$repoHeadPublisher = [System.IO.File]::ReadAllText($repoHeadPublisherPath)
$deliveryModeResolver = [System.IO.File]::ReadAllText($deliveryModeResolverPath)
$maintenanceModeResolver = [System.IO.File]::ReadAllText($maintenanceModeResolverPath)
$serviceClassResolver = [System.IO.File]::ReadAllText($serviceClassResolverPath)
$activeRuntimeIdentityPublisher = [System.IO.File]::ReadAllText($activeRuntimeIdentityPublisherPath)
$runtimeInstaller = [System.IO.File]::ReadAllText($runtimeInstallerPath)
$updateMode = [System.IO.File]::ReadAllText($updateModePath)
$unrealPrerequisiteModule = [System.IO.File]::ReadAllText($unrealPrerequisiteModulePath)
$unrealPrerequisiteTest = [System.IO.File]::ReadAllText($unrealPrerequisiteTestPath)
$provisioningMode = [System.IO.File]::ReadAllText($provisioningModePath)
$stopSupersededRoot = [System.IO.File]::ReadAllText($stopSupersededRootPath)
$packageRuntimeArtifact = [System.IO.File]::ReadAllText($packageRuntimeArtifactPath)
$prepareForBake = [System.IO.File]::ReadAllText($prepareForBakePath)
$prepareScaleWorldS4ForBake = [System.IO.File]::ReadAllText($prepareScaleWorldS4ForBakePath)
$prepareScaleWorldS4ForBakeViaSsm = [System.IO.File]::ReadAllText($prepareScaleWorldS4ForBakeViaSsmPath)
$prepareScaleWorldS4ForBakeViaSsmScript = [System.IO.File]::ReadAllText($prepareScaleWorldS4ForBakeViaSsmScriptPath)
$prepareScaleWorldD1ForBakeViaSsm = [System.IO.File]::ReadAllText($prepareScaleWorldD1ForBakeViaSsmPath)
$prepareScaleWorldD1ForBakeViaSsmScript = [System.IO.File]::ReadAllText($prepareScaleWorldD1ForBakeViaSsmScriptPath)

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
    -Expected 'if not defined STACK_LAUNCH_UNREAL_BEFORE_WILBUR set "STACK_LAUNCH_UNREAL_BEFORE_WILBUR=false"' `
    -Message 'Stack launcher must wait for Wilbur readiness before starting Unreal while preserving the env override.'

$streamerConfigSendIndex = $signallingServer.IndexOf('newStreamer.sendMessage(message);')
$streamerRegistryAddIndex = $signallingServer.IndexOf('this.streamerRegistry.add(newStreamer);')
Assert-True `
    -Condition (
        $streamerConfigSendIndex -ge 0 -and
        $streamerConfigSendIndex -eq $signallingServer.LastIndexOf('newStreamer.sendMessage(message);') -and
        $streamerRegistryAddIndex -gt $streamerConfigSendIndex
    ) `
    -Message 'Streamer handshake must send exactly one config before registry add sends identify.'

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
    -Message 'Stage/Prod startup should preserve automatic artifact detection while retaining git-ref fallback for non-artifact roots.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "RUNTIME_BUNDLE_METADATA=%PIXELSTREAMING_ROOT%\runtime-bundle-metadata.json"' `
    -Message 'Stack launcher must detect runtime artifacts from metadata in the current launch root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'PixelStreaming runtime artifact metadata detected at "%RUNTIME_BUNDLE_METADATA%". Using the current launch root as the active runtime.' `
    -Message 'Artifact launch roots must identify themselves without delegating through another root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_RESTART_COMMAND=""%SCRIPT_DIR%start_streamer_stack.bat"" --recovery"' `
    -Message 'Artifact launch roots must bind watchdog stack recovery to the same launch root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_WILBUR_RESTART_COMMAND=""%SCRIPT_DIR%start_dev_turn.bat"""' `
    -Message 'Artifact launch roots must bind Wilbur recovery to the same launch root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_UNREAL_RESTART_COMMAND=""%SCRIPT_DIR%start_unreal.bat"""' `
    -Message 'Artifact launch roots must bind Unreal recovery to the same launch root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_STREAMER_HEALTH_PATH=%PIXELSTREAMING_ROOT%\SignallingWebServer\state\streamer-health.json"' `
    -Message 'Artifact launch roots must keep streamer health under the same launch root.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'del /f /q "%WATCHDOG_STREAMER_HEALTH_PATH%"' `
    -Message 'Artifact launch roots must remove stale baked streamer health snapshots before watchdog evaluates runtime freshness.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'publish_active_runtime_identity_tags.ps1' `
    -Message 'Artifact launch roots must publish runtime artifact identity from local metadata before Wilbur can publish fallback git-ref tags.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "STACK_ENABLE_BOOT_GIT_SYNC=false"' `
    -Message 'Artifact launch roots must disable boot-time git sync.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'PixelStreaming delivery mode runtime_artifact requires runtime metadata at "%RUNTIME_BUNDLE_METADATA%".' `
    -Message 'Explicit runtime-artifact mode must fail closed when the current launch root is not an installed artifact.'

Assert-DoesNotContainText `
    -Content $stackLauncher `
    -Unexpected 'STACK_ENABLE_ACTIVE_RUNTIME_DELEGATION' `
    -Message 'Stack launcher must not retain the split-root active runtime delegation switch.'

Assert-DoesNotContainText `
    -Content $stackLauncher `
    -Unexpected ':delegate_to_active_runtime_if_available' `
    -Message 'Stack launcher must not retain the split-root active runtime delegation label.'

Assert-DoesNotContainText `
    -Content $startDevTurn `
    -Unexpected ':delegate_to_active_runtime_wilbur_if_needed' `
    -Message 'Direct Wilbur launcher must not retain split-root runtime delegation.'

Assert-DoesNotContainText `
    -Content $startDevTurn `
    -Unexpected 'Delegating Wilbur startup to active PixelStreaming runtime' `
    -Message 'Direct Wilbur launcher must not hand off to a separate runtime root.'

Assert-ContainsText `
    -Content $startDevTurn `
    -Expected 'set "RUNTIME_BUNDLE_METADATA=%ROOT%\..\runtime-bundle-metadata.json"' `
    -Message 'Direct Wilbur launcher must be able to identify artifact launch roots from local metadata.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'stop_superseded_root_processes.ps1' `
    -Message 'Artifact launch roots must retire superseded stale-root supervisors before launching.'

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
    -Content $watchdog `
    -Expected '$script:SignallingWebServerRoot = (Resolve-Path (Join-Path $PSScriptRoot ''..\..'')).Path' `
    -Message 'Watchdog root must be the resolved string path, not a Resolve-Path PathInfo object.'

Assert-DoesNotContainText `
    -Content $watchdog `
    -Unexpected '$script:SignallingWebServerRoot = Resolve-Path (Join-Path $PSScriptRoot ''..\..'')' `
    -Message 'Watchdog root must not keep PathInfo because later path matching calls string methods.'

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
    -Expected 'PixelStreaming delivery mode runtime_artifact requires runtime metadata at "%RUNTIME_BUNDLE_METADATA%".' `
    -Message 'Explicit runtime-artifact mode must fail closed when the current launch root is not an installed artifact.'

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
    -Expected 'function Get-WilburCommandLinePatterns' `
    -Message 'Watchdog must normalize Wilbur command-line matching through a dedicated helper so runtime-artifact path aliases stay scoped.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '([string]$script:SignallingWebServerRoot).IndexOf(''\runtime-releases\''' `
    -Message 'Runtime-artifact watchdogs must accept their resolved runtime-release root when the configured Wilbur matcher uses the stable PixelStreaming launch path.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'CommandLinePatterns = Get-WilburCommandLinePatterns -Pattern $WilburCommandLinePattern' `
    -Message 'Wilbur process detection must accept only the configured active-runtime root and the current runtime-release root alias.'

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
    -Content $updateMode `
    -Expected 'function Test-RuntimeArtifactLaunchRoot' `
    -Message 'Update mode must detect installed runtime-artifact launch roots before deciding whether repo sync is valid.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected "Join-Path `$Root 'runtime-bundle-metadata.json'" `
    -Message 'Update mode must identify artifact launch roots from local runtime metadata, not from mutable git state.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected 'function Invoke-RepoSyncForMutableLaunchRoot' `
    -Message 'Update mode must centralize guarded repo sync so Unreal and combined updates cannot accidentally treat artifacts as git checkouts.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected 'Skipping PixelStreaming repo/bootstrap sync before $Context because launch root' `
    -Message 'Update mode must skip repo sync for runtime-artifact launch roots instead of failing on missing git/build-all files.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected "Reason = 'runtime_artifact_launch_root'" `
    -Message 'Update mode trace must record why repo sync was skipped for artifact-delivered launch roots.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected "-Context 'Unreal update'" `
    -Message 'Unreal update preparation must use the guarded repo-sync helper.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected "-Context 'Unreal activation'" `
    -Message 'Unreal activation must use the guarded repo-sync helper.'

Assert-DoesNotContainText `
    -Content $updateMode `
    -Unexpected "Preparing Unreal update payload for '`$zipFileName' in parallel with PixelStreaming repo sync." `
    -Message 'Update mode must not claim all Unreal preparation runs in parallel with repo sync because artifact roots skip git sync.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected 'function Invoke-UnrealPrerequisitePreflight' `
    -Message 'Update mode must centralize prerequisite validation and unattended installation before activation.'

foreach ($phase in @('checking_prerequisites', 'installing_prerequisites', 'verifying_prerequisites')) {
    Assert-ContainsText `
        -Content $updateMode `
        -Expected "-Phase '$phase'" `
        -Message "Update mode must publish the '$phase' prerequisite phase."
}

Assert-MatchesText `
    -Content $updateMode `
    -Pattern 'if \(\$hasRuntimePayload -and -not \$hasUnrealPayload\) \{.*?Invoke-UnrealPrerequisitePreflight.*?Installing PixelStreaming runtime artifact' `
    -Message 'Runtime-only updates must validate the current Unreal release before runtime activation.'

Assert-MatchesText `
    -Content $updateMode `
    -Pattern '\$unrealPrerequisiteRoot = if \(\$hasPreparedReleaseForTarget\).*?\$preparedReleasePath.*?elseif \(\$currentReleaseAlreadyMatchesTarget\).*?\$activeInstallPath.*?Invoke-UnrealPrerequisitePreflight.*?if \(\$hasRuntimePayload\)' `
    -Message 'Unreal and combined updates must check the prepared release, while same-build retries check the active release, before either payload is activated.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected "@('update_recovery_exhausted', 'watchdog_restart_failed')" `
    -Message 'Update validation must fail fast only for terminal watchdog reasons after recovery is exhausted or cannot launch.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected '$statusAtUtc -lt $ValidationStartedAtUtc' `
    -Message 'Terminal watchdog faults must be at least as new as the current validation start.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected '$code = "runtime_fault:$($streamerValidation.TerminalReason)"' `
    -Message 'Streamer validation must preserve the concrete fresh terminal watchdog reason in the update result code.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected 'Get-UpdateFailureResultReason -ErrorRecord $_ -Fallback $reason' `
    -Message 'Update failure publication must preserve stable prerequisite and validation machine codes.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected 'function Set-ProvisioningInstanceTags' `
    -Message 'Provisioning runtime identity tags must use a JSON tag payload helper instead of AWS CLI shorthand.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected '--tags ("file://{0}" -f $tagPayloadPath)' `
    -Message 'Provisioning runtime identity tags must pass JSON tag payload files so comma-delimited capability values remain strings.'

Assert-DoesNotContainText `
    -Content $provisioningMode `
    -Unexpected 'Key=$Key,Value=$normalizedValue' `
    -Message 'Provisioning must not use AWS CLI tag shorthand because comma-delimited values are parsed as lists.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected "ScaleWorldPixelStreamingUpdateCapabilities = 'pixelstreaming_runtime,combined_runtime_unreal'" `
    -Message 'Provisioning must still publish combined runtime capabilities as a single tag value.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected '-PassThru' `
    -Message 'Provisioning heartbeat startup must keep the child process handle for deterministic cleanup.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected 'Stop-Process -Id $heartbeatProcess.Id -Force' `
    -Message 'Provisioning heartbeat cleanup must force-stop stale heartbeat children that miss the stop file.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected 'Clear-ProvisioningUpdatePhaseTag' `
    -Message 'Provisioning bootstrap success must clear stale ScaleWorldUpdatePhase state.'

Assert-ContainsText `
    -Content $provisioningMode `
    -Expected "Remove-ProvisioningInstanceTags -AwsCli `$AwsCli -Region `$Region -InstanceId `$InstanceId -Keys @('ScaleWorldUpdatePhase')" `
    -Message 'Provisioning update phase cleanup must remove only the stale update phase tag.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Get-RuntimeBundleMetadata' `
    -Message 'AMI bake preparation must derive the bootstrap source commit from runtime bundle metadata.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'ExpectedInstanceName' `
    -Message 'AMI bake preparation must support an expected instance name guard for dedicated bake sources.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Assert-ExpectedInstanceName' `
    -Message 'AMI bake preparation must refuse to run on the wrong named source instance when requested.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'pixelStreamingRepoCommit' `
    -Message 'AMI bake preparation must read the runtime artifact source commit from bundle metadata.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Skipping bootstrap git sync because the runtime artifact is the launch root.' `
    -Message 'AMI bake preparation must not mutate git when the artifact is the launch root.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'function Test-RuntimeLaunchRoot' `
    -Message 'AMI bake preparation must verify artifact launch-root startup tooling before image capture.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'function Test-BootstrapProvisioningScript' `
    -Message 'AMI bake preparation must verify the bootstrap provisioning script before bake.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Key=$Key,Value=$normalizedValue' `
    -Message 'AMI bake preparation must explicitly reject the old provisioning AWS CLI tag shorthand.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Stop-StreamerStackProcesses' `
    -Message 'AMI bake preparation must stop streamer stack processes before image capture.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'runtime-updates' `
    -Message 'AMI bake preparation must clear runtime update caches before image capture.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'session-artifact-queue' `
    -Message 'AMI bake preparation must clear carried-over session artifact queues before image capture.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'runtime-entitlement-manifest.json' `
    -Message 'AMI bake preparation must clear the session-specific runtime entitlement projection before image capture.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Repair-SysprepBlockingEdgeAppx' `
    -Message 'AMI bake preparation must repair the known per-user Edge AppX state that prevents Windows generalization.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Set-StreamerStartupTaskPrincipalForImage' `
    -Message 'AMI bake preparation must rebind the streamer startup task to a machine-independent service principal before Sysprep.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected "-UserId 'SYSTEM'" `
    -Message 'AMI bake preparation must run the post-Sysprep streamer startup task as SYSTEM.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'Reset-InstanceAgentDesiredStateForBake' `
    -Message 'AMI bake preparation must reset desired state so stale source-instance commands are not baked.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected "policyVersion = 'bake-default'" `
    -Message 'AMI bake preparation must mark the neutral desired-state snapshot as bake-generated.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'SkipDesiredStateReset' `
    -Message 'AMI bake preparation must expose an explicit escape hatch for desired-state reset.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'UseScriptCheckoutCommit' `
    -Message 'AMI bake preparation must support using the script checkout commit for dedicated bake-source runners.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected 'function Test-BakePrepScripts' `
    -Message 'AMI bake preparation must keep legacy git-checkout bake tooling verification available for non-artifact roots.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected "The selected target commit does not contain the AMI bake tooling." `
    -Message 'AMI bake preparation must fail loudly when the target commit would remove the bake tooling.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBake `
    -Expected '-ExpectedInstanceName "ScaleWorld_s4"' `
    -Message 'ScaleWorld_s4 bake runner must explicitly target the stage source instance.'

Assert-DoesNotContainText `
    -Content $prepareScaleWorldS4ForBake `
    -Unexpected '-UseScriptCheckoutCommit' `
    -Message 'ScaleWorld_s4 bake runner must not assume the launch root is a git checkout.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBake `
    -Expected 'prepare-for-ami-bake.ps1' `
    -Message 'ScaleWorld_s4 bake runner must delegate to the generic AMI bake preparation script.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBakeViaSsm `
    -Expected 'prepare-scaleworld-s4-for-ami-bake-via-ssm.ps1' `
    -Message 'ScaleWorld_s4 workstation bake runner must delegate to the SSM wrapper script.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Expected "InstanceName = 'ScaleWorld_s4'" `
    -Message 'ScaleWorld_s4 SSM bake runner must target the dedicated stage bake source by default.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Expected 'AWS-RunPowerShellScript' `
    -Message 'ScaleWorld_s4 SSM bake runner must execute through AWS Systems Manager.'

Assert-DoesNotContainText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Unexpected 'Get-LocalScriptCheckoutInfo' `
    -Message 'ScaleWorld_s4 SSM bake runner must not derive a remote bootstrap sync target from the local checkout.'

Assert-DoesNotContainText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Unexpected 'checkout --force `$targetCommit' `
    -Message 'ScaleWorld_s4 SSM bake runner must not mutate the remote launch root with git.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Expected 'Artifact-mode bake prep no longer mutates' `
    -Message 'ScaleWorld_s4 SSM bake runner must fail clearly when the remote artifact lacks bake tooling.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Expected 'prepare-scaleworld-s4-for-ami-bake.bat' `
    -Message 'ScaleWorld_s4 SSM bake runner must execute the on-instance bake-prep batch.'

Assert-ContainsText `
    -Content $prepareScaleWorldS4ForBakeViaSsmScript `
    -Expected 'Type PREPARE to continue' `
    -Message 'ScaleWorld_s4 SSM bake runner must require an explicit local confirmation before remote cleanup.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsm `
    -Expected 'prepare-scaleworld-d1-for-ami-bake-via-ssm.ps1' `
    -Message 'ScaleWorld_d1 workstation shortcut must delegate to the dedicated PowerShell SSM runner.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected "`$instanceName = 'ScaleWorld_d1'" `
    -Message 'ScaleWorld_d1 SSM bake runner must be hard-bound to the dedicated Dev bake source.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected "`$expectedDeploymentTrack = 'dev'" `
    -Message 'ScaleWorld_d1 SSM bake runner must reject a non-Dev deployment track.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'prepare-for-ami-bake.ps1' `
    -Message 'ScaleWorld_d1 SSM bake runner must delegate to the generic on-instance bake preparation script.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected '-ExpectedInstanceName $expectedInstanceName' `
    -Message 'ScaleWorld_d1 SSM bake runner must preserve the remote instance-name guard.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'runtime-entitlement-manifest.json' `
    -Message 'ScaleWorld_d1 SSM bake runner must scrub session-specific entitlement state even when the installed generic prep predates that cleanup.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'AWS-RunPowerShellScript' `
    -Message 'ScaleWorld_d1 bake runner must execute remotely through AWS Systems Manager.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'Type SYSPREP to continue' `
    -Message 'ScaleWorld_d1 SSM bake runner must require explicit confirmation before cleanup and Sysprep shutdown.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'SYSPREP_LAUNCHING' `
    -Message 'ScaleWorld_d1 SSM bake runner must explicitly mark the point at which EC2Launch generalization begins.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected "sysprep ''--shutdown=true''" `
    -Message 'ScaleWorld_d1 SSM bake runner must use EC2Launch v2 Sysprep with shutdown.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'Wait-RemoteSysprepShutdown' `
    -Message 'ScaleWorld_d1 workstation runner must wait for the source instance to stop after Sysprep.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'nvidia-smi.exe' `
    -Message 'ScaleWorld_d1 SSM bake runner must validate the source GPU driver before generalization.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected 'Microsoft.MicrosoftEdge.Stable' `
    -Message 'ScaleWorld_d1 SSM bake runner must repair the known Edge AppX provisioning drift before Sysprep.'

Assert-ContainsText `
    -Content $prepareScaleWorldD1ForBakeViaSsmScript `
    -Expected "New-ScheduledTaskPrincipal -UserId ''SYSTEM'' -LogonType ServiceAccount" `
    -Message 'ScaleWorld_d1 SSM bake runner must make the streamer startup task survive Windows generalization.'

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
    -Content $packageRuntimeArtifact `
    -Expected 'Copy-RequiredFile -RelativePath "SWupdate.ps1" -DestinationRoot $stageRoot' `
    -Message 'Runtime artifacts must include root SWupdate.ps1 because artifact launch roots run Unreal update activation from the artifact root.'

Assert-ContainsText `
    -Content $packageRuntimeArtifact `
    -Expected 'Copy-RequiredFile -RelativePath "SignallingWebServer\platform_scripts\powershell\unreal_prerequisite.psm1" -DestinationRoot $stageRoot' `
    -Message 'Runtime artifact packaging must explicitly include the Unreal prerequisite helper.'

Assert-ContainsText `
    -Content $packageRuntimeArtifact `
    -Expected "'unreal-prerequisite-preflight-v1'" `
    -Message 'New runtime artifacts must declare the prerequisite-preflight capability that makes the helper mandatory.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected '"SWupdate.ps1"' `
    -Message 'Runtime artifact installer must reject bundles missing root SWupdate.ps1.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected '"SignallingWebServer\platform_scripts\powershell\unreal_prerequisite.psm1"' `
    -Message 'Runtime artifact installer must know the capability-gated Unreal prerequisite helper path.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected "if (@(`$ExpectedManifest.Capabilities) -contains 'unreal-prerequisite-preflight-v1') {" `
    -Message 'Runtime artifact installer must require the Unreal prerequisite helper only for manifests that declare its capability.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected 'capabilities = @($Manifest.Capabilities)' `
    -Message 'Runtime installer completion markers must preserve artifact capabilities for later self-consistency checks.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected "'SignallingWebServer\platform_scripts\powershell\unreal_prerequisite.psm1'" `
    -Message 'AMI bake preparation must know the capability-gated Unreal prerequisite helper path.'

Assert-ContainsText `
    -Content $prepareForBake `
    -Expected "if (`$capabilities -contains 'unreal-prerequisite-preflight-v1') {" `
    -Message 'AMI bake validation must require the helper for new prerequisite-aware artifacts while accepting legacy rollback artifacts.'

$runtimeInstallerPolicyModule = New-SelectedFunctionModule `
    -Content $runtimeInstaller `
    -FunctionNames @(
        'Normalize-Optional',
        'Get-NormalizedRuntimeCapabilities',
        'Read-RuntimeManifest',
        'Get-InstalledRuntimeMarkerPath',
        'Test-RequiredRuntimeFile',
        'Get-RequiredRuntimeFiles',
        'Test-InstalledRuntimeBundle'
    )
$runtimePolicyTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("scaleworld-runtime-policy-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $runtimePolicyTestRoot -Force | Out-Null
    $legacyManifest = [ordered]@{
        artifactType = 'pixelstreaming_runtime'
        bundleId = 'legacy-rollback'
        runtimeZipKey = 'runtime/legacy.zip'
        runtimeZipSha256 = ('a' * 64)
        capabilities = @('runtime-status-v1', 'instance-agent-bootstrap-v1')
    }
    $legacyExpectedManifest = [pscustomobject]@{
        BundleId = $legacyManifest.bundleId
        RuntimeZipKey = $legacyManifest.runtimeZipKey
        RuntimeZipSha256 = $legacyManifest.runtimeZipSha256
        Capabilities = @($legacyManifest.capabilities)
    }
    $legacyMarker = [ordered]@{
        schemaVersion = 1
        bundleId = $legacyManifest.bundleId
        runtimeZipKey = $legacyManifest.runtimeZipKey
        runtimeZipSha256 = $legacyManifest.runtimeZipSha256
        installedAtUtc = '2026-01-01T00:00:00.0000000Z'
    }
    $legacyManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runtimePolicyTestRoot 'manifest.json') -Encoding ASCII
    $legacyMarker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runtimePolicyTestRoot '.scaleworld-runtime-installed.json') -Encoding ASCII

    $legacyRequiredFiles = @(& $runtimeInstallerPolicyModule {
        param($Manifest)
        Get-RequiredRuntimeFiles -ExpectedManifest $Manifest
    } $legacyExpectedManifest)
    foreach ($relativePath in $legacyRequiredFiles) {
        $testFilePath = Join-Path $runtimePolicyTestRoot $relativePath
        $testFileDirectory = Split-Path -Parent $testFilePath
        New-Item -ItemType Directory -Path $testFileDirectory -Force | Out-Null
        Set-Content -LiteralPath $testFilePath -Value '' -Encoding ASCII
    }

    $legacyAccepted = & $runtimeInstallerPolicyModule {
        param($BundleRoot, $Manifest)
        Test-InstalledRuntimeBundle -BundleRoot $BundleRoot -ExpectedManifest $Manifest
    } $runtimePolicyTestRoot $legacyExpectedManifest
    Assert-True `
        -Condition $legacyAccepted `
        -Message 'A pre-change runtime artifact and completion marker must remain valid for rollback/redeployment without the new helper.'

    $prerequisiteAwareManifest = [ordered]@{}
    foreach ($entry in $legacyManifest.GetEnumerator()) {
        $prerequisiteAwareManifest[$entry.Key] = $entry.Value
    }
    $prerequisiteAwareManifest.capabilities = @($legacyManifest.capabilities) + 'unreal-prerequisite-preflight-v1'
    $prerequisiteAwareManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runtimePolicyTestRoot 'manifest.json') -Encoding ASCII
    $prerequisiteAwareExpectedManifest = [pscustomobject]@{
        BundleId = $prerequisiteAwareManifest.bundleId
        RuntimeZipKey = $prerequisiteAwareManifest.runtimeZipKey
        RuntimeZipSha256 = $prerequisiteAwareManifest.runtimeZipSha256
        Capabilities = @($prerequisiteAwareManifest.capabilities)
    }

    $newArtifactAcceptedWithoutHelper = & $runtimeInstallerPolicyModule {
        param($BundleRoot, $Manifest)
        Test-InstalledRuntimeBundle -BundleRoot $BundleRoot -ExpectedManifest $Manifest
    } $runtimePolicyTestRoot $prerequisiteAwareExpectedManifest
    Assert-True `
        -Condition (-not $newArtifactAcceptedWithoutHelper) `
        -Message 'A prerequisite-aware artifact must fail validation when its declared helper is missing.'

    $helperPath = Join-Path $runtimePolicyTestRoot 'SignallingWebServer\platform_scripts\powershell\unreal_prerequisite.psm1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $helperPath) -Force | Out-Null
    Set-Content -LiteralPath $helperPath -Value '' -Encoding ASCII
    $newArtifactAcceptedWithHelper = & $runtimeInstallerPolicyModule {
        param($BundleRoot, $Manifest)
        Test-InstalledRuntimeBundle -BundleRoot $BundleRoot -ExpectedManifest $Manifest
    } $runtimePolicyTestRoot $prerequisiteAwareExpectedManifest
    Assert-True `
        -Condition $newArtifactAcceptedWithHelper `
        -Message 'A prerequisite-aware artifact must pass validation after its declared helper is present.'
} finally {
    if ($null -ne $runtimeInstallerPolicyModule) {
        Remove-Module $runtimeInstallerPolicyModule.Name -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $runtimePolicyTestRoot -PathType Container) {
        $resolvedPolicyTestRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $runtimePolicyTestRoot).ProviderPath)
        $expectedTempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\scaleworld-runtime-policy-'
        if ($resolvedPolicyTestRoot.StartsWith($expectedTempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedPolicyTestRoot -Recurse -Force
        }
    }
}

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected "SourceRef = Normalize-Optional (`$manifest.sourceRef -as [string])" `
    -Message 'Runtime artifact installer must preserve the source ref in installed runtime identity metadata.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected 'function Prune-InactiveRuntimeArtifacts' `
    -Message 'Runtime artifact installer must prune inactive runtime releases after successful activation.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected 'Get-LiveRuntimeReleaseRoots' `
    -Message 'Runtime artifact pruning must protect release roots still referenced by live processes.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected "Clear-DirectoryChildrenBestEffort -Path `$ScratchRoot" `
    -Message 'Runtime artifact installer must clear runtime update cache after successful activation.'

Assert-ContainsText `
    -Content $runtimeInstaller `
    -Expected "Write-Warning `"Skipping external runtime staging cleanup for '`$StagingParentRoot'.`"" `
    -Message 'Runtime artifact pruning must not blindly clear external staging roots.'

Assert-MatchesText `
    -Content $runtimeInstaller `
    -Pattern 'if \(\$Activate\) \{.*?Set-ActiveRuntimePointer.*?Prune-InactiveRuntimeArtifacts' `
    -Message 'Runtime artifact pruning must only run after active runtime activation.'

Assert-DoesNotContainText `
    -Content $provisioningMode `
    -Unexpected "syncing_bootstrap_to_runtime_artifact" `
    -Message 'Provisioning artifact install must not publish a bootstrap-sync phase.'

Assert-DoesNotContainText `
    -Content $provisioningMode `
    -Unexpected "Continuing with general origin fetch before checking out the artifact commit." `
    -Message 'Provisioning must not fetch artifact source refs for bootstrap alignment.'

Assert-DoesNotContainText `
    -Content $provisioningMode `
    -Unexpected 'Invoke-BootstrapCheckoutAlignment' `
    -Message 'Provisioning must not align the launch root to the runtime artifact source commit.'

Assert-DoesNotContainText `
    -Content $updateMode `
    -Unexpected "`$installedSourceCommit = if (-not [string]::IsNullOrWhiteSpace(`$targetRuntimeSourceCommit))" `
    -Message 'Update mode bootstrap alignment must use the installed artifact manifest commit, not a potentially stale EC2 target source tag.'

Assert-ContainsText `
    -Content $updateMode `
    -Expected "Stopping existing streamer stack before PixelStreaming runtime activation." `
    -Message 'Update mode must stop any old stack before activating and pruning runtime releases.'

Assert-DoesNotContainText `
    -Content $updateMode `
    -Unexpected "Set-UpdatePhase -AwsCli `$awsCli -Region `$identity.Region -InstanceId `$identity.InstanceId -Phase 'syncing_bootstrap'" `
    -Message 'Update mode must not expose a bootstrap sync phase for artifact updates.'

Assert-DoesNotContainText `
    -Content $updateMode `
    -Unexpected 'Invoke-BootstrapCheckoutAlignment' `
    -Message 'Update mode must not align the launch root to the installed runtime artifact source commit.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected '[switch]$PublishGitRefDeliveryIdentity' `
    -Message 'Repo-head publishing must require an explicit opt-in before it can publish git-ref delivery identity.'

Assert-MatchesText `
    -Content $repoHeadPublisher `
    -Pattern 'if \(-not \$PublishGitRefDeliveryIdentity\) \{.*?without changing PixelStreaming delivery identity.*?exit 0.*?\}\s*\$currentDeliveryMode = Get-InstanceTagValue' `
    -Message 'Repo-head publishing must publish repo telemetry only by default before reading or changing delivery identity.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected '$publishGitRefDeliveryIdentity = Test-ExplicitGitRefDeliveryMode -Value $PixelStreamingDeliveryMode' `
    -Message 'Repo sync must derive git-ref identity publishing from the explicit PixelStreaming delivery mode.'

Assert-ContainsText `
    -Content $repoSync `
    -Expected "`$publishArguments += '-PublishGitRefDeliveryIdentity'" `
    -Message 'Repo sync must opt in to git-ref delivery identity publishing only when explicitly allowed.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "Key = 'ScaleWorldPixelStreamingDeliveryMode'" `
    -Message 'Explicit git-ref startup must publish its delivery mode for Fleet status.'

Assert-ContainsText `
    -Content $repoHeadPublisher `
    -Expected "'ScaleWorldPixelStreamingRuntimeBundleId'" `
    -Message 'Explicit git-ref startup must clear stale runtime artifact identity tags.'

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
    -Content $activeRuntimeIdentityPublisher `
    -Expected 'runtime-bundle-metadata.json' `
    -Message 'Active runtime identity publishing must read the immutable runtime bundle metadata from the installed runtime root.'

Assert-ContainsText `
    -Content $activeRuntimeIdentityPublisher `
    -Expected 'ScaleWorldPixelStreamingDeliveryMode' `
    -Message 'Active runtime identity publishing must stamp runtime_artifact delivery mode for fleet display and future launches.'

Assert-ContainsText `
    -Content $activeRuntimeIdentityPublisher `
    -Expected 'ScaleWorldPixelStreamingRuntimeBundleId' `
    -Message 'Active runtime identity publishing must stamp the runtime bundle id.'

Assert-ContainsText `
    -Content $activeRuntimeIdentityPublisher `
    -Expected 'ScaleWorldPixelStreamingRuntimeManifestKey' `
    -Message 'Active runtime identity publishing must stamp the runtime manifest key.'

Assert-DoesNotContainText `
    -Content $activeRuntimeIdentityPublisher `
    -Unexpected 'ScaleWorldLastUpdatedAtUtc' `
    -Message 'Active runtime identity publishing must not rewrite the generic updated timestamp on every startup.'

Assert-ContainsText `
    -Content $deliveryModeResolver `
    -Expected "ScaleWorldPixelStreamingRuntimeBundleId" `
    -Message 'Delivery-mode resolution must infer runtime-artifact mode from existing runtime identity tags when the mode tag is absent.'

Assert-ContainsText `
    -Content $maintenanceModeResolver `
    -Expected 'ScaleWorldMaintenanceMode' `
    -Message 'Maintenance-mode resolution must read the EC2 maintenance tag that owns provisioning state.'

Assert-ContainsText `
    -Content $serviceClassResolver `
    -Expected 'ScaleWorldServiceClass' `
    -Message 'Service-class resolution must read the dedicated EC2 instance tag.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'call :apply_unreal_service_class_startup_args' `
    -Message 'Stack startup must apply service-class-specific Unreal settings.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS' `
    -Message 'Premium Unreal scalability arguments must remain configurable without changing the shared runtime artifact.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG=-ScaleWorldPremium"' `
    -Message 'Premium startup must expose the stable Unreal-readable premium command-line marker.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "SCALEWORLD_STANDARD_ENCODER_CODEC=vp9"' `
    -Message 'Standard startup must retain VP9 as its configurable codec default.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "SCALEWORLD_PREMIUM_ENCODER_CODEC=AV1"' `
    -Message 'Premium startup must use AV1 as its configurable codec default.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'SCALEWORLD_UNREAL_STARTUP_ARGS:%SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG%=' `
    -Message 'Stack recovery must remove an inherited premium marker before re-evaluating the current service-class tag.'

Assert-MatchesText `
    -Content $stackLauncher `
    -Pattern 'if /i "!RESOLVED_SERVICE_CLASS!"=="premium" \(.+!SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG!.+set "SCALEWORLD_DEFAULT_ENCODER_CODEC=!SCALEWORLD_PREMIUM_ENCODER_CODEC!".+\) else \(.+set "SCALEWORLD_DEFAULT_ENCODER_CODEC=!SCALEWORLD_STANDARD_ENCODER_CODEC!"' `
    -Message 'Premium must receive the Unreal marker and premium codec default while Standard receives the standard codec default.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'call :apply_unreal_provisioning_startup_args' `
    -Message 'Stack startup must apply Unreal provisioning warmup arguments after the provisioning bootstrap check.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'if /i "!RESOLVED_MAINTENANCE_MODE!"=="provisioning"' `
    -Message 'Unreal provisioning warmup must be gated by the current maintenance tag, not by the provisioning feature switch.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG=-RunProvisioningPSOWarmup"' `
    -Message 'Stack startup must expose the exact Unreal startup flag used by the Blueprint warmup sequence.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'SCALEWORLD_UNREAL_STARTUP_ARGS:%SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG%=' `
    -Message 'Stack recovery must remove stale inherited provisioning warmup args before re-evaluating the maintenance tag.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'set "WATCHDOG_UNREAL_RESTART_COMMAND=%WATCHDOG_RESTART_COMMAND%"' `
    -Message 'Provisioning Unreal-only watchdog recovery must route through stack recovery so the maintenance tag is re-evaluated.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'call "%SCRIPT_DIR%start_unreal.bat" %SCALEWORLD_UNREAL_STARTUP_ARGS%' `
    -Message 'Stack startup must pass computed Unreal startup arguments to the direct Unreal launcher.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected '[int]$MaxBitrateKbps = $(if ($env:SCALEWORLD_PIXEL_STREAMING_MAX_BITRATE_KBPS) { [int]$env:SCALEWORLD_PIXEL_STREAMING_MAX_BITRATE_KBPS } else { 30000 })' `
    -Message 'Unreal startup must default Pixel Streaming WebRTC max bitrate to 30000 kbps while retaining an environment override.'

Assert-MatchesText `
    -Content $unrealLauncher `
    -Pattern 'if \(\$env:SCALEWORLD_ENCODER_CODEC\).+elseif \(\$env:SCALEWORLD_DEFAULT_ENCODER_CODEC\).+''vp9''' `
    -Message 'Unreal startup must prefer an explicit codec override, then the service-class default, and finally VP9.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected '"-PixelStreamingEncoderCodec=$EncoderCodec"' `
    -Message 'Unreal startup must pass the resolved active encoder codec to Pixel Streaming.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected '"-ScaleWorldEntitlementManifest=`"$RuntimeEntitlementManifestPath`""' `
    -Message 'Unreal startup must expose the stable runtime entitlement manifest path.'

Assert-ContainsText `
    -Content $stackLauncher `
    -Expected 'SCALEWORLD_RUNTIME_ENTITLEMENT_MANIFEST_PATH=C:\ProgramData\ScaleWorld\runtime-entitlement-manifest.json' `
    -Message 'Stack startup must share one stable runtime entitlement manifest path with Wilbur and Unreal.'

Assert-ContainsText `
    -Content $unrealLauncher `
    -Expected '"-PixelStreaming2.WebRTC.MaxBitrate=$maxBitrateBps"' `
    -Message 'Unreal startup must pass the configured WebRTC max bitrate to Pixel Streaming 2.'

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

Assert-MatchesText `
    -Content $unrealLauncher `
    -Pattern 'Assert-ScaleWorldUnrealPrerequisite.*?Start-Process -FilePath \$processPath' `
    -Message 'Normal Unreal startup must run its check-only prerequisite guard before launching the bootstrap executable.'

Assert-DoesNotContainText `
    -Content $unrealLauncher `
    -Unexpected 'Install-ScaleWorldUnrealPrerequisite' `
    -Message 'Normal serving startup must never install prerequisites or request a reboot.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "`$script:BundledVcRedistRelativePath = 'Engine\Extras\Redist\en-us\vc_redist.x64.exe'" `
    -Message 'The prerequisite requirement must be derived from the exact redistributable bundled with the Unreal release.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected 'Get-AuthenticodeSignature -FilePath $InstallerPath' `
    -Message 'The bundled redistributable must have a valid Authenticode signature before execution.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "[string]::Equals(`$signer, 'Microsoft Corporation'" `
    -Message 'The bundled redistributable signer must be Microsoft Corporation.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "@('/install', '/quiet', '/norestart')" `
    -Message 'Prerequisite installation must be unattended and must not reboot an instance.'

Assert-MatchesText `
    -Content $unrealPrerequisiteModule `
    -Pattern 'if \(-not \(Test-ScaleWorldProcessElevated\)\).*?unreal_prerequisite_elevation_required.*?\$exitCode = \$null' `
    -Message 'A non-elevated update must fail before the installer can open an interactive UAC prompt.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "'Global\ScaleWorldUnrealPrerequisiteInstall'" `
    -Message 'Concurrent update invocations must serialize Visual C++ installation through a machine-wide mutex.'

foreach ($code in @(
    'unreal_prerequisite_64bit_powershell_required',
    'unreal_prerequisite_elevation_required',
    'unreal_prerequisite_install_busy',
    'unreal_prerequisite_install_timeout',
    'unreal_prerequisite_reboot_required',
    'unreal_prerequisite_installer_initiated_reboot',
    'unreal_prerequisite_install_failed',
    'unreal_prerequisite_verification_failed'
)) {
    Assert-ContainsText `
        -Content $unrealPrerequisiteModule `
        -Expected $code `
        -Message "The prerequisite helper must preserve stable failure code '$code'."
}

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected 'SCALEWORLD_UNREAL_PREREQUISITE_INSTALL_TIMEOUT_SECONDS' `
    -Message 'The prerequisite installer deadline must be configurable for fleet update environments.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected 'WaitForExit($TimeoutMilliseconds)' `
    -Message 'The signed prerequisite installer must use a bounded process wait.'

Assert-DoesNotContainText `
    -Content $unrealPrerequisiteModule `
    -Unexpected 'Stop-Process' `
    -Message 'Prerequisite timeout handling must not terminate an active vendor or Windows Installer process.'

Assert-ContainsText `
    -Content $unrealPrerequisiteTest `
    -Expected 'A timed-out VC++ bootstrap from a different artifact path must block a duplicate installer launch.' `
    -Message 'Focused prerequisite tests must cover cross-artifact-path installer overlap prevention.'

Assert-MatchesText `
    -Content $unrealPrerequisiteModule `
    -Pattern 'Get-ScaleWorldRuntimeDllVersionFromVersionInfo.*?FileVersion' `
    -Message 'Runtime DLL acceptance must use the fixed FileVersion read by Unreal bootstrap.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected 'AppLocalSatisfied = $appLocalSatisfied' `
    -Message 'Prerequisite verification must mirror Unreal bootstrap support for current app-local runtime DLLs without registry state.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'" `
    -Message 'The system prerequisite route must verify the x64 Visual C++ registry runtime.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "Get-ScaleWorldSystemRuntimeDllObservation -FileName 'msvcp140_2.dll'" `
    -Message 'The system prerequisite route must verify msvcp140_2.dll.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected "Get-ScaleWorldSystemRuntimeDllObservation -FileName 'vcruntime140_1.dll'" `
    -Message 'The system prerequisite route must verify vcruntime140_1.dll.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected '$loadLibrarySearchDllLoadDir -bor $loadLibrarySearchSystem32' `
    -Message 'DLL loadability probes must use only the DLL directory and System32 dependency search locations.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected '-Msvcp1402Loadable $msvcp1402.Loadable' `
    -Message 'Version-current System32 DLLs must also pass a real loadability check.'

Assert-ContainsText `
    -Content $unrealPrerequisiteModule `
    -Expected '-AppLocalMsvcp1402Loadable $appLocalMsvcp1402.Loadable' `
    -Message 'Version-current app-local DLLs must also pass a real loadability check.'

Assert-DoesNotContainText `
    -Content $unrealPrerequisiteModule `
    -Unexpected "GetValue('Version'" `
    -Message 'The x64 runtime registry check must use Unreal''s numeric Major/Minor/Bld/Rbld values rather than the display Version string.'

Assert-ContainsText `
    -Content $unrealPrerequisiteTest `
    -Expected 'Current app-local DLLs beside the packaged target must satisfy the Unreal bootstrap contract without registry state.' `
    -Message 'Focused prerequisite tests must cover Unreal bootstrap app-local DLL behavior.'

Assert-ContainsText `
    -Content $unrealPrerequisiteTest `
    -Expected 'A current but unloadable runtime DLL must not satisfy the Unreal bootstrap contract.' `
    -Message 'Focused prerequisite tests must reject version-current but unloadable DLLs.'

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
    -Expected 'Provisioning connect timeout is a control-plane readiness deadline, not a' `
    -Message 'Provisioning watchdog streamer-health grace must not be capped by the external connect timeout.'

Assert-MatchesText `
    -Content $watchdog `
    -Pattern 'if \(\$isProvisioningMaintenance\) \{.*?\$effectiveStreamerHealthStartupGraceSeconds = \[Math\]::Max\(.*?\$provisioningStreamerHealthStartupGraceSecondsValue.*?\)\s*\} elseif \(\$isUpdateMaintenance\)' `
    -Message 'Provisioning watchdog streamer-health grace must honor the provisioning startup grace before update-mode timeout capping.'

Assert-ContainsText `
    -Content $startWatchdog `
    -Expected 'WATCHDOG_PROVISIONING_ASSET_WARMUP_STALL_GRACE_SECONDS=1800' `
    -Message 'Provisioning asset warmup stall recovery must default to a conservative 30 minute guard.'

Assert-ContainsText `
    -Content $startWatchdog `
    -Expected 'WATCHDOG_PROVISIONING_ASSET_WARMUP_STALL_CPU_CONFIRM_SECONDS=120' `
    -Message 'Provisioning asset warmup stall recovery must require an extended Unreal CPU stall confirmation.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$provisioningAssetWarmupStallProbeActive =' `
    -Message 'Watchdog must keep the provisioning warmup stall guard separate from normal streamer health startup grace.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$streamerHealthSnapshotStatus.Equals(''warming_up_assets''' `
    -Message 'Early provisioning warmup recovery must only apply to explicit asset warmup status.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$streamerHealthSnapshotReason.Equals(''initial_unreal_asset_warmup''' `
    -Message 'Early provisioning warmup recovery must only apply to the initial Unreal asset warmup reason.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$unrealCpuStallAccumulatedSeconds -ge $provisioningAssetWarmupStallCpuConfirmSecondsValue' `
    -Message 'Early provisioning warmup recovery must require the extended CPU-stall confirmation window.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected '$unrealCpuStallConfirmEnabledValue -and
                        $provisioningAssetWarmupAgeSeconds -ge $provisioningAssetWarmupStallGraceSecondsValue' `
    -Message 'Early provisioning warmup recovery must be disabled when CPU stall confirmation is disabled.'

Assert-DoesNotContainText `
    -Content $watchdog `
    -Unexpected '-not $unrealCpuStallConfirmEnabledValue -or
                        $isProvisioningAssetWarmupEarlyRecovery' `
    -Message 'Early provisioning warmup recovery must not trigger merely because CPU stall confirmation is disabled.'

Assert-DoesNotContainText `
    -Content $watchdog `
    -Unexpected '$provisioningStreamerConnectTimeoutSecondsValue
            )' `
    -Message 'Provisioning streamer-health startup grace must not be min-capped by ProvisioningStreamerConnectTimeoutSeconds.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'awaiting CPU stall confirmation or' `
    -Message 'Watchdog must preserve CPU stall confirmation while bounding indefinite unhealthy streamer states.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected 'streamer_health_file_stale' `
    -Message 'Watchdog must treat stale streamer health as a hard health fault.'

Assert-ContainsText `
    -Content $watchdog `
    -Expected "'streamer health file stale ({0:N0}s)' -f `$healthAgeSeconds" `
    -Message 'Watchdog must include the stale streamer-health age in fault logs.'

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
    -Content $stackRecycleScript `
    -Expected "`$marker.phase = 'replacement_started'" `
    -Message 'Stack recycle must durably distinguish pre-launch intent from replacement-started proof.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected '[System.IO.File]::Replace($temporaryPath, $resolvedMarkerPath, $backupPath)' `
    -Message 'Stack recycle marker replacement must supply a valid backup path for Windows PowerShell 5.1.'

Assert-DoesNotContainText `
    -Content $stackRecycleScript `
    -Unexpected '[System.IO.File]::Replace($temporaryPath, $resolvedMarkerPath, $null)' `
    -Message 'Stack recycle must not pass a null backup path to File.Replace on Windows PowerShell 5.1.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue' `
    -Message 'Stack recycle must clean up the replacement backup without blocking launch after durable read-back succeeds.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'Suppressing reset_completed because commercial recovery is still durable-blocked' `
    -Message 'Instance agent must not emit reset completion from a Ready edge while only pre-launch intent or otherwise unproven commercial recovery remains.'

$wilburAbsenceProofIndex = $stackRecycleScript.IndexOf("if (-not (Wait-ForProcessAbsence -Label 'wilbur'")
$unrealAbsenceProofIndex = $stackRecycleScript.IndexOf('if (-not (Wait-ForUnrealAbsence')
$replacementProofIndex = $stackRecycleScript.IndexOf(
    '$stackRestartStartedAtUtc = Set-RecycleMarkerReplacementStarted'
)
$replacementLaunchIndex = $stackRecycleScript.IndexOf(
    "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('`"{0}`" --recovery'"
)
Assert-True `
    -Condition (
        $wilburAbsenceProofIndex -ge 0 -and
        $unrealAbsenceProofIndex -gt $wilburAbsenceProofIndex -and
        $replacementProofIndex -gt $unrealAbsenceProofIndex -and
        $replacementLaunchIndex -gt $replacementProofIndex
    ) `
    -Message 'Replacement-started proof must be persisted only after old Wilbur and Unreal are absent and before the replacement stack launches.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected '-ExpectedSourcePid $sourcePidToStop' `
    -Message 'Replacement proof must remain bound to the exact source Wilbur process that the helper stopped.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'recoveredRecycleTokenAtStartup' `
    -Message 'Viewer idle stop must remember recycle tokens recovered with a recycle marker.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'recoveredRecycleMarkerAtStartup?.recycleRequestedToken ?? null' `
    -Message 'A tokenless passive marker must never adopt a newer desired-state recycle token.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'isRecoveredRecycleTokenStillInProgress' `
    -Message 'Viewer idle stop must scope recovered recycle suppression to the live recycle marker.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'recycleTokensMatch(token, recoveredRecycleTokenAtStartup) && hasRecycleLaunchMarker()' `
    -Message 'Viewer idle stop must only suppress a recovered recycle token while its recycle marker still exists.'

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
    -Expected 'only a new token may launch another stack recycle' `
    -Message 'Viewer idle stop must durably suppress a completed recycle token after its transient marker clears.'

Assert-DoesNotContainText `
    -Content $viewerIdleStop `
    -Unexpected 'is active again after its recycle marker cleared' `
    -Message 'Viewer idle stop must never re-arm the same completed recycle token merely because its transient marker cleared.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'recycleRequestedToken,' `
    -Message 'Recycle intent markers must retain the triggering token across process replacement.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'getRecycleTokenCompletionStatus' `
    -Message 'Desired-state and command recycle paths must consult the durable completed-token fence.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'Recovered legacy tokenless recycle marker' `
    -Message 'Replacement recovery must explicitly detect legacy tokenless markers.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'ensureCompletedRecycleMarkerEventQueued' `
    -Message 'A retained recycle marker must reconstruct reset completion until control-plane acknowledgement.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'responseRecycleToken === acceptedRecycleToken' `
    -Message 'An accepted tokenful reset completion must remain pending while desired state still advertises the same recycle token.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'if (acceptedResetCompletion && !resetCompletionStillNeedsControlReconciliation)' `
    -Message 'A durable recycle marker may clear only after event acceptance and exact-token desired-state reconciliation.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'shouldRetryPendingReadyRecycleCompletion' `
    -Message 'An identical Ready heartbeat must retry pending completion-marker durability after commercial recovery was already released.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'options.connectTicketRuntimeGate?.isCommercialRecoveryRequired() !== true' `
    -Message 'Ready heartbeat retry bypass must remain limited to a pending marker whose commercial recovery fence is already complete.'

$runTickIndex = $instanceAgent.IndexOf('const runTick = async (): Promise<void> =>')
$firstResetCompletionFlushIndex = if ($runTickIndex -ge 0) {
    $instanceAgent.IndexOf('await flushEvents();', $runTickIndex)
} else {
    -1
}
$readyHeartbeatIndex = if ($firstResetCompletionFlushIndex -ge 0) {
    $instanceAgent.IndexOf('await sendHeartbeat();', $firstResetCompletionFlushIndex)
} else {
    -1
}
$resetCompletionReplayIndex = if ($readyHeartbeatIndex -ge 0) {
    $instanceAgent.IndexOf('ensureCompletedRecycleMarkerEventQueued();', $readyHeartbeatIndex)
} else {
    -1
}
$replayedResetCompletionFlushIndex = if ($resetCompletionReplayIndex -ge 0) {
    $instanceAgent.IndexOf('await flushEvents();', $resetCompletionReplayIndex)
} else {
    -1
}
Assert-True `
    -Condition (
        $runTickIndex -ge 0 -and
        $firstResetCompletionFlushIndex -gt $runTickIndex -and
        $readyHeartbeatIndex -gt $firstResetCompletionFlushIndex -and
        $resetCompletionReplayIndex -gt $readyHeartbeatIndex -and
        $replayedResetCompletionFlushIndex -gt $resetCompletionReplayIndex
    ) `
    -Message 'Reset completion reconciliation must upload once, send Ready, replay stable evidence, and upload again in that order.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'resetCompletedAtUtc' `
    -Message 'Reset-completion replay must retain a stable durable occurrence timestamp.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'only the marker-owned token may complete it' `
    -Message 'A completed marker must not terminalize a newer active recycle command.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'recoveredRecycleMarker.schemaVersion === 1' `
    -Message 'Only legacy tokenless markers require the migration fail-closed guard.'

Assert-ContainsText `
    -Content $instanceAgent `
    -Expected 'ownership cannot be proven' `
    -Message 'A legacy tokenless marker must fail closed rather than adopt a newer destructive token.'

Assert-ContainsText `
    -Content $stackRecycleScript `
    -Expected 'schemaVersion -ne 1 -and [int]$marker.schemaVersion -ne 2' `
    -Message 'The recycle helper must accept legacy marker schema 1 and current marker schema 2 during migration.'

$atomicRecycleCompletionIndex = $connectTicketRuntimeState.IndexOf(
    'completeCommercialRecoveryAfterReset(recycleRequestedToken?'
)
$completedRecycleTokenWriteIndex = if ($atomicRecycleCompletionIndex -ge 0) {
    $connectTicketRuntimeState.IndexOf(
        'completedRecycleTokens: normalizedRecycleToken',
        $atomicRecycleCompletionIndex
    )
} else {
    -1
}
$atomicRecycleStateWriteIndex = if ($completedRecycleTokenWriteIndex -ge 0) {
    $connectTicketRuntimeState.IndexOf(
        'writeRuntimeStateSnapshot(statePath, completedSnapshot',
        $completedRecycleTokenWriteIndex
    )
} else {
    -1
}
Assert-True `
    -Condition (
        $atomicRecycleCompletionIndex -ge 0 -and
        $completedRecycleTokenWriteIndex -gt $atomicRecycleCompletionIndex -and
        $atomicRecycleStateWriteIndex -gt $completedRecycleTokenWriteIndex
    ) `
    -Message 'Completed recycle token fencing and commercial admission release must share one atomic durable state write.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'recycleLaunchInFlight = true' `
    -Message 'Stack recycle launch must acquire an in-process mutex before awaiting command transition.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'launchedRecycleMarker.recycleRequestedToken' `
    -Message 'A launched recycle may start only the command token owned by its durable marker.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'const commandToFail = commandToStart' `
    -Message 'A recycle launch failure must report against the command captured before launch, never a newer command.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected "scheduleStackRecycleRetry('replacement_recycle_in_progress')" `
    -Message 'A new recycle token must remain pending while an earlier replacement marker is active.'

Assert-ContainsText `
    -Content $viewerIdleStop `
    -Expected 'const COMMERCIAL_RECYCLE_LAUNCH_MAX_ATTEMPTS = 3' `
    -Message 'Commercial recycle launch failure escalation must remain explicitly bounded.'

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
