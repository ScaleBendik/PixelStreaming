@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..\..") do set "PIXELSTREAMING_ROOT=%%~fI"
set "UPDATE_SCRIPT=%PIXELSTREAMING_ROOT%\SWupdate.ps1"

if exist "%SCRIPT_DIR%prepare_data_drive.bat" (
  call "%SCRIPT_DIR%prepare_data_drive.bat" -SkipIfUnavailable
)

if not exist "%UPDATE_SCRIPT%" (
  echo ERROR: Update script not found at "%UPDATE_SCRIPT%".
  exit /b 1
)

echo Running manual Unreal update test...
powershell -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_SCRIPT%" %*
exit /b %errorlevel%
