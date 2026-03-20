@echo off
setlocal

powershell -ExecutionPolicy Bypass -File "%~dp0..\promote-prod-streamer-release.ps1" %*
exit /b %errorlevel%
