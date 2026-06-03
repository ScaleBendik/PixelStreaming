@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-for-ami-bake.ps1" -ExpectedInstanceName "ScaleWorld_s4" -UseScriptCheckoutCommit %*
exit /b %ERRORLEVEL%
