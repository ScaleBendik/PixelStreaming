@echo off
setlocal

powershell -ExecutionPolicy Bypass -File "%~dp0build-all.ps1"
exit /b %errorlevel%
