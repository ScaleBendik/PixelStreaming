@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..\..") do set "PIXELSTREAMING_ROOT=%%~fI"
if not defined SCALEWORLD_INSTALL_BASE set "SCALEWORLD_INSTALL_BASE=C:\PixelStreaming"
for %%I in ("%SCRIPT_DIR%\..\..") do set "STACK_SIGNALLING_ROOT=%%~fI"
set "STACK_LEASE_SCRIPT=%SCRIPT_DIR%..\powershell\invoke_stack_launch_lease.ps1"
set "STACK_LEASE_MODE=normal"
if /i "%~1"=="--recovery" set "STACK_LEASE_MODE=recovery"
if /i "%~1"=="--validation" set "STACK_LEASE_MODE=validation"
set "STACK_LEASE_RECEIPT=%TEMP%\scaleworld-stack-launch-%RANDOM%-%RANDOM%-%RANDOM%.env"
rem Register before deleting health or changing metadata/config. A Task
rem Scheduler retry of a cancelled producer must not disturb its replacement.
powershell -NoProfile -ExecutionPolicy Bypass -File "%STACK_LEASE_SCRIPT%" -Mode Enter -RepoRoot "%STACK_SIGNALLING_ROOT%" -InstallBase "%SCALEWORLD_INSTALL_BASE%" -LaunchMode "%STACK_LEASE_MODE%" -OutputFile "%STACK_LEASE_RECEIPT%"
set "STACK_LEASE_EXIT=%errorlevel%"
if "%STACK_LEASE_EXIT%"=="10" (
  if exist "%STACK_LEASE_RECEIPT%" del /f /q "%STACK_LEASE_RECEIPT%" >nul 2>nul
  echo Stack launch is already owned by a live or completed attempt. Skipping duplicate entry.
  exit /b 0
)
if not "%STACK_LEASE_EXIT%"=="0" exit /b 1
if not exist "%STACK_LEASE_RECEIPT%" exit /b 1
for /f "usebackq delims=" %%L in ("%STACK_LEASE_RECEIPT%") do %%L
del /f /q "%STACK_LEASE_RECEIPT%" >nul 2>nul
set "SCALEWORLD_STACK_LAUNCH_GRANT="
if not defined SCALEWORLD_STACK_LAUNCH_GENERATION exit /b 1
set "RUNTIME_BUNDLE_METADATA=%PIXELSTREAMING_ROOT%\runtime-bundle-metadata.json"
set "UPDATE_SCRIPT=%PIXELSTREAMING_ROOT%\SWupdate.ps1"
set "DATA_DRIVE_SCRIPT=%SCRIPT_DIR%..\powershell\ensure_data_drive.ps1"
set "UPDATE_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\invoke_update_mode.ps1"
set "PROVISIONING_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\invoke_provisioning_mode.ps1"
set "RESOLVE_MAINTENANCE_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_maintenance_mode_from_instance_tag.ps1"
set "RESOLVE_SERVICE_CLASS_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_service_class_from_instance_tag.ps1"
set "ACTIVE_RUNTIME_IDENTITY_PUBLISHER=%SCRIPT_DIR%..\powershell\publish_active_runtime_identity_tags.ps1"
set "STOP_SUPERSEDED_ROOT_SCRIPT=%SCRIPT_DIR%..\powershell\stop_superseded_root_processes.ps1"
set "NORMALIZE_DELIVERY_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\normalize_pixelstreaming_delivery_mode.ps1"
set "STACK_MODE=normal"
set "STACK_START_WATCHDOG=true"
set "STACK_START_UNREAL=true"
set "STACK_CONFIG_SERVICE_CLASS_ARG="
set "STARTUP_TELEMETRY_CMD=%SCRIPT_DIR%startup_telemetry.bat"
set "STARTUP_TELEMETRY_MODE=normal"
if /i "%~1"=="--recovery" set "STARTUP_TELEMETRY_MODE=recovery"
if /i "%~1"=="--validation" set "STARTUP_TELEMETRY_MODE=validation"
if exist "%STARTUP_TELEMETRY_CMD%" call "%STARTUP_TELEMETRY_CMD%" begin stack %STARTUP_TELEMETRY_MODE%
call :startup_phase metadata.started 0
if not defined STREAMING_LANE_TAG_RETRY_COUNT set "STREAMING_LANE_TAG_RETRY_COUNT=12"
if not defined STREAMING_LANE_TAG_RETRY_DELAY_SECONDS set "STREAMING_LANE_TAG_RETRY_DELAY_SECONDS=5"
if not defined DEPLOYMENT_TRACK_TAG_RETRY_COUNT set "DEPLOYMENT_TRACK_TAG_RETRY_COUNT=%STREAMING_LANE_TAG_RETRY_COUNT%"
if not defined DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS set "DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS=%STREAMING_LANE_TAG_RETRY_DELAY_SECONDS%"
if not defined DELIVERY_MODE_TAG_RETRY_COUNT set "DELIVERY_MODE_TAG_RETRY_COUNT=%STREAMING_LANE_TAG_RETRY_COUNT%"
if not defined DELIVERY_MODE_TAG_RETRY_DELAY_SECONDS set "DELIVERY_MODE_TAG_RETRY_DELAY_SECONDS=%STREAMING_LANE_TAG_RETRY_DELAY_SECONDS%"
if not defined MAINTENANCE_MODE_TAG_RETRY_COUNT set "MAINTENANCE_MODE_TAG_RETRY_COUNT=%STREAMING_LANE_TAG_RETRY_COUNT%"
if not defined MAINTENANCE_MODE_TAG_RETRY_DELAY_SECONDS set "MAINTENANCE_MODE_TAG_RETRY_DELAY_SECONDS=%STREAMING_LANE_TAG_RETRY_DELAY_SECONDS%"
if not defined SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG set "SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG=-RunProvisioningPSOWarmup"
if not defined SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS set "SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS=-ExecCmds="sg.ViewDistanceQuality 4,sg.AntiAliasingQuality 4,sg.ShadowQuality 4,sg.GlobalIlluminationQuality 4,sg.ReflectionQuality 4,sg.PostProcessQuality 4,sg.TextureQuality 4,sg.EffectsQuality 4,sg.FoliageQuality 4,sg.ShadingQuality 4""
if not defined SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG set "SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG=-ScaleWorldPremium"
if not defined SCALEWORLD_STANDARD_ENCODER_CODEC set "SCALEWORLD_STANDARD_ENCODER_CODEC=vp9"
if not defined SCALEWORLD_PREMIUM_ENCODER_CODEC set "SCALEWORLD_PREMIUM_ENCODER_CODEC=AV1"
if not defined SCALEWORLD_RUNTIME_ENTITLEMENT_MANIFEST_PATH set "SCALEWORLD_RUNTIME_ENTITLEMENT_MANIFEST_PATH=C:\ProgramData\ScaleWorld\runtime-entitlement-manifest.json"
set "STACK_PREPARED_LANE=%SCALEWORLD_STREAMING_LANE%"
set "STACK_PREPARED_TRACK=%SCALEWORLD_DEPLOYMENT_TRACK%"
set "STACK_PREPARED_DELIVERY=%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"
call :read_startup_metadata_batch
call :resolve_streaming_lane_from_instance_tag
if errorlevel 1 exit /b 1
if defined RESOLVED_STREAMING_LANE set "SCALEWORLD_STREAMING_LANE=%RESOLVED_STREAMING_LANE%"
if not defined SCALEWORLD_STREAMING_LANE set "SCALEWORLD_STREAMING_LANE=nonprod"
call :resolve_deployment_track_from_instance_tag
if errorlevel 1 exit /b 1
if defined RESOLVED_DEPLOYMENT_TRACK set "SCALEWORLD_DEPLOYMENT_TRACK=%RESOLVED_DEPLOYMENT_TRACK%"
if not defined SCALEWORLD_DEPLOYMENT_TRACK (
  if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" (
    set "SCALEWORLD_DEPLOYMENT_TRACK=prod"
  ) else (
    set "SCALEWORLD_DEPLOYMENT_TRACK=stage"
  )
)
if defined SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE goto startup_delivery_mode_resolved
call :resolve_pixelstreaming_delivery_mode_from_instance_tag
if errorlevel 1 exit /b 1
if defined RESOLVED_PIXELSTREAMING_DELIVERY_MODE set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=%RESOLVED_PIXELSTREAMING_DELIVERY_MODE%"
:startup_delivery_mode_resolved
if not defined SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=git_ref"
  ) else (
    set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=auto"
  )
)
if not exist "%NORMALIZE_DELIVERY_MODE_SCRIPT%" (
  echo ERROR: PixelStreaming delivery mode normalizer not found at "%NORMALIZE_DELIVERY_MODE_SCRIPT%".
  exit /b 1
)
set "NORMALIZED_PIXELSTREAMING_DELIVERY_MODE="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%NORMALIZE_DELIVERY_MODE_SCRIPT%" -Value "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"`) do (
  set "NORMALIZED_PIXELSTREAMING_DELIVERY_MODE=%%I"
)
if not defined NORMALIZED_PIXELSTREAMING_DELIVERY_MODE exit /b 1
set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=%NORMALIZED_PIXELSTREAMING_DELIVERY_MODE%"
rem Routing tags stay fresh. Changed routing discards optional preparation reuse.
if /i not "%STACK_PREPARED_LANE%"=="%SCALEWORLD_STREAMING_LANE%" set "SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED=false"
if /i not "%STACK_PREPARED_TRACK%"=="%SCALEWORLD_DEPLOYMENT_TRACK%" set "SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED=false"
if /i not "%STACK_PREPARED_DELIVERY%"=="%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%" set "SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED=false"
call :startup_phase metadata.completed 0
if not defined SCALEWORLD_GIT_SYNC_MODE (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  )
)
if /i "%SCALEWORLD_GIT_SYNC_MODE%"=="upstream" (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    echo WARNING: Prod deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/prod/git-target-ref controls startup.
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    echo WARNING: Stage deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/stage/git-target-ref controls startup.
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  )
)
if not defined SCALEWORLD_GIT_TARGET_REF_PARAM (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/prod/git-target-ref"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/stage/git-target-ref;/pixelstreaming/nonprod/git-target-ref"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/dev/git-target-ref;/pixelstreaming/nonprod/git-target-ref"
  ) else (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/nonprod/git-target-ref"
  )
)
if exist "%RUNTIME_BUNDLE_METADATA%" (
  echo PixelStreaming runtime artifact metadata detected at "%RUNTIME_BUNDLE_METADATA%". Using the current launch root as the active runtime.
  set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=runtime_artifact"
  set "WATCHDOG_RESTART_COMMAND=""%SCRIPT_DIR%start_streamer_stack.bat"" --recovery"
  set "WATCHDOG_WILBUR_RESTART_COMMAND=""%SCRIPT_DIR%start_dev_turn.bat"""
  set "WATCHDOG_UNREAL_RESTART_COMMAND=""%SCRIPT_DIR%start_unreal.bat"""
  set "WATCHDOG_WILBUR_COMMANDLINE_PATTERN=%PIXELSTREAMING_ROOT%\SignallingWebServer"
  set "WATCHDOG_STREAMER_HEALTH_PATH=%PIXELSTREAMING_ROOT%\SignallingWebServer\state\streamer-health.json"
  if exist "%WATCHDOG_STREAMER_HEALTH_PATH%" (
    del /f /q "%WATCHDOG_STREAMER_HEALTH_PATH%" >nul 2>nul
    if exist "%WATCHDOG_STREAMER_HEALTH_PATH%" (
      echo WARNING: Failed to remove stale streamer health snapshot at "%WATCHDOG_STREAMER_HEALTH_PATH%".
    ) else (
      echo Removed stale streamer health snapshot at "%WATCHDOG_STREAMER_HEALTH_PATH%".
    )
  )
  set "SCALEWORLD_STACK_RUNTIME_IDENTITY_PUBLISHED="
  if /i "%SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED%"=="true" set "SCALEWORLD_STACK_RUNTIME_IDENTITY_PUBLISHED=true"
  if /i not "%SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED%"=="true" if exist "%ACTIVE_RUNTIME_IDENTITY_PUBLISHER%" (
    call :startup_phase identity.started 0
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ACTIVE_RUNTIME_IDENTITY_PUBLISHER%" -RuntimeRoot "%PIXELSTREAMING_ROOT%"
    if "!errorlevel!"=="0" set "SCALEWORLD_STACK_RUNTIME_IDENTITY_PUBLISHED=true"
    call :startup_phase identity.completed !errorlevel!
  ) else (
    if /i not "%SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED%"=="true" echo WARNING: Active runtime identity publisher not found at "%ACTIVE_RUNTIME_IDENTITY_PUBLISHER%".
  )
)
if not defined STACK_ENABLE_BOOT_GIT_SYNC (
  if exist "%RUNTIME_BUNDLE_METADATA%" (
    set "STACK_ENABLE_BOOT_GIT_SYNC=false"
  ) else if /i "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"=="runtime_artifact" (
    set "STACK_ENABLE_BOOT_GIT_SYNC=false"
  ) else if /i "%SCALEWORLD_GIT_SYNC_MODE%"=="off" (
    set "STACK_ENABLE_BOOT_GIT_SYNC=false"
  ) else (
    set "STACK_ENABLE_BOOT_GIT_SYNC=true"
  )
)
if not defined STACK_LAUNCH_UNREAL_BEFORE_WILBUR set "STACK_LAUNCH_UNREAL_BEFORE_WILBUR=false"
if not defined STACK_PREPARE_DATA_DRIVE set "STACK_PREPARE_DATA_DRIVE=true"
if not defined STACK_REQUIRE_DATA_DRIVE set "STACK_REQUIRE_DATA_DRIVE=false"
if not defined STACK_ENABLE_UPDATE_MODE set "STACK_ENABLE_UPDATE_MODE=true"
if not defined STACK_ENABLE_PROVISIONING_MODE set "STACK_ENABLE_PROVISIONING_MODE=true"
if not defined SCALEWORLD_DATA_DISK_NUMBER set "SCALEWORLD_DATA_DISK_NUMBER=1"

