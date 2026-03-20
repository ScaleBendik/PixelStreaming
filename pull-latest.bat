@echo off
setlocal

call "%~dp0BuildScripts\pull-latest.bat" %*
exit /b %errorlevel%
