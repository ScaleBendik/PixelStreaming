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

echo Starting Wilbur in %STACK_MODE% mode...
start "ScaleWorld Wilbur" "%SCRIPT_DIR%start_dev_turn.bat" %*

if /i "%STACK_START_UNREAL%"=="true" (
  if exist "%SCRIPT_DIR%start_unreal.bat" (
    timeout /t %STACK_UNREAL_START_DELAY_SECONDS% /nobreak >nul
    echo Starting Unreal runtime...
    start "ScaleWorld Unreal" "%SCRIPT_DIR%start_unreal.bat"
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