if /i "%~1"=="--recovery" (
  set "STACK_MODE=recovery"
  shift
)

if /i "%~1"=="--validation" (
  set "STACK_MODE=validation"
  set "STACK_ENABLE_UPDATE_MODE=false"
  set "STACK_ENABLE_PROVISIONING_MODE=false"
  set "STACK_ENABLE_BOOT_GIT_SYNC=false"
  set "STACK_RUN_UNREAL_UPDATE_CHECK=false"
  shift
)

if not defined STACK_WATCHDOG_START_DELAY_SECONDS set "STACK_WATCHDOG_START_DELAY_SECONDS=3"
if not defined STACK_UNREAL_START_DELAY_SECONDS set "STACK_UNREAL_START_DELAY_SECONDS=1"
if not defined SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS set "SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS=120"
if not defined STACK_WILBUR_READY_HOST set "STACK_WILBUR_READY_HOST=127.0.0.1"
if not defined STACK_WILBUR_READY_PORT (
  if defined SCALEWORLD_PIXEL_STREAMING_PORT (
    set "STACK_WILBUR_READY_PORT=%SCALEWORLD_PIXEL_STREAMING_PORT%"
  ) else (
    set "STACK_WILBUR_READY_PORT=8888"
  )
)
if not defined STACK_WILBUR_READY_TIMEOUT_SECONDS set "STACK_WILBUR_READY_TIMEOUT_SECONDS=60"
if not defined STACK_RUN_UNREAL_UPDATE_CHECK set "STACK_RUN_UNREAL_UPDATE_CHECK=false"
if not defined WATCHDOG_TERMINATE_MATCHED_PROCESSES set "WATCHDOG_TERMINATE_MATCHED_PROCESSES=true"

