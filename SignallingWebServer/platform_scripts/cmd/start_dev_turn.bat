@echo off
setlocal

set "ROOT=C:\PixelStreaming\PixelStreaming\SignallingWebServer"
set "REGION=eu-north-1"
set "TURN_USER_PARAM=/pixelstreaming/turn/username"
set "TURN_CREDENTIAL_PARAM=/pixelstreaming/turn/credential"
set "AWS_EXE=aws"
set "CONNECT_TICKET_AUTH_MODE=soft"
set "CONNECT_TICKET_ISSUER=scaleworld-dev-connect-ticket"
set "CONNECT_TICKET_AUDIENCE=scaleworld-pixelstreaming"
set "CONNECT_TICKET_SIGNING_KEY=sw-dev-ct-20260305-jvL9N8kQ2mH4rT6yU1pW3sX5cV7bN9fK2dG4hJ6k"
set "CONNECT_TICKET_ROUTE_HOST_SUFFIX=stream.scaleworld.net"

where aws >nul 2>nul
if errorlevel 1 (
  if exist "C:\Program Files\Amazon\AWSCLIV2\aws.exe" (
    set "AWS_EXE=C:\Program Files\Amazon\AWSCLIV2\aws.exe"
  ) else if exist "C:\Program Files\Amazon\AWSCLI\bin\aws.exe" (
    set "AWS_EXE=C:\Program Files\Amazon\AWSCLI\bin\aws.exe"
  ) else (
    echo ERROR: AWS CLI not found in PATH or standard install directories.
    exit /b 1
  )
)

echo Using AWS CLI: "%AWS_EXE%"

set "AWS_CALL=aws"
if /i not "%AWS_EXE%"=="aws" (
  set "AWS_CALL="%AWS_EXE%""
)

set "TURN_USERNAME="
for /f "usebackq delims=" %%I in (`%AWS_CALL% ssm get-parameter --name "%TURN_USER_PARAM%" --with-decryption --region "%REGION%" --query Parameter.Value --output text`) do (
  set "TURN_USERNAME=%%I"
)

set "TURN_CREDENTIAL="
for /f "usebackq delims=" %%I in (`%AWS_CALL% ssm get-parameter --name "%TURN_CREDENTIAL_PARAM%" --with-decryption --region "%REGION%" --query Parameter.Value --output text`) do (
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

set "INSTANCE_ID="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='21600'}; $iid = Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{'X-aws-ec2-metadata-token'=$token}; Write-Output $iid } catch { }"`) do (
  set "INSTANCE_ID=%%I"
)

if not defined INSTANCE_ID (
  echo WARNING: Failed to read EC2 instance id from IMDSv2 metadata endpoint.
  echo WARNING: Starting Wilbur with ticket auth disabled for this run.
  set "CONNECT_TICKET_AUTH_MODE=off"
) else (
  echo Detected EC2 instance id: %INSTANCE_ID%
)

cd /d "%ROOT%\platform_scripts\cmd"

call start.bat -- ^
  --peer_options_player_file="%ROOT%\peer_options.player.json" ^
  --peer_options_streamer_file="%ROOT%\peer_options.streamer.json" ^
  --auth_mode="%CONNECT_TICKET_AUTH_MODE%" ^
  --auth_issuer="%CONNECT_TICKET_ISSUER%" ^
  --auth_audience="%CONNECT_TICKET_AUDIENCE%" ^
  --auth_signing_key="%CONNECT_TICKET_SIGNING_KEY%" ^
  --auth_instance_id="%INSTANCE_ID%" ^
  --auth_route_host_suffix="%CONNECT_TICKET_ROUTE_HOST_SUFFIX%"
