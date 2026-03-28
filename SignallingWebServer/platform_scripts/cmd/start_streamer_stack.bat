@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..\..") do set "PIXELSTREAMING_ROOT=%%~fI"
set "UPDATE_SCRIPT=%PIXELSTREAMING_ROOT%\SWupdate.ps1"
set "DATA_DRIVE_SCRIPT=%SCRIPT_DIR%..\powershell\ensure_data_drive.ps1"
set "UPDATE_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\invoke_update_mode.ps1"
set "PROVISIONING_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\invoke_provisioning_mode.ps1"
set "STACK_MODE=normal"
set "STACK_START_WATCHDOG=true"
set "STACK_START_UNREAL=true"
if not defined STREAMING_LANE_TAG_RETRY_COUNT set "STREAMING_LANE_TAG_RETRY_COUNT=12"
if not defined STREAMING_LANE_TAG_RETRY_DELAY_SECONDS set "STREAMING_LANE_TAG_RETRY_DELAY_SECONDS=5"
call :resolve_streaming_lane_from_instance_tag
if defined RESOLVED_STREAMING_LANE set "SCALEWORLD_STREAMING_LANE=%RESOLVED_STREAMING_LANE%"
if not defined SCALEWORLD_STREAMING_LANE set "SCALEWORLD_STREAMING_LANE=nonprod"
call :resolve_deployment_track_from_instance_tag
if defined RESOLVED_DEPLOYMENT_TRACK set "SCALEWORLD_DEPLOYMENT_TRACK=%RESOLVED_DEPLOYMENT_TRACK%"
if not defined SCALEWORLD_DEPLOYMENT_TRACK (
  if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" (
    set "SCALEWORLD_DEPLOYMENT_TRACK=prod"
  ) else (
    set "SCALEWORLD_DEPLOYMENT_TRACK=stage"
  )
)
if not defined SCALEWORLD_GIT_SYNC_MODE (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else (
    set "SCALEWORLD_GIT_SYNC_MODE=upstream"
  )
)
if not defined SCALEWORLD_GIT_TARGET_REF_PARAM (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/prod/git-target-ref"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/nonprod/git-target-ref"
  )
)
if not defined STACK_ENABLE_BOOT_GIT_SYNC (
  if /i "%SCALEWORLD_GIT_SYNC_MODE%"=="off" (
    set "STACK_ENABLE_BOOT_GIT_SYNC=false"
  ) else (
    set "STACK_ENABLE_BOOT_GIT_SYNC=true"
  )
)
if not defined STACK_LAUNCH_UNREAL_BEFORE_WILBUR set "STACK_LAUNCH_UNREAL_BEFORE_WILBUR=true"
if not defined STACK_PREPARE_DATA_DRIVE set "STACK_PREPARE_DATA_DRIVE=true"
if not defined STACK_REQUIRE_DATA_DRIVE set "STACK_REQUIRE_DATA_DRIVE=false"
if not defined STACK_ENABLE_UPDATE_MODE set "STACK_ENABLE_UPDATE_MODE=true"
if not defined STACK_ENABLE_PROVISIONING_MODE set "STACK_ENABLE_PROVISIONING_MODE=true"
if not defined SCALEWORLD_DATA_DISK_NUMBER set "SCALEWORLD_DATA_DISK_NUMBER=1"

if /i "%~1"=="--recovery" (
  set "STACK_MODE=recovery"
  set "STACK_START_WATCHDOG=false"
  shift
)

if /i "%~1"=="--validation" (
  set "STACK_MODE=validation"
  set "STACK_ENABLE_UPDATE_MODE=false"
  set "STACK_RUN_UNREAL_UPDATE_CHECK=false"
  shift
)

if not defined STACK_WATCHDOG_START_DELAY_SECONDS set "STACK_WATCHDOG_START_DELAY_SECONDS=3"
if not defined STACK_UNREAL_START_DELAY_SECONDS set "STACK_UNREAL_START_DELAY_SECONDS=1"
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
if not defined WATCHDOG_RESTART_COMMAND set "WATCHDOG_RESTART_COMMAND=""%SCRIPT_DIR%start_streamer_stack.bat"" --recovery"
if not defined WATCHDOG_TERMINATE_MATCHED_PROCESSES set "WATCHDOG_TERMINATE_MATCHED_PROCESSES=true"

if /i "%STACK_MODE%"=="recovery" set "STACK_RUN_UNREAL_UPDATE_CHECK=false"

if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_BOOT_GIT_SYNC%"=="true" (
  call :sync_repo_before_stack
  if errorlevel 1 exit /b 1
)