if /i "%STACK_MODE%"=="recovery" set "STACK_RUN_UNREAL_UPDATE_CHECK=false"
set "STACK_LAUNCH_EXIT=0"

if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_UPDATE_MODE%"=="true" (
  if exist "%UPDATE_MODE_SCRIPT%" (
    echo Checking instance update mode...
    call :startup_phase update_control.started 0
    powershell -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_MODE_SCRIPT%"
    set "UPDATE_MODE_EXIT=!errorlevel!"
    if "!UPDATE_MODE_EXIT!"=="10" (
      echo Update mode completed successfully. Skipping normal startup.
      exit /b 0
    )
    if "!UPDATE_MODE_EXIT!"=="11" (
      echo Update mode is holding the instance in maintenance. Skipping normal startup.
      exit /b 0
    )
    if not "!UPDATE_MODE_EXIT!"=="0" (
      echo ERROR: Update mode check failed with exit code !UPDATE_MODE_EXIT!.
      exit /b !UPDATE_MODE_EXIT!
    )
    rem A terminal handoff can retarget this BAT's junction. Never CALL a
    rem label through that changed path before leaving the parsed source block.
    call :startup_phase update_control.completed !UPDATE_MODE_EXIT!
  ) else (
    echo WARNING: Update mode script not found at "%UPDATE_MODE_SCRIPT%". Continuing with normal startup.
  )
)

if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_PROVISIONING_MODE%"=="true" (
  if exist "%PROVISIONING_MODE_SCRIPT%" (
    echo Checking instance provisioning mode...
    call :startup_phase provisioning_control.started 0
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PROVISIONING_MODE_SCRIPT%"
    set "PROVISIONING_MODE_EXIT=!errorlevel!"
    if "!PROVISIONING_MODE_EXIT!"=="42" (
      echo Provisioning transferred to the installed runtime. Leaving the source launcher.
      exit /b 0
    )
    if not "!PROVISIONING_MODE_EXIT!"=="0" (
      echo ERROR: Provisioning mode bootstrap failed with exit code !PROVISIONING_MODE_EXIT!.
      exit /b !PROVISIONING_MODE_EXIT!
    )
    call :startup_phase provisioning_control.completed !PROVISIONING_MODE_EXIT!
  ) else (
    echo WARNING: Provisioning mode script not found at "%PROVISIONING_MODE_SCRIPT%". Continuing with normal startup.
  )
)

if not defined WATCHDOG_RESTART_COMMAND set "WATCHDOG_RESTART_COMMAND=""%SCRIPT_DIR%start_streamer_stack.bat"" --recovery"

call :startup_phase maintenance_control.started 0
call :apply_unreal_provisioning_startup_args
call :startup_phase maintenance_control.completed %errorlevel%
if errorlevel 1 exit /b 1
call :startup_phase service_class.started 0
call :apply_unreal_service_class_startup_args
call :startup_phase service_class.completed %errorlevel%
if errorlevel 1 exit /b 1

echo PixelStreaming delivery mode "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%" for %SCALEWORLD_STREAMING_LANE%/%SCALEWORLD_DEPLOYMENT_TRACK% startup.

