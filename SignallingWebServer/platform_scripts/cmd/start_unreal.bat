@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "START_UNREAL_SCRIPT=%SCRIPT_DIR%..\powershell\start_scaleworld.ps1"

if not exist "%START_UNREAL_SCRIPT%" (
  echo ERROR: Unreal launcher script not found at "%START_UNREAL_SCRIPT%".
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%START_UNREAL_SCRIPT%" %*
exit /b %errorlevel%
