@echo off
setlocal

set "ROOT=C:\PixelStreaming\PixelStreaming\SignallingWebServer"
set "REGION=eu-north-1"
set "TURN_USER_PARAM=/pixelstreaming/turn/username"
set "TURN_CREDENTIAL_PARAM=/pixelstreaming/turn/credential"
set "AWS_EXE=aws"
set "ENABLE_GIT_SYNC_BEFORE_START=false"
set "CONNECT_TICKET_AUTH_MODE=enforce"
set "CONNECT_TICKET_ISSUER=scaleworld-dev-connect-ticket"
set "CONNECT_TICKET_AUDIENCE=scaleworld-pixelstreaming"
set "CONNECT_TICKET_SIGNING_KEY=sw-dev-ct-20260305-jvL9N8kQ2mH4rT6yU1pW3sX5cV7bN9fK2dG4hJ6k"
set "CONNECT_TICKET_ROUTE_HOST_SUFFIX=stream.scaleworld.net"
if not defined PLAYER_KEEPALIVE set "PLAYER_KEEPALIVE=true"
if not defined PLAYER_KEEPALIVE_INTERVAL_MS set "PLAYER_KEEPALIVE_INTERVAL_MS=30000"
if not defined PLAYER_KEEPALIVE_MAX_MISSED_PONGS set "PLAYER_KEEPALIVE_MAX_MISSED_PONGS=2"
if not defined VIEWER_IDLE_STOP set "VIEWER_IDLE_STOP=true"
if not defined VIEWER_IDLE_GRACE_MS set "VIEWER_IDLE_GRACE_MS=900000"
if not defined VIEWER_IDLE_FIRST_VIEWER_GRACE_MS set "VIEWER_IDLE_FIRST_VIEWER_GRACE_MS=3600000"
if not defined VIEWER_IDLE_FIRST_VIEWER_DELAY_MS set "VIEWER_IDLE_FIRST_VIEWER_DELAY_MS=0"
if not defined VIEWER_IDLE_STOP_RETRY_MS set "VIEWER_IDLE_STOP_RETRY_MS=60000"
if not defined VIEWER_IDLE_STOP_DRY_RUN set "VIEWER_IDLE_STOP_DRY_RUN=false"

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

if /i "%ENABLE_GIT_SYNC_BEFORE_START%"=="true" (
  call :sync_repo_and_build
  if errorlevel 1 exit /b 1
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
  --auth_route_host_suffix="%CONNECT_TICKET_ROUTE_HOST_SUFFIX%" ^
  --player_keepalive="%PLAYER_KEEPALIVE%" ^
  --player_keepalive_interval_ms="%PLAYER_KEEPALIVE_INTERVAL_MS%" ^
  --player_keepalive_max_missed_pongs="%PLAYER_KEEPALIVE_MAX_MISSED_PONGS%" ^
  --viewer_idle_stop="%VIEWER_IDLE_STOP%" ^
  --viewer_idle_grace_ms="%VIEWER_IDLE_GRACE_MS%" ^
  --viewer_idle_first_viewer_grace_ms="%VIEWER_IDLE_FIRST_VIEWER_GRACE_MS%" ^
  --viewer_idle_first_viewer_delay_ms="%VIEWER_IDLE_FIRST_VIEWER_DELAY_MS%" ^
  --viewer_idle_stop_retry_ms="%VIEWER_IDLE_STOP_RETRY_MS%" ^
  --viewer_idle_stop_dry_run="%VIEWER_IDLE_STOP_DRY_RUN%"

exit /b %errorlevel%

:sync_repo_and_build
for %%I in ("%ROOT%\..") do set "REPO_ROOT=%%~fI"

where git >nul 2>nul
if errorlevel 1 (
  echo ERROR: Git not found in PATH while ENABLE_GIT_SYNC_BEFORE_START=true.
  exit /b 1
)

pushd "%REPO_ROOT%"

echo Checking PixelStreaming repo for remote updates...
git fetch --prune
if errorlevel 1 (
  echo ERROR: git fetch failed.
  popd
  exit /b 1
)

set "UPSTREAM_BRANCH="
for /f "usebackq delims=" %%I in (`git rev-parse --abbrev-ref --symbolic-full-name @{u} 2^>nul`) do (
  set "UPSTREAM_BRANCH=%%I"
)

if not defined UPSTREAM_BRANCH (
  echo WARNING: No upstream branch configured. Skipping git pull/build step.
  popd
  exit /b 0
)

set "REMOTE_UPDATES=0"
for /f "usebackq delims=" %%I in (`git rev-list --count HEAD..@{u}`) do (
  set "REMOTE_UPDATES=%%I"
)

if "%REMOTE_UPDATES%"=="0" (
  echo No remote updates detected on %UPSTREAM_BRANCH%.
  popd
  exit /b 0
)

echo %REMOTE_UPDATES% remote update^(s^) detected on %UPSTREAM_BRANCH%. Pulling latest changes...
git pull --ff-only
if errorlevel 1 (
  echo ERROR: git pull --ff-only failed.
  popd
  exit /b 1
)

echo Running build-all.bat after git update...
call "%REPO_ROOT%\build-all.bat"
if errorlevel 1 (
  echo ERROR: build-all.bat failed.
  popd
  exit /b 1
)

popd
exit /b 0