if /i "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"=="runtime_artifact" if not exist "%RUNTIME_BUNDLE_METADATA%" (
  echo ERROR: PixelStreaming delivery mode runtime_artifact requires runtime metadata at "%RUNTIME_BUNDLE_METADATA%".
  echo ERROR: Convert the launch root to an installed artifact or explicitly switch the instance back to git_ref maintenance.
  exit /b 1
)

if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_BOOT_GIT_SYNC%"=="true" (
  call :sync_repo_before_stack
  set "STACK_SYNC_EXIT=!errorlevel!"
  if "!STACK_SYNC_EXIT!"=="42" (
    echo Repo sync launched a fresh stack from the updated checkout. Exiting this pre-update launcher.
    exit /b 0
  )
  if not "!STACK_SYNC_EXIT!"=="0" exit /b !STACK_SYNC_EXIT!
)

call :startup_phase old_roots.started 0
call :stop_superseded_runtime_roots_before_stack_launch
call :startup_phase old_roots.completed %errorlevel%

if /i "%STACK_RUN_UNREAL_UPDATE_CHECK%"=="true" (
  if exist "%UPDATE_SCRIPT%" (
    echo Running Unreal update check...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_SCRIPT%"
    if errorlevel 1 (
      echo ERROR: Unreal update check failed.
      exit /b 1
    )
  ) else (
    echo WARNING: Update script not found at "%UPDATE_SCRIPT%". Skipping Unreal update check.
  )
)
set "SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT=%ProgramData%\ScaleWorld\instance-config-snapshot.json"
call :startup_phase config.started 0
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\initialize_instance_config.ps1" -RuntimeRoot "%PIXELSTREAMING_ROOT%" -InstallBase "%SCALEWORLD_INSTALL_BASE%" -Environment "%SCALEWORLD_DEPLOYMENT_TRACK%" -Mode "%STACK_MODE%" %STACK_CONFIG_SERVICE_CLASS_ARG%
call :startup_phase config.completed %errorlevel%
if errorlevel 1 (
  echo ERROR: Instance config initialization failed. See the instance-config snapshot error file in ProgramData\ScaleWorld.
  exit /b 1
)
set "WILBUR_PROCESS_NAME=node.exe"
if defined WATCHDOG_WILBUR_PROCESS_NAME set "WILBUR_PROCESS_NAME=%WATCHDOG_WILBUR_PROCESS_NAME%"
set "WILBUR_COMMANDLINE_PATTERN=%PIXELSTREAMING_ROOT%\SignallingWebServer"
set "WILBUR_LAUNCHER_PATTERN=%SCRIPT_DIR%start_dev_turn.bat"
if defined WATCHDOG_WILBUR_COMMANDLINE_PATTERN set "WILBUR_COMMANDLINE_PATTERN=%WATCHDOG_WILBUR_COMMANDLINE_PATTERN%"
set "UNREAL_PROCESS_NAME=ScaleWorld.exe"
if defined SCALEWORLD_EXECUTABLE_NAME set "UNREAL_PROCESS_NAME=%SCALEWORLD_EXECUTABLE_NAME%"
set "UNREAL_LAUNCHER_PATTERN=start_unreal.bat"
set "TEST_UNREAL_RUNTIME_SCRIPT=%SCRIPT_DIR%..\powershell\test_scaleworld_runtime_present.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$wilbur = Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq '%WILBUR_PROCESS_NAME%' -and $_.CommandLine -like '*%WILBUR_COMMANDLINE_PATTERN%*') -or ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -like '*%WILBUR_LAUNCHER_PATTERN%*') } | Select-Object -First 1; if ($wilbur) { exit 0 } else { exit 1 }"
call :startup_phase wilbur_process_check.completed %errorlevel%
if errorlevel 1 (
  echo Starting Wilbur in %STACK_MODE% mode...
  rem Pass only this launch's successful tag resolutions to the child. Watchdog
  rem and later standalone launches must still resolve their own metadata.
  set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA="
  if defined RESOLVED_STREAMING_LANE if defined RESOLVED_DEPLOYMENT_TRACK set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA=true"
  start "ScaleWorld Wilbur" "%SCRIPT_DIR%start_dev_turn.bat" %*
  set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA="
  call :startup_phase wilbur_launch.scheduled 0
) else (
  echo Wilbur is already running or launch is already in progress. Skipping launch.
)

if /i "%STACK_START_UNREAL%"=="true" if /i "%STACK_LAUNCH_UNREAL_BEFORE_WILBUR%"=="true" (
  call :launch_unreal_if_needed
  if errorlevel 1 set "STACK_LAUNCH_EXIT=1"
)

if /i "%STACK_START_UNREAL%"=="true" if /i not "%STACK_LAUNCH_UNREAL_BEFORE_WILBUR%"=="true" if "!STACK_LAUNCH_EXIT!"=="0" (
  call :startup_phase wilbur_tcp.started 0
  call :wait_for_wilbur_ready
  call :startup_phase wilbur_tcp.completed !errorlevel!
  if errorlevel 1 (
    echo ERROR: Wilbur did not become ready on %STACK_WILBUR_READY_HOST%:%STACK_WILBUR_READY_PORT% within %STACK_WILBUR_READY_TIMEOUT_SECONDS% seconds.
    set "STACK_LAUNCH_EXIT=1"
  )

  if "!STACK_LAUNCH_EXIT!"=="0" (
    call :startup_phase unreal_launch.started 0
    call :launch_unreal_if_needed
    call :startup_phase unreal_launch.completed !errorlevel!
    if errorlevel 1 set "STACK_LAUNCH_EXIT=1"
  )
)
if /i "%STACK_START_WATCHDOG%"=="true" (
  if exist "%SCRIPT_DIR%start_watchdog.bat" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$currentPid = $PID; $scriptDir = [System.IO.Path]::GetFullPath('%SCRIPT_DIR%'); $watchdogScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\powershell\watchdog.ps1')); $watchdogLauncher = [System.IO.Path]::GetFullPath((Join-Path $scriptDir 'start_watchdog.bat')); $watchdog = Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $currentPid -and (($_.Name -ieq 'powershell.exe' -and $_.CommandLine -like ('*' + $watchdogScript + '*')) -or ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -like ('*' + $watchdogLauncher + '*'))) } | Select-Object -First 1; if ($watchdog) { exit 0 } else { exit 1 }"
    if errorlevel 1 (
      echo Scheduling watchdog start in %STACK_WATCHDOG_START_DELAY_SECONDS% seconds...
      start "ScaleWorld Watchdog" powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\start_stack_watchdog.ps1" -DelaySeconds %STACK_WATCHDOG_START_DELAY_SECONDS%
    ) else (
      echo Watchdog is already running or launch is already in progress. Skipping launch.
    )
  ) else (
    echo WARNING: start_watchdog.bat not found in "%SCRIPT_DIR%". Watchdog launch skipped.
  )
)

