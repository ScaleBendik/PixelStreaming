@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-runtime-artifact.ps1" %*
exit /b %errorlevel%