if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_UPDATE_MODE%"=="true" (
  if exist "%UPDATE_MODE_SCRIPT%" (
    echo Checking instance update mode...
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
  ) else (
    echo WARNING: Update mode script not found at "%UPDATE_MODE_SCRIPT%". Continuing with normal startup.
  )
)

if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_PROVISIONING_MODE%"=="true" (
  if exist "%PROVISIONING_MODE_SCRIPT%" (
    echo Checking instance provisioning mode...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PROVISIONING_MODE_SCRIPT%"
    set "PROVISIONING_MODE_EXIT=!errorlevel!"
    if not "!PROVISIONING_MODE_EXIT!"=="0" (
      echo ERROR: Provisioning mode bootstrap failed with exit code !PROVISIONING_MODE_EXIT!.
      exit /b !PROVISIONING_MODE_EXIT!
    )
  ) else (
    echo WARNING: Provisioning mode script not found at "%PROVISIONING_MODE_SCRIPT%". Continuing with normal startup.
  )
)

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
set "WILBUR_PROCESS_NAME=node.exe"
if defined WATCHDOG_WILBUR_PROCESS_NAME set "WILBUR_PROCESS_NAME=%WATCHDOG_WILBUR_PROCESS_NAME%"
set "WILBUR_COMMANDLINE_PATTERN=index.js"
if defined WATCHDOG_WILBUR_COMMANDLINE_PATTERN set "WILBUR_COMMANDLINE_PATTERN=%WATCHDOG_WILBUR_COMMANDLINE_PATTERN%"
set "WILBUR_LAUNCHER_PATTERN=start_dev_turn.bat"
set "UNREAL_PROCESS_NAME=ScaleWorld.exe"
if defined SCALEWORLD_EXECUTABLE_NAME set "UNREAL_PROCESS_NAME=%SCALEWORLD_EXECUTABLE_NAME%"
for %%I in ("%UNREAL_PROCESS_NAME%") do set "UNREAL_PROCESS_BASENAME=%%~nI"
set "UNREAL_PROCESS_NAME_PATTERN=%UNREAL_PROCESS_BASENAME%*"
set "UNREAL_LAUNCHER_PATTERN=start_unreal.bat"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$wilbur = Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq '%WILBUR_PROCESS_NAME%' -and $_.CommandLine -like '*%WILBUR_COMMANDLINE_PATTERN%*') -or ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -like '*%WILBUR_LAUNCHER_PATTERN%*') } | Select-Object -First 1; if ($wilbur) { exit 0 } else { exit 1 }"
if errorlevel 1 (
  echo Starting Wilbur in %STACK_MODE% mode...
  start "ScaleWorld Wilbur" "%SCRIPT_DIR%start_dev_turn.bat" %*
) else (
  echo Wilbur is already running or launch is already in progress. Skipping launch.
)

if /i "%STACK_START_UNREAL%"=="true" if /i "%STACK_LAUNCH_UNREAL_BEFORE_WILBUR%"=="true" (
  call :launch_unreal_if_needed
  if errorlevel 1 exit /b 1
)

if /i "%STACK_START_UNREAL%"=="true" if /i not "%STACK_LAUNCH_UNREAL_BEFORE_WILBUR%"=="true" (
  call :wait_for_wilbur_ready
  if errorlevel 1 (
    echo ERROR: Wilbur did not become ready on %STACK_WILBUR_READY_HOST%:%STACK_WILBUR_READY_PORT% within %STACK_WILBUR_READY_TIMEOUT_SECONDS% seconds.
    exit /b 1
  )

  call :launch_unreal_if_needed
  if errorlevel 1 exit /b 1
)

if /i "%STACK_START_WATCHDOG%"=="true" (
  if exist "%SCRIPT_DIR%start_watchdog.bat" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$currentPid = $PID; $watchdog = Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $currentPid -and (($_.Name -ieq 'powershell.exe' -and $_.CommandLine -like '*watchdog.ps1*') -or ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -like '*start_watchdog.bat*')) } | Select-Object -First 1; if ($watchdog) { exit 0 } else { exit 1 }"
    if errorlevel 1 (
      echo Scheduling watchdog start in %STACK_WATCHDOG_START_DELAY_SECONDS% seconds...
      start "ScaleWorld Watchdog" powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds %STACK_WATCHDOG_START_DELAY_SECONDS%; & '%SCRIPT_DIR%start_watchdog.bat'"
    ) else (
      echo Watchdog is already running or launch is already in progress. Skipping launch.
    )
  ) else (
    echo WARNING: start_watchdog.bat not found in "%SCRIPT_DIR%". Watchdog launch skipped.
  )
)