if not "%STACK_LAUNCH_EXIT%"=="0" (
  echo ERROR: Stack launch completed with component startup failures. Watchdog was scheduled when enabled for recovery.
  exit /b %STACK_LAUNCH_EXIT%
)

echo Stack launch completed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%STACK_LEASE_SCRIPT%" -Mode Complete -RepoRoot "%STACK_SIGNALLING_ROOT%" -InstallBase "%SCALEWORLD_INSTALL_BASE%"
if errorlevel 1 exit /b 1
call :startup_phase stack.completed 0
if exist "%STARTUP_TELEMETRY_CMD%" call "%STARTUP_TELEMETRY_CMD%" end 0
exit /b 0

:startup_phase
if exist "%STARTUP_TELEMETRY_CMD%" call "%STARTUP_TELEMETRY_CMD%" phase %~1 %~2
exit /b %errorlevel%

:stop_superseded_runtime_roots_before_stack_launch
if not exist "%RUNTIME_BUNDLE_METADATA%" exit /b 0
if exist "%STOP_SUPERSEDED_ROOT_SCRIPT%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%STOP_SUPERSEDED_ROOT_SCRIPT%" -CurrentRoot "%PIXELSTREAMING_ROOT%" -ActiveRoot "%PIXELSTREAMING_ROOT%" -InstallRoot "%SCALEWORLD_INSTALL_BASE%" -AllRoots -WaitSeconds 3
  if errorlevel 1 echo WARNING: Superseded PixelStreaming root cleanup failed before artifact-root stack launch.
) else (
  echo WARNING: Superseded PixelStreaming root cleanup script not found at "%STOP_SUPERSEDED_ROOT_SCRIPT%".
)
exit /b 0

:sync_repo_before_stack
set "REPO_SYNC_SCRIPT=%SCRIPT_DIR%..\powershell\ensure_repo_current.ps1"

if not exist "%REPO_SYNC_SCRIPT%" (
  echo ERROR: Repo sync helper not found at "%REPO_SYNC_SCRIPT%".
  exit /b 1
)

echo Applying git sync mode "%SCALEWORLD_GIT_SYNC_MODE%" before normal startup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_SYNC_SCRIPT%" -RepoRoot "%PIXELSTREAMING_ROOT%" -Mode "startup"
set "REPO_SYNC_EXIT=%errorlevel%"
if "%REPO_SYNC_EXIT%"=="42" exit /b 42
if not "%REPO_SYNC_EXIT%"=="0" (
  echo ERROR: Boot-time repo sync failed.
  exit /b %REPO_SYNC_EXIT%
)

exit /b 0

:read_startup_metadata_batch
rem One launch-local first attempt; only fixed enum tokens cross into CMD.
rem Each field retains its own subsequent attempts/delay and failure policy.
set "STARTUP_BATCH_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_startup_metadata_from_instance_tags.ps1"
set "STARTUP_BATCH_ENABLED="
set "STARTUP_BATCH_LANE=LOOKUP_FAILED"
set "STARTUP_BATCH_TRACK=LOOKUP_FAILED"
set "STARTUP_BATCH_DELIVERY=LOOKUP_FAILED"
if not exist "%STARTUP_BATCH_SCRIPT%" exit /b 0
set "STARTUP_BATCH_ENABLED=true"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTUP_BATCH_SCRIPT%"`) do (
  if "%%I"=="LANE_NONPROD" set "STARTUP_BATCH_LANE=LANE_NONPROD"
  if "%%I"=="LANE_PROD" set "STARTUP_BATCH_LANE=LANE_PROD"
  if "%%I"=="LANE_MISSING" set "STARTUP_BATCH_LANE=LANE_MISSING"
  if "%%I"=="LANE_INVALID" set "STARTUP_BATCH_LANE=LANE_INVALID"
  if "%%I"=="TRACK_DEV" set "STARTUP_BATCH_TRACK=TRACK_DEV"
  if "%%I"=="TRACK_STAGE" set "STARTUP_BATCH_TRACK=TRACK_STAGE"
  if "%%I"=="TRACK_PROD" set "STARTUP_BATCH_TRACK=TRACK_PROD"
  if "%%I"=="TRACK_MISSING" set "STARTUP_BATCH_TRACK=TRACK_MISSING"
  if "%%I"=="DELIVERY_GIT_REF" set "STARTUP_BATCH_DELIVERY=DELIVERY_GIT_REF"
  if "%%I"=="DELIVERY_RUNTIME_ARTIFACT" set "STARTUP_BATCH_DELIVERY=DELIVERY_RUNTIME_ARTIFACT"
  if "%%I"=="DELIVERY_AUTO" set "STARTUP_BATCH_DELIVERY=DELIVERY_AUTO"
  if "%%I"=="DELIVERY_MISSING" set "STARTUP_BATCH_DELIVERY=DELIVERY_MISSING"
  if "%%I"=="DELIVERY_INVALID" set "STARTUP_BATCH_DELIVERY=DELIVERY_INVALID"
)
exit /b 0

:resolve_streaming_lane_from_instance_tag
set "RESOLVED_STREAMING_LANE="
set "RESOLVE_STREAMING_LANE_EXIT=0"
set /a STREAMING_LANE_TAG_ATTEMPT=0
set "RESOLVE_STREAMING_LANE_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_streaming_lane_from_instance_tag.ps1"

