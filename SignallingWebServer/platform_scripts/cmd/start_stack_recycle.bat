@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "RECYCLE_SCRIPT=%SCRIPT_DIR%..\powershell\invoke_stack_recycle.ps1"
set "SIGNALLING_ROOT=%SCRIPT_DIR%..\.."
set "RECYCLE_STATE_DIR=%SIGNALLING_ROOT%\state"
set "RECYCLE_LAUNCH_LOG=%RECYCLE_STATE_DIR%\stack-recycle-launch.log"

if not exist "%RECYCLE_STATE_DIR%" (
  mkdir "%RECYCLE_STATE_DIR%" >nul 2>&1
)

>> "%RECYCLE_LAUNCH_LOG%" echo [%DATE% %TIME%] start_stack_recycle.bat %*

if not exist "%RECYCLE_SCRIPT%" (
  >> "%RECYCLE_LAUNCH_LOG%" echo [%DATE% %TIME%] ERROR: recycle script not found at "%RECYCLE_SCRIPT%".
  exit /b 1
)

start "ScaleWorld Stack Recycle" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%RECYCLE_SCRIPT%" %*
exit /b 0
