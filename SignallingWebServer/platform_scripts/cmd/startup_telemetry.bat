@echo off
rem Diagnostics only. Phase calls preserve the caller's ERRORLEVEL and use no
rem additional process. Begin/End failures must never change startup behavior.
if /i "%~1"=="begin" goto begin
if /i "%~1"=="end" goto end
set "SW_TELEMETRY_SAVED_EXIT=%errorlevel%"
if defined SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE (
  >>"%SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE%" echo %~2^|%TIME%^|%~3
) 2>nul
exit /b %SW_TELEMETRY_SAVED_EXIT%

:begin
set "SCALEWORLD_STARTUP_TELEMETRY_CONTEXT_ID="
set "SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE="
set "SCALEWORLD_STARTUP_TELEMETRY_LAUNCHER_PID="
if not defined SCALEWORLD_STARTUP_TELEMETRY_ENABLED set "SCALEWORLD_STARTUP_TELEMETRY_ENABLED=true"
if /i not "%SCALEWORLD_STARTUP_TELEMETRY_ENABLED%"=="true" if not "%SCALEWORLD_STARTUP_TELEMETRY_ENABLED%"=="1" exit /b 0
if not exist "%~dp0..\powershell\startup_telemetry_command.ps1" exit /b 0
for /f "usebackq tokens=1,* delims==" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\powershell\startup_telemetry_command.ps1" -Action Begin -Role "%~2" -Mode "%~3" 2^>nul`) do (
  if "%%I"=="SCALEWORLD_STARTUP_TELEMETRY_LAUNCH_ID" set "SCALEWORLD_STARTUP_TELEMETRY_LAUNCH_ID=%%J"
  if "%%I"=="SCALEWORLD_STARTUP_TELEMETRY_CONTEXT_ID" set "SCALEWORLD_STARTUP_TELEMETRY_CONTEXT_ID=%%J"
  if "%%I"=="SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE" set "SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE=%%J"
  if "%%I"=="SCALEWORLD_STARTUP_TELEMETRY_LAUNCHER_PID" set "SCALEWORLD_STARTUP_TELEMETRY_LAUNCHER_PID=%%J"
)
if not defined SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE set "SCALEWORLD_STARTUP_TELEMETRY_LAUNCH_ID="
exit /b 0

:end
set "SW_TELEMETRY_SAVED_EXIT=%errorlevel%"
if defined SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE if exist "%~dp0..\powershell\startup_telemetry_command.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\powershell\startup_telemetry_command.ps1" -Action End -ResultCode %~2 >nul 2>nul
)
exit /b %SW_TELEMETRY_SAVED_EXIT%