:resolve_streaming_lane_retry
set /a STREAMING_LANE_TAG_ATTEMPT+=1
set "RESOLVED_STREAMING_LANE="
if /i "%STARTUP_BATCH_ENABLED%"=="true" (
  if not "!STREAMING_LANE_TAG_ATTEMPT!"=="1" (
    set "STARTUP_BATCH_LANE=LOOKUP_FAILED"
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTUP_BATCH_SCRIPT%" -Field lane`) do (
      if "%%I"=="LANE_NONPROD" set "STARTUP_BATCH_LANE=LANE_NONPROD"
      if "%%I"=="LANE_PROD" set "STARTUP_BATCH_LANE=LANE_PROD"
      if "%%I"=="LANE_MISSING" set "STARTUP_BATCH_LANE=LANE_MISSING"
      if "%%I"=="LANE_INVALID" set "STARTUP_BATCH_LANE=LANE_INVALID"
    )
  )
  set "RESOLVE_STREAMING_LANE_EXIT=2"
  if "!STARTUP_BATCH_LANE!"=="LANE_NONPROD" set "RESOLVED_STREAMING_LANE=nonprod"
  if "!STARTUP_BATCH_LANE!"=="LANE_PROD" set "RESOLVED_STREAMING_LANE=prod"
  if "!STARTUP_BATCH_LANE!"=="LANE_MISSING" set "RESOLVE_STREAMING_LANE_EXIT=0"
  if "!STARTUP_BATCH_LANE!"=="LANE_INVALID" (
    call :startup_phase metadata.lane.attempt_!STREAMING_LANE_TAG_ATTEMPT! 1
    echo ERROR: Unsupported ScaleWorldLane. Refusing startup.
    exit /b 1
  )
  goto resolve_streaming_lane_result
)
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_STREAMING_LANE_SCRIPT%"`) do (
  set "RESOLVED_STREAMING_LANE=%%I"
)
set "RESOLVE_STREAMING_LANE_EXIT=%errorlevel%"

:resolve_streaming_lane_result
if defined RESOLVED_STREAMING_LANE set "RESOLVE_STREAMING_LANE_EXIT=0"
call :startup_phase metadata.lane.attempt_%STREAMING_LANE_TAG_ATTEMPT% %RESOLVE_STREAMING_LANE_EXIT%
if defined RESOLVED_STREAMING_LANE exit /b 0
if "%RESOLVE_STREAMING_LANE_EXIT%"=="0" (
  if %STREAMING_LANE_TAG_ATTEMPT% geq %STREAMING_LANE_TAG_RETRY_COUNT% exit /b 0
  echo WARNING: Failed to resolve ScaleWorldLane instance tag on attempt %STREAMING_LANE_TAG_ATTEMPT% of %STREAMING_LANE_TAG_RETRY_COUNT%.
  echo WARNING: Retrying in %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% seconds before falling back to default lane.
  timeout /t %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
  goto resolve_streaming_lane_retry
)

if %STREAMING_LANE_TAG_ATTEMPT% geq %STREAMING_LANE_TAG_RETRY_COUNT% (
  echo ERROR: ScaleWorldLane instance tag resolution failed after %STREAMING_LANE_TAG_RETRY_COUNT% attempts.
  echo ERROR: Refusing to continue with an inferred default lane after a real tag lookup failure.
  exit /b 1
)

echo WARNING: ScaleWorldLane instance tag lookup failed on attempt %STREAMING_LANE_TAG_ATTEMPT% of %STREAMING_LANE_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% seconds before failing startup.
timeout /t %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_streaming_lane_retry

exit /b 0

:resolve_deployment_track_from_instance_tag
set "RESOLVED_DEPLOYMENT_TRACK="
set "RESOLVE_DEPLOYMENT_TRACK_EXIT=0"
set /a DEPLOYMENT_TRACK_TAG_ATTEMPT=0
set "RESOLVE_DEPLOYMENT_TRACK_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_deployment_track_from_instance_tag.ps1"
if not exist "%RESOLVE_DEPLOYMENT_TRACK_SCRIPT%" exit /b 0

:resolve_deployment_track_retry
set /a DEPLOYMENT_TRACK_TAG_ATTEMPT+=1
set "RESOLVED_DEPLOYMENT_TRACK="
if /i "%STARTUP_BATCH_ENABLED%"=="true" (
  if not "!DEPLOYMENT_TRACK_TAG_ATTEMPT!"=="1" (
    set "STARTUP_BATCH_TRACK=LOOKUP_FAILED"
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTUP_BATCH_SCRIPT%" -Field track`) do (
      if "%%I"=="TRACK_DEV" set "STARTUP_BATCH_TRACK=TRACK_DEV"
      if "%%I"=="TRACK_STAGE" set "STARTUP_BATCH_TRACK=TRACK_STAGE"
      if "%%I"=="TRACK_PROD" set "STARTUP_BATCH_TRACK=TRACK_PROD"
      if "%%I"=="TRACK_MISSING" set "STARTUP_BATCH_TRACK=TRACK_MISSING"
    )
  )
  set "RESOLVE_DEPLOYMENT_TRACK_EXIT=2"
  if "!STARTUP_BATCH_TRACK!"=="TRACK_DEV" set "RESOLVED_DEPLOYMENT_TRACK=dev"
  if "!STARTUP_BATCH_TRACK!"=="TRACK_STAGE" set "RESOLVED_DEPLOYMENT_TRACK=stage"
  if "!STARTUP_BATCH_TRACK!"=="TRACK_PROD" set "RESOLVED_DEPLOYMENT_TRACK=prod"
  if "!STARTUP_BATCH_TRACK!"=="TRACK_MISSING" set "RESOLVE_DEPLOYMENT_TRACK_EXIT=0"
  goto resolve_deployment_track_result
)
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_DEPLOYMENT_TRACK_SCRIPT%"`) do (
  set "RESOLVED_DEPLOYMENT_TRACK=%%I"
)
set "RESOLVE_DEPLOYMENT_TRACK_EXIT=%errorlevel%"

:resolve_deployment_track_result
if defined RESOLVED_DEPLOYMENT_TRACK set "RESOLVE_DEPLOYMENT_TRACK_EXIT=0"
call :startup_phase metadata.track.attempt_%DEPLOYMENT_TRACK_TAG_ATTEMPT% %RESOLVE_DEPLOYMENT_TRACK_EXIT%
if defined RESOLVED_DEPLOYMENT_TRACK exit /b 0
if "%RESOLVE_DEPLOYMENT_TRACK_EXIT%"=="0" (
  if %DEPLOYMENT_TRACK_TAG_ATTEMPT% geq %DEPLOYMENT_TRACK_TAG_RETRY_COUNT% exit /b 0
  echo WARNING: Failed to resolve ScaleWorldDeploymentTrack instance tag on attempt %DEPLOYMENT_TRACK_TAG_ATTEMPT% of %DEPLOYMENT_TRACK_TAG_RETRY_COUNT%.
  echo WARNING: Retrying in %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% seconds before falling back to default deployment track.
  timeout /t %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
  goto resolve_deployment_track_retry
)

