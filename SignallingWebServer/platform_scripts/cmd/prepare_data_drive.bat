@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\ensure_data_drive.ps1" %*
exit /b %errorlevel%
