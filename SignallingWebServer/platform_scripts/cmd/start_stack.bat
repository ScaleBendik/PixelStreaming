@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
echo WARNING: start_stack.bat is deprecated. Redirecting to start_streamer_stack.bat.
call "%SCRIPT_DIR%start_streamer_stack.bat" %*
exit /b %errorlevel%
