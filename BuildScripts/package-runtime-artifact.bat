@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package-runtime-artifact.ps1" %*
exit /b %ERRORLEVEL%
