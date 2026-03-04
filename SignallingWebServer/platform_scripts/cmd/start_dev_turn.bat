@echo off
setlocal enabledelayedexpansion

set "ROOT=C:\PixelStreaming\PixelStreaming\SignallingWebServer"
set "REGION=eu-north-1"
set "TURN_USER_PARAM=/pixelstreaming/turn/username"
set "TURN_CREDENTIAL_PARAM=/pixelstreaming/turn/credential"
set "AWS_EXE=aws"

where aws >nul 2>nul
if errorlevel 1 (
  set "AWS_EXE=C:\Program Files\Amazon\AWSCLIV2\aws.exe"
)

if /i not "%AWS_EXE%"=="aws" (
  if not exist "%AWS_EXE%" (
    echo ERROR: AWS CLI not found at "%AWS_EXE%".
    exit /b 1
  )
)

set "TURN_USERNAME="
for /f "usebackq delims=" %%I in (`"%AWS_EXE%" ssm get-parameter --name "%TURN_USER_PARAM%" --with-decryption --region "%REGION%" --query Parameter.Value --output text 2^>nul`) do (
  set "TURN_USERNAME=%%I"
)

set "TURN_CREDENTIAL="
for /f "usebackq delims=" %%I in (`"%AWS_EXE%" ssm get-parameter --name "%TURN_CREDENTIAL_PARAM%" --with-decryption --region "%REGION%" --query Parameter.Value --output text 2^>nul`) do (
  set "TURN_CREDENTIAL=%%I"
)

if not defined TURN_USERNAME (
  echo ERROR: Failed to load TURN username from SSM parameter "%TURN_USER_PARAM%".
  exit /b 1
)

if not defined TURN_CREDENTIAL (
  echo ERROR: Failed to load TURN credential from SSM parameter "%TURN_CREDENTIAL_PARAM%".
  exit /b 1
)

echo Loaded TURN credentials from SSM parameter store.

cd /d "%ROOT%\platform_scripts\cmd"

call start.bat -- ^
  --peer_options_player_file="%ROOT%\peer_options.player.json" ^
  --peer_options_streamer_file="%ROOT%\peer_options.streamer.json"
