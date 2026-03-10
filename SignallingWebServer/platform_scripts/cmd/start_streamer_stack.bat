@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..\..") do set "PIXELSTREAMING_ROOT=%%~fI"
set "UPDATE_SCRIPT=%PIXELSTREAMING_ROOT%\SWupdate.ps1"
set "STACK_MODE=normal"
set "STACK_START_WATCHDOG=true"
set "STACK_START_UNREAL=true"

if /i "%~1"=="--recovery" (
  set "STACK_MODE=recovery"
  set "STACK_START_WATCHDOG=false"
  shift
)

if not defined STACK_WATCHDOG_START_DELAY_SECONDS set "STACK_WATCHDOG_START_DELAY_SECONDS=3"
if not defined STACK_UNREAL_START_DELAY_SECONDS set "STACK_UNREAL_START_DELAY_SECONDS=5"
if not defined STACK_RUN_UNREAL_UPDATE_CHECK set "STACK_RUN_UNREAL_UPDATE_CHECK=false"
if not defined WATCHDOG_RESTART_COMMAND set "WATCHDOG_RESTART_COMMAND=""%SCRIPT_DIR%start_streamer_stack.bat"" --recovery"
if not defined WATCHDOG_TERMINATE_MATCHED_PROCESSES set "WATCHDOG_TERMINATE_MATCHED_PROCESSES=true"

if /i "%STACK_MODE%"=="recovery" set "STACK_RUN_UNREAL_UPDATE_CHECK=false"

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
set "UNREAL_PROCESS_NAME=ScaleWorld.exe"
if defined SCALEWORLD_EXECUTABLE_NAME set "UNREAL_PROCESS_NAME=%SCALEWORLD_EXECUTABLE_NAME%"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$wilbur = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq '%WILBUR_PROCESS_NAME%' -and $_.CommandLine -like '*%WILBUR_COMMANDLINE_PATTERN%*' } | Select-Object -First 1; if ($wilbur) { exit 0 } else { exit 1 }"
if errorlevel 1 (
  echo Starting Wilbur in %STACK_MODE% mode...
  start "ScaleWorld Wilbur" "%SCRIPT_DIR%start_dev_turn.bat" %*
) else (
  echo Wilbur is already running. Skipping launch.
)

if /i "%STACK_START_UNREAL%"=="true" (
  if exist "%SCRIPT_DIR%start_unreal.bat" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$unreal = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq '%UNREAL_PROCESS_NAME%' } | Select-Object -First 1; if ($unreal) { exit 0 } else { exit 1 }"
    if errorlevel 1 (
      timeout /t %STACK_UNREAL_START_DELAY_SECONDS% /nobreak >nul
      echo Starting Unreal runtime...
      start "ScaleWorld Unreal" "%SCRIPT_DIR%start_unreal.bat"
    ) else (
      echo Unreal is already running. Skipping launch.
    )
  ) else (
    echo WARNING: start_unreal.bat not found in "%SCRIPT_DIR%". Unreal launch skipped.
  )
)

if /i "%STACK_START_WATCHDOG%"=="true" (
  if exist "%SCRIPT_DIR%start_watchdog.bat" (
    echo Scheduling watchdog start in %STACK_WATCHDOG_START_DELAY_SECONDS% seconds...
    start "ScaleWorld Watchdog" powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds %STACK_WATCHDOG_START_DELAY_SECONDS%; & '%SCRIPT_DIR%start_watchdog.bat'"
  ) else (
    echo WARNING: start_watchdog.bat not found in "%SCRIPT_DIR%". Watchdog launch skipped.
  )
)

echo Stack launch completed.
exit /b 0