if %DEPLOYMENT_TRACK_TAG_ATTEMPT% geq %DEPLOYMENT_TRACK_TAG_RETRY_COUNT% (
  echo ERROR: ScaleWorldDeploymentTrack instance tag resolution failed after %DEPLOYMENT_TRACK_TAG_RETRY_COUNT% attempts.
  echo ERROR: Refusing to continue with an inferred default deployment track after a real tag lookup failure.
  exit /b 1
)

echo WARNING: ScaleWorldDeploymentTrack instance tag lookup failed on attempt %DEPLOYMENT_TRACK_TAG_ATTEMPT% of %DEPLOYMENT_TRACK_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% seconds before failing startup.
timeout /t %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_deployment_track_retry

:resolve_pixelstreaming_delivery_mode_from_instance_tag
set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE="
set "RESOLVE_DELIVERY_MODE_EXIT=0"
set /a DELIVERY_MODE_TAG_ATTEMPT=0
set "RESOLVE_DELIVERY_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_pixelstreaming_delivery_mode_from_instance_tag.ps1"
if not exist "%RESOLVE_DELIVERY_MODE_SCRIPT%" exit /b 0

:resolve_delivery_mode_retry
set /a DELIVERY_MODE_TAG_ATTEMPT+=1
set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE="
if /i "%STARTUP_BATCH_ENABLED%"=="true" (
  if not "!DELIVERY_MODE_TAG_ATTEMPT!"=="1" (
    set "STARTUP_BATCH_DELIVERY=LOOKUP_FAILED"
    for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTUP_BATCH_SCRIPT%" -Field delivery`) do (
      if "%%I"=="DELIVERY_GIT_REF" set "STARTUP_BATCH_DELIVERY=DELIVERY_GIT_REF"
      if "%%I"=="DELIVERY_RUNTIME_ARTIFACT" set "STARTUP_BATCH_DELIVERY=DELIVERY_RUNTIME_ARTIFACT"
      if "%%I"=="DELIVERY_AUTO" set "STARTUP_BATCH_DELIVERY=DELIVERY_AUTO"
      if "%%I"=="DELIVERY_MISSING" set "STARTUP_BATCH_DELIVERY=DELIVERY_MISSING"
      if "%%I"=="DELIVERY_INVALID" set "STARTUP_BATCH_DELIVERY=DELIVERY_INVALID"
    )
  )
  set "RESOLVE_DELIVERY_MODE_EXIT=2"
  if "!STARTUP_BATCH_DELIVERY!"=="DELIVERY_GIT_REF" set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE=git_ref"
  if "!STARTUP_BATCH_DELIVERY!"=="DELIVERY_RUNTIME_ARTIFACT" set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE=runtime_artifact"
  if "!STARTUP_BATCH_DELIVERY!"=="DELIVERY_AUTO" set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE=auto"
  if "!STARTUP_BATCH_DELIVERY!"=="DELIVERY_MISSING" set "RESOLVE_DELIVERY_MODE_EXIT=0"
  goto resolve_delivery_mode_result
)
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_DELIVERY_MODE_SCRIPT%"`) do (
  set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE=%%I"
)
set "RESOLVE_DELIVERY_MODE_EXIT=%errorlevel%"

:resolve_delivery_mode_result
if defined RESOLVED_PIXELSTREAMING_DELIVERY_MODE set "RESOLVE_DELIVERY_MODE_EXIT=0"
call :startup_phase metadata.delivery.attempt_%DELIVERY_MODE_TAG_ATTEMPT% %RESOLVE_DELIVERY_MODE_EXIT%
if defined RESOLVED_PIXELSTREAMING_DELIVERY_MODE exit /b 0
if "%RESOLVE_DELIVERY_MODE_EXIT%"=="0" (
  echo ScaleWorldPixelStreamingDeliveryMode instance tag is not set. Using deployment-track default delivery mode.
  exit /b 0
)

if %DELIVERY_MODE_TAG_ATTEMPT% geq %DELIVERY_MODE_TAG_RETRY_COUNT% (
  echo ERROR: ScaleWorldPixelStreamingDeliveryMode instance tag resolution failed after %DELIVERY_MODE_TAG_RETRY_COUNT% attempts.
  echo ERROR: Refusing to continue with an inferred default delivery mode after a real tag lookup failure.
  exit /b 1
)

echo WARNING: ScaleWorldPixelStreamingDeliveryMode instance tag lookup failed on attempt %DELIVERY_MODE_TAG_ATTEMPT% of %DELIVERY_MODE_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %DELIVERY_MODE_TAG_RETRY_DELAY_SECONDS% seconds before failing startup.
timeout /t %DELIVERY_MODE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_delivery_mode_retry

:apply_unreal_provisioning_startup_args
call :resolve_maintenance_mode_from_instance_tag
if errorlevel 1 exit /b 1

if defined SCALEWORLD_UNREAL_STARTUP_ARGS (
  set "SCALEWORLD_UNREAL_STARTUP_ARGS=!SCALEWORLD_UNREAL_STARTUP_ARGS:%SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG%=!"
)

if /i "!RESOLVED_MAINTENANCE_MODE!"=="provisioning" (
  if defined SCALEWORLD_UNREAL_STARTUP_ARGS (
    set "SCALEWORLD_UNREAL_STARTUP_ARGS=!SCALEWORLD_UNREAL_STARTUP_ARGS! !SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG!"
  ) else (
    set "SCALEWORLD_UNREAL_STARTUP_ARGS=!SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG!"
  )
  set "WATCHDOG_UNREAL_RESTART_COMMAND=%WATCHDOG_RESTART_COMMAND%"
  echo Provisioning maintenance detected. Unreal startup will include !SCALEWORLD_UNREAL_PROVISIONING_STARTUP_ARG!.
)

exit /b 0

