@echo off
setlocal

call "%~dp0BuildScripts\build-all.bat" %*
exit /b %errorlevel%
