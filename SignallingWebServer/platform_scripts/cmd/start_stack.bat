@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "WATCHDOG_START_DELAY_SECONDS=3"

if not exist "%SCRIPT_DIR%start_dev_turn.bat" (
  echo ERROR: start_dev_turn.bat not found in "%SCRIPT_DIR%".
  exit /b 1
)

if not exist "%SCRIPT_DIR%start_watchdog.bat" (
  echo ERROR: start_watchdog.bat not found in "%SCRIPT_DIR%".
  exit /b 1
)

echo Scheduling watchdog start in %WATCHDOG_START_DELAY_SECONDS% seconds...
start "ScaleWorld Watchdog" cmd /c "timeout /t %WATCHDOG_START_DELAY_SECONDS% /nobreak >nul && call \"%SCRIPT_DIR%start_watchdog.bat\""

echo Starting Wilbur...
call "%SCRIPT_DIR%start_dev_turn.bat" %*
exit /b %errorlevel%

