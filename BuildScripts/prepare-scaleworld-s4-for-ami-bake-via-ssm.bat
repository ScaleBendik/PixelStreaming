@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-scaleworld-s4-for-ami-bake-via-ssm.ps1" %*
set EXIT_CODE=%ERRORLEVEL%

echo.
if %EXIT_CODE% NEQ 0 (
  echo ScaleWorld_s4 SSM AMI bake preparation failed with exit code %EXIT_CODE%.
) else (
  echo ScaleWorld_s4 SSM AMI bake preparation completed.
)

pause
exit /b %EXIT_CODE%