echo Stack launch completed.
exit /b 0

:sync_repo_before_stack
set "REPO_SYNC_SCRIPT=%SCRIPT_DIR%..\powershell\ensure_repo_current.ps1"

if not exist "%REPO_SYNC_SCRIPT%" (
  echo ERROR: Repo sync helper not found at "%REPO_SYNC_SCRIPT%".
  exit /b 1
)

echo Applying git sync mode "%SCALEWORLD_GIT_SYNC_MODE%" before normal startup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_SYNC_SCRIPT%" -RepoRoot "%PIXELSTREAMING_ROOT%" -Mode "startup"
if errorlevel 1 (
  echo ERROR: Boot-time repo sync failed.
  exit /b 1
)

exit /b 0

:resolve_streaming_lane_from_instance_tag
set "RESOLVED_STREAMING_LANE="
set /a STREAMING_LANE_TAG_ATTEMPT=0
set "RESOLVE_STREAMING_LANE_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_streaming_lane_from_instance_tag.ps1"

:resolve_streaming_lane_retry
set /a STREAMING_LANE_TAG_ATTEMPT+=1
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_STREAMING_LANE_SCRIPT%"`) do (
  set "RESOLVED_STREAMING_LANE=%%I"
)

if defined RESOLVED_STREAMING_LANE exit /b 0
if %STREAMING_LANE_TAG_ATTEMPT% geq %STREAMING_LANE_TAG_RETRY_COUNT% exit /b 0

echo WARNING: Failed to resolve ScaleWorldLane instance tag on attempt %STREAMING_LANE_TAG_ATTEMPT% of %STREAMING_LANE_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% seconds before falling back to default lane.
timeout /t %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_streaming_lane_retry

exit /b 0

:resolve_deployment_track_from_instance_tag
set "RESOLVED_DEPLOYMENT_TRACK="
set "RESOLVE_DEPLOYMENT_TRACK_SCRIPT=%SCRIPT_DIR%..\powershell\resolve_deployment_track_from_instance_tag.ps1"
if not exist "%RESOLVE_DEPLOYMENT_TRACK_SCRIPT%" exit /b 0

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_DEPLOYMENT_TRACK_SCRIPT%"`) do (
  set "RESOLVED_DEPLOYMENT_TRACK=%%I"
)

exit /b 0

:launch_unreal_if_needed
if exist "%SCRIPT_DIR%start_unreal.bat" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$currentPid = $PID; $unreal = Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $currentPid -and (($_.Name -like '%UNREAL_PROCESS_NAME_PATTERN%') -or ($_.Name -ieq 'cmd.exe' -and $_.CommandLine -like '*%UNREAL_LAUNCHER_PATTERN%*') -or ($_.Name -ieq 'powershell.exe' -and $_.CommandLine -like '*start_scaleworld.ps1*')) } | Select-Object -First 1; if ($unreal) { exit 0 } else { exit 1 }"
  if errorlevel 1 (
    timeout /t %STACK_UNREAL_START_DELAY_SECONDS% /nobreak >nul
    echo Starting Unreal runtime...
    call "%SCRIPT_DIR%start_unreal.bat"
    if errorlevel 1 (
      echo ERROR: Unreal launch failed.
      exit /b 1
    )
  ) else (
    echo Unreal is already running or launch is already in progress. Skipping launch.
  )
) else (
  echo WARNING: start_unreal.bat not found in "%SCRIPT_DIR%". Unreal launch skipped.
)
exit /b 0

:wait_for_wilbur_ready
echo Waiting for Wilbur readiness on %STACK_WILBUR_READY_HOST%:%STACK_WILBUR_READY_PORT%...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$hostName = '%STACK_WILBUR_READY_HOST%'; $port = %STACK_WILBUR_READY_PORT%; $deadline = (Get-Date).AddSeconds(%STACK_WILBUR_READY_TIMEOUT_SECONDS%); while ((Get-Date) -lt $deadline) { $client = $null; try { $client = New-Object System.Net.Sockets.TcpClient; $async = $client.BeginConnect($hostName, $port, $null, $null); if ($async.AsyncWaitHandle.WaitOne(1000)) { $client.EndConnect($async); $client.Close(); exit 0 } } catch { } finally { if ($client) { $client.Close() } } Start-Sleep -Milliseconds 500 } exit 1"
exit /b %errorlevel%