:apply_unreal_service_class_startup_args
set "STACK_CONFIG_SERVICE_CLASS_ARG="
set "RESOLVED_SERVICE_CLASS=standard"
if defined SCALEWORLD_UNREAL_STARTUP_ARGS (
  set "NORMALIZED_SERVICE_ARGS_FILE=%TEMP%\sw-startup-args-!RANDOM!-!RANDOM!.txt"
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\normalize_unreal_service_class_args.ps1" -OutputPath "!NORMALIZED_SERVICE_ARGS_FILE!"
  if errorlevel 1 (
    if exist "!NORMALIZED_SERVICE_ARGS_FILE!" del /q "!NORMALIZED_SERVICE_ARGS_FILE!"
    exit /b 1
  )
  set "SCALEWORLD_UNREAL_STARTUP_ARGS="
  set /p "SCALEWORLD_UNREAL_STARTUP_ARGS="<"!NORMALIZED_SERVICE_ARGS_FILE!"
  del /q "!NORMALIZED_SERVICE_ARGS_FILE!"
)
if exist "%RESOLVE_SERVICE_CLASS_SCRIPT%" (
  set "RESOLVED_SERVICE_CLASS="
  for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_SERVICE_CLASS_SCRIPT%"`) do (
    set "RESOLVED_SERVICE_CLASS=%%I"
  )
  rem Do not hand off a fallback after a failed lookup. Config resolution must
  rem retain its stricter failure behavior. Only enum values enter CMD arguments.
  if /i "!RESOLVED_SERVICE_CLASS!"=="standard" set "STACK_CONFIG_SERVICE_CLASS_ARG=-ResolvedServiceClass standard"
  if /i "!RESOLVED_SERVICE_CLASS!"=="premium" set "STACK_CONFIG_SERVICE_CLASS_ARG=-ResolvedServiceClass premium"
  if not defined RESOLVED_SERVICE_CLASS (
    echo WARNING: ScaleWorldServiceClass could not be resolved. Using standard Unreal scalability settings.
    set "RESOLVED_SERVICE_CLASS=standard"
  )
)

if /i "!RESOLVED_SERVICE_CLASS!"=="premium" (
  if defined SCALEWORLD_UNREAL_STARTUP_ARGS (
    set "SCALEWORLD_UNREAL_STARTUP_ARGS=!SCALEWORLD_UNREAL_STARTUP_ARGS! !SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG! !SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS!"
  ) else (
    set "SCALEWORLD_UNREAL_STARTUP_ARGS=!SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG! !SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS!"
  )
  set "SCALEWORLD_DEFAULT_ENCODER_CODEC=!SCALEWORLD_PREMIUM_ENCODER_CODEC!"
  echo Premium service class detected. Unreal will receive !SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG!, premium scalability settings, and the !SCALEWORLD_DEFAULT_ENCODER_CODEC! encoder default.
) else (
  set "SCALEWORLD_DEFAULT_ENCODER_CODEC=!SCALEWORLD_STANDARD_ENCODER_CODEC!"
  echo Standard service class detected. Unreal premium settings are absent and the encoder default is !SCALEWORLD_DEFAULT_ENCODER_CODEC!.
)
exit /b 0

:resolve_maintenance_mode_from_instance_tag
set "RESOLVED_MAINTENANCE_MODE="
set "RESOLVE_MAINTENANCE_MODE_EXIT=0"
set /a MAINTENANCE_MODE_TAG_ATTEMPT=0
if not exist "%RESOLVE_MAINTENANCE_MODE_SCRIPT%" exit /b 0

:resolve_maintenance_mode_retry
set /a MAINTENANCE_MODE_TAG_ATTEMPT+=1
set "RESOLVED_MAINTENANCE_MODE="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_MAINTENANCE_MODE_SCRIPT%"`) do (
  set "RESOLVED_MAINTENANCE_MODE=%%I"
)
set "RESOLVE_MAINTENANCE_MODE_EXIT=%errorlevel%"

if defined RESOLVED_MAINTENANCE_MODE exit /b 0
if "%RESOLVE_MAINTENANCE_MODE_EXIT%"=="0" exit /b 0

if %MAINTENANCE_MODE_TAG_ATTEMPT% geq %MAINTENANCE_MODE_TAG_RETRY_COUNT% (
  echo ERROR: ScaleWorldMaintenanceMode instance tag resolution failed after %MAINTENANCE_MODE_TAG_RETRY_COUNT% attempts.
  echo ERROR: Refusing to continue without knowing whether provisioning startup warmup should run.
  exit /b 1
)

echo WARNING: ScaleWorldMaintenanceMode instance tag lookup failed on attempt %MAINTENANCE_MODE_TAG_ATTEMPT% of %MAINTENANCE_MODE_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %MAINTENANCE_MODE_TAG_RETRY_DELAY_SECONDS% seconds before failing startup.
timeout /t %MAINTENANCE_MODE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_maintenance_mode_retry

:launch_unreal_if_needed
if exist "%SCRIPT_DIR%start_unreal.bat" (
  if not exist "%TEST_UNREAL_RUNTIME_SCRIPT%" (
    echo ERROR: Unreal runtime detection script not found at "%TEST_UNREAL_RUNTIME_SCRIPT%".
    exit /b 1
  )
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TEST_UNREAL_RUNTIME_SCRIPT%" -IncludeLaunchers -LauncherGraceSeconds %SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS%
  if errorlevel 1 (
    timeout /t %STACK_UNREAL_START_DELAY_SECONDS% /nobreak >nul
    echo Starting Unreal runtime...
    call "%SCRIPT_DIR%start_unreal.bat" %SCALEWORLD_UNREAL_STARTUP_ARGS%
    if errorlevel 1 (
      echo ERROR: Unreal launch failed.
      exit /b 1
    )
  ) else (
    echo Unreal runtime is already running or a fresh launcher is still in progress. Skipping launch.
  )
) else (
  echo WARNING: start_unreal.bat not found in "%SCRIPT_DIR%". Unreal launch skipped.
)
exit /b 0
:wait_for_wilbur_ready
echo Waiting for Wilbur readiness on %STACK_WILBUR_READY_HOST%:%STACK_WILBUR_READY_PORT%...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$hostName = '%STACK_WILBUR_READY_HOST%'; $port = %STACK_WILBUR_READY_PORT%; $deadline = (Get-Date).AddSeconds(%STACK_WILBUR_READY_TIMEOUT_SECONDS%); while ((Get-Date) -lt $deadline) { $client = $null; try { $client = New-Object System.Net.Sockets.TcpClient; $async = $client.BeginConnect($hostName, $port, $null, $null); if ($async.AsyncWaitHandle.WaitOne(1000)) { $client.EndConnect($async); $client.Close(); exit 0 } } catch { } finally { if ($client) { $client.Close() } } Start-Sleep -Milliseconds 500 } exit 1"
exit /b %errorlevel%
