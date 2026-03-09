@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "WATCHDOG_SCRIPT=%SCRIPT_DIR%..\powershell\watchdog.ps1"

if not exist "%WATCHDOG_SCRIPT%" (
  echo ERROR: Watchdog script not found at "%WATCHDOG_SCRIPT%".
  exit /b 1
)

if not defined WATCHDOG_UNREAL_PROCESS_NAME (
  set "WATCHDOG_UNREAL_PROCESS_NAME=ScaleWorld"
)

if not defined WATCHDOG_TERMINATE_MATCHED_PROCESSES (
  set "WATCHDOG_TERMINATE_MATCHED_PROCESSES=true"
)

if not defined WATCHDOG_RESTART_COMMAND (
  set "WATCHDOG_RESTART_COMMAND=""%SCRIPT_DIR%start_streamer_stack.bat"" --recovery"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%WATCHDOG_SCRIPT%" %*
exit /b %errorlevel%
