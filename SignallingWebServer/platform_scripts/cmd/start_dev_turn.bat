@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%\..\..") do set "ROOT=%%~fI"
if defined SCALEWORLD_WILBUR_ROOT set "ROOT=%SCALEWORLD_WILBUR_ROOT%"
if not defined SCALEWORLD_INSTALL_BASE set "SCALEWORLD_INSTALL_BASE=C:\PixelStreaming"
for %%I in ("%SCALEWORLD_INSTALL_BASE%\PixelStreamingRuntime") do set "SCALEWORLD_ACTIVE_RUNTIME_ROOT=%%~fI"
set "ACTIVE_RUNTIME_WILBUR_LAUNCHER=%SCALEWORLD_ACTIVE_RUNTIME_ROOT%\SignallingWebServer\platform_scripts\cmd\start_dev_turn.bat"
set "NORMALIZE_DELIVERY_MODE_SCRIPT=%ROOT%\SignallingWebServer\platform_scripts\powershell\normalize_pixelstreaming_delivery_mode.ps1"
set "RESOLVE_DELIVERY_MODE_SCRIPT=%ROOT%\SignallingWebServer\platform_scripts\powershell\resolve_pixelstreaming_delivery_mode_from_instance_tag.ps1"
set "ACTIVE_RUNTIME_WILBUR_DELEGATED=false"
call :delegate_to_active_runtime_if_required %*
set "ACTIVE_RUNTIME_WILBUR_DELEGATE_EXIT=%errorlevel%"
if /i "%ACTIVE_RUNTIME_WILBUR_DELEGATED%"=="true" exit /b %ACTIVE_RUNTIME_WILBUR_DELEGATE_EXIT%
if not "%ACTIVE_RUNTIME_WILBUR_DELEGATE_EXIT%"=="0" exit /b %ACTIVE_RUNTIME_WILBUR_DELEGATE_EXIT%
set "REGION=eu-north-1"
if not defined STREAMING_LANE_TAG_RETRY_COUNT set "STREAMING_LANE_TAG_RETRY_COUNT=12"
if not defined STREAMING_LANE_TAG_RETRY_DELAY_SECONDS set "STREAMING_LANE_TAG_RETRY_DELAY_SECONDS=5"
if not defined DEPLOYMENT_TRACK_TAG_RETRY_COUNT set "DEPLOYMENT_TRACK_TAG_RETRY_COUNT=%STREAMING_LANE_TAG_RETRY_COUNT%"
if not defined DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS set "DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS=%STREAMING_LANE_TAG_RETRY_DELAY_SECONDS%"
call :resolve_streaming_lane_from_instance_tag
if errorlevel 1 exit /b 1
if defined RESOLVED_STREAMING_LANE set "SCALEWORLD_STREAMING_LANE=%RESOLVED_STREAMING_LANE%"
if not defined SCALEWORLD_STREAMING_LANE set "SCALEWORLD_STREAMING_LANE=nonprod"
call :resolve_deployment_track_from_instance_tag
if errorlevel 1 exit /b 1
if defined RESOLVED_DEPLOYMENT_TRACK set "SCALEWORLD_DEPLOYMENT_TRACK=%RESOLVED_DEPLOYMENT_TRACK%"
if not defined SCALEWORLD_DEPLOYMENT_TRACK (
  if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" (
    set "SCALEWORLD_DEPLOYMENT_TRACK=prod"
  ) else (
    set "SCALEWORLD_DEPLOYMENT_TRACK=stage"
  )
)
if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" goto apply_streaming_lane_prod
if /i "%SCALEWORLD_STREAMING_LANE%"=="nonprod" goto apply_streaming_lane_nonprod
echo ERROR: Unsupported SCALEWORLD_STREAMING_LANE "%SCALEWORLD_STREAMING_LANE%". Expected nonprod or prod.
exit /b 1

:apply_streaming_lane_nonprod
if not defined TURN_USER_PARAM set "TURN_USER_PARAM=/pixelstreaming/turn/username"
if not defined TURN_CREDENTIAL_PARAM set "TURN_CREDENTIAL_PARAM=/pixelstreaming/turn/credential"
if not defined CONNECT_TICKET_SIGNING_KEY_PARAM set "CONNECT_TICKET_SIGNING_KEY_PARAM=/pixelstreaming/connect-ticket/signing-key"
if not defined CONNECT_TICKET_ISSUER set "CONNECT_TICKET_ISSUER=scaleworld-dev-connect-ticket"
goto after_streaming_lane_defaults

:apply_streaming_lane_prod
if not defined TURN_USER_PARAM set "TURN_USER_PARAM=/pixelstreaming/turn/username"
if not defined TURN_CREDENTIAL_PARAM set "TURN_CREDENTIAL_PARAM=/pixelstreaming/turn/credential"
if not defined CONNECT_TICKET_SIGNING_KEY_PARAM set "CONNECT_TICKET_SIGNING_KEY_PARAM=/pixelstreaming/prod/connect-ticket/signing-key"
if not defined CONNECT_TICKET_ISSUER set "CONNECT_TICKET_ISSUER=scaleworld-prod-connect-ticket"
goto after_streaming_lane_defaults

:after_streaming_lane_defaults
set "AWS_EXE=aws"
set "ENABLE_GIT_SYNC_BEFORE_START=false"
set "DISCARD_LOCAL_GIT_CHANGES_ON_SYNC=true"
set "REQUIRE_EC2_INSTANCE_FOR_GIT_SYNC=true"
if not defined SCALEWORLD_GIT_SYNC_MODE (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else (
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  )
)
if /i "%SCALEWORLD_GIT_SYNC_MODE%"=="upstream" (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    echo WARNING: Prod deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/prod/git-target-ref controls startup.
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    echo WARNING: Stage deployment track cannot use upstream git sync. Forcing pinned mode so /pixelstreaming/stage/git-target-ref controls startup.
    set "SCALEWORLD_GIT_SYNC_MODE=pinned"
  )
)
if not defined SCALEWORLD_GIT_TARGET_REF_PARAM (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/prod/git-target-ref"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/stage/git-target-ref;/pixelstreaming/nonprod/git-target-ref"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/dev/git-target-ref;/pixelstreaming/nonprod/git-target-ref"
  ) else (
    set "SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/nonprod/git-target-ref"
  )
)
set "RUNTIME_STATUS_ENABLED=true"
if not defined STARTUP_RUNTIME_STATUS_HEARTBEAT_INTERVAL_SECONDS set "STARTUP_RUNTIME_STATUS_HEARTBEAT_INTERVAL_SECONDS=30"
if not defined IMDS_INSTANCE_ID_RETRY_COUNT set "IMDS_INSTANCE_ID_RETRY_COUNT=12"
if not defined IMDS_INSTANCE_ID_RETRY_DELAY_SECONDS set "IMDS_INSTANCE_ID_RETRY_DELAY_SECONDS=5"
set "CONNECT_TICKET_AUTH_MODE=enforce"
set "CONNECT_TICKET_AUDIENCE=scaleworld-pixelstreaming"
if not defined CONNECT_TICKET_SIGNING_KEY set "CONNECT_TICKET_SIGNING_KEY="
set "CONNECT_TICKET_ROUTE_HOST_SUFFIX=stream.scaleworld.net"
if not defined ENABLE_REVERSE_PROXY set "ENABLE_REVERSE_PROXY=true"
if not defined REVERSE_PROXY_NUM_PROXIES set "REVERSE_PROXY_NUM_PROXIES=1"
if not defined PLAYER_KEEPALIVE set "PLAYER_KEEPALIVE=true"
if not defined PLAYER_KEEPALIVE_INTERVAL_MS set "PLAYER_KEEPALIVE_INTERVAL_MS=30000"
if not defined PLAYER_KEEPALIVE_MAX_MISSED_PONGS set "PLAYER_KEEPALIVE_MAX_MISSED_PONGS=2"
if not defined VIEWER_IDLE_STOP set "VIEWER_IDLE_STOP=true"
if not defined VIEWER_IDLE_GRACE_MS set "VIEWER_IDLE_GRACE_MS=300000"
if not defined VIEWER_IDLE_FIRST_VIEWER_GRACE_MS set "VIEWER_IDLE_FIRST_VIEWER_GRACE_MS=600000"
if not defined VIEWER_IDLE_FIRST_VIEWER_DELAY_MS set "VIEWER_IDLE_FIRST_VIEWER_DELAY_MS=0"
if not defined VIEWER_IDLE_STOP_RETRY_MS set "VIEWER_IDLE_STOP_RETRY_MS=60000"
if not defined VIEWER_IDLE_STOP_DRY_RUN set "VIEWER_IDLE_STOP_DRY_RUN=false"
if not defined INSTANCE_AGENT_API_BASE_URL set "INSTANCE_AGENT_API_BASE_URL="
if not defined INSTANCE_AGENT_API_BASE_URL_PARAM (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "INSTANCE_AGENT_API_BASE_URL_PARAM=/pixelstreaming/prod/instance-agent-api-base-url"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "INSTANCE_AGENT_API_BASE_URL_PARAM=/pixelstreaming/stage/instance-agent-api-base-url"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "INSTANCE_AGENT_API_BASE_URL_PARAM=/pixelstreaming/dev/instance-agent-api-base-url"
    if not defined INSTANCE_AGENT_API_BASE_URL_FALLBACK_PARAM set "INSTANCE_AGENT_API_BASE_URL_FALLBACK_PARAM=/pixelstreaming/nonprod/instance-agent-api-base-url"
  ) else if /i "%SCALEWORLD_STREAMING_LANE%"=="nonprod" (
    set "INSTANCE_AGENT_API_BASE_URL_PARAM=/pixelstreaming/nonprod/instance-agent-api-base-url"
  )
)
if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV set "INSTANCE_AGENT_CONTROL_PLANE_ENV="
if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM (
  if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/prod/instance-agent-control-plane-env"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/stage/instance-agent-control-plane-env"
  ) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/dev/instance-agent-control-plane-env"
    if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV_FALLBACK_PARAM set "INSTANCE_AGENT_CONTROL_PLANE_ENV_FALLBACK_PARAM=/pixelstreaming/nonprod/instance-agent-control-plane-env"
  ) else if /i "%SCALEWORLD_STREAMING_LANE%"=="nonprod" (
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM=/pixelstreaming/nonprod/instance-agent-control-plane-env"
  )
)
if not defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET="
if not defined INSTANCE_AGENT_INSTANCE_ID set "INSTANCE_AGENT_INSTANCE_ID="
if not defined INSTANCE_AGENT_REGION set "INSTANCE_AGENT_REGION="
if not defined INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF set "INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF=false"
if not defined INSTANCE_AGENT_LANE set "INSTANCE_AGENT_LANE=%SCALEWORLD_STREAMING_LANE%"
if not defined INSTANCE_AGENT_ROUTE_KEY set "INSTANCE_AGENT_ROUTE_KEY="
if not defined INSTANCE_AGENT_SCOPE_VALUE set "INSTANCE_AGENT_SCOPE_VALUE="
if not defined INSTANCE_AGENT_VERSION set "INSTANCE_AGENT_VERSION="
if not defined INSTANCE_AGENT_RUNTIME_VERSION set "INSTANCE_AGENT_RUNTIME_VERSION="
if not defined INSTANCE_AGENT_HEARTBEAT_MS set "INSTANCE_AGENT_HEARTBEAT_MS="
if not defined INSTANCE_AGENT_DESIRED_STATE_PATH set "INSTANCE_AGENT_DESIRED_STATE_PATH=C:\PixelStreaming\state\instance-agent-desired-state.json"
if not defined INSTANCE_AGENT_ARTIFACT_BUCKET set "INSTANCE_AGENT_ARTIFACT_BUCKET="
if not defined INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM (
  if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" (
    set "INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM=/pixelstreaming/prod/session-log-artifact-bucket"
  ) else if /i "%SCALEWORLD_STREAMING_LANE%"=="nonprod" (
    set "INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM=/pixelstreaming/nonprod/session-log-artifact-bucket"
  )
)
if not defined INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED set "INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED="
if not defined INSTANCE_AGENT_ARTIFACT_PREFIX set "INSTANCE_AGENT_ARTIFACT_PREFIX=PixelStreamingLogs/%SCALEWORLD_STREAMING_LANE%/%SCALEWORLD_DEPLOYMENT_TRACK%"
if not defined INSTANCE_AGENT_ARTIFACT_QUEUE_PATH set "INSTANCE_AGENT_ARTIFACT_QUEUE_PATH=C:\PixelStreaming\state\session-artifact-queue"
if not defined INSTANCE_AGENT_ARTIFACT_MAX_BYTES set "INSTANCE_AGENT_ARTIFACT_MAX_BYTES=2097152"
if not defined INSTANCE_AGENT_ARTIFACT_UNREAL_LOG_DIRECTORY set "INSTANCE_AGENT_ARTIFACT_UNREAL_LOG_DIRECTORY="
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_PREFIX set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_PREFIX=PixelStreamingScreenshots/%SCALEWORLD_STREAMING_LANE%/%SCALEWORLD_DEPLOYMENT_TRACK%"
if not defined INSTANCE_AGENT_SCREENSHOT_SOURCE_FOLDER set "INSTANCE_AGENT_SCREENSHOT_SOURCE_FOLDER="
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_QUEUE_PATH set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_QUEUE_PATH=C:\PixelStreaming\state\session-screenshot-artifact-queue"
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_FILES set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_FILES=250"
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_BYTES set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_BYTES=104857600"
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS=3"
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_SETTLE_DELAY_MS set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_SETTLE_DELAY_MS=1000"

set "INSTANCE_ID="
set "STARTUP_HEARTBEAT_STATE_FILE="
set "STARTUP_HEARTBEAT_STOP_FILE="
if not defined CURRENT_RELEASE_STATE_PATH set "CURRENT_RELEASE_STATE_PATH=C:\PixelStreaming\state\current-release.json"

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
echo Using streaming lane: "%SCALEWORLD_STREAMING_LANE%"
echo Using deployment track: "%SCALEWORLD_DEPLOYMENT_TRACK%"

set "AWS_CALL=aws"
if /i not "%AWS_EXE%"=="aws" (
  set "AWS_CALL="%AWS_EXE%""
)

set "TURN_USERNAME="
set "TURN_CREDENTIAL="
call :load_runtime_parameters
if errorlevel 1 exit /b 1
call :resolve_instance_agent_control_plane_env
if errorlevel 1 exit /b 1
call :apply_instance_agent_control_plane_defaults
if errorlevel 1 exit /b 1
call :load_instance_agent_bootstrap_shared_secret
if errorlevel 1 exit /b 1

if not defined TURN_USERNAME (
  echo ERROR: Failed to load TURN username from SSM parameter "%TURN_USER_PARAM%".
  exit /b 1
)

if not defined TURN_CREDENTIAL (
  echo ERROR: Failed to load TURN credential from SSM parameter "%TURN_CREDENTIAL_PARAM%".
  exit /b 1
)

echo Loaded TURN credentials from SSM parameter store.

if /i not "%CONNECT_TICKET_AUTH_MODE%"=="off" (
  if not defined CONNECT_TICKET_SIGNING_KEY (
    echo ERROR: Failed to load connect-ticket signing key from SSM parameter "%CONNECT_TICKET_SIGNING_KEY_PARAM%".
    exit /b 1
  )

  echo Loaded connect-ticket signing key from SSM parameter store.
)

set /a IMDS_INSTANCE_ID_ATTEMPT=0

:read_instance_id_retry
set /a IMDS_INSTANCE_ID_ATTEMPT+=1
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='21600'}; $iid = Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{'X-aws-ec2-metadata-token'=$token}; Write-Output $iid } catch { }"`) do (
  set "INSTANCE_ID=%%I"
)

if defined INSTANCE_ID (
  echo Detected EC2 instance id: %INSTANCE_ID%
  if exist "%ROOT%\platform_scripts\powershell\publish_current_build_tags.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\platform_scripts\powershell\publish_current_build_tags.ps1" -InstanceId "%INSTANCE_ID%" -Region "%REGION%" -AwsCliPath "%AWS_EXE%" -CurrentReleaseStatePath "%CURRENT_RELEASE_STATE_PATH%"
    if errorlevel 2 (
      echo WARNING: Current build metadata was not available for tag publish.
    ) else if errorlevel 1 (
      echo WARNING: Failed to publish current build metadata tags.
    )
  )
  goto after_instance_id
)

if %IMDS_INSTANCE_ID_ATTEMPT% geq %IMDS_INSTANCE_ID_RETRY_COUNT% goto instance_id_failed

echo WARNING: Failed to read EC2 instance id from IMDSv2 metadata endpoint on attempt %IMDS_INSTANCE_ID_ATTEMPT% of %IMDS_INSTANCE_ID_RETRY_COUNT%.
echo WARNING: Retrying in %IMDS_INSTANCE_ID_RETRY_DELAY_SECONDS% seconds...
timeout /t %IMDS_INSTANCE_ID_RETRY_DELAY_SECONDS% /nobreak >nul
goto read_instance_id_retry

:instance_id_failed
if /i "%CONNECT_TICKET_AUTH_MODE%"=="off" (
  echo WARNING: Failed to read EC2 instance id from IMDSv2 metadata endpoint after %IMDS_INSTANCE_ID_RETRY_COUNT% attempts.
  echo WARNING: CONNECT_TICKET_AUTH_MODE=off, continuing without instance id.
) else (
  echo ERROR: Failed to read EC2 instance id from IMDSv2 metadata endpoint after %IMDS_INSTANCE_ID_RETRY_COUNT% attempts.
  echo ERROR: Refusing to start Wilbur with ticket auth enabled and no instance id.
  exit /b 1
)

:after_instance_id
call :apply_instance_agent_defaults
call :reset_startup_heartbeat
call :set_runtime_status "booting" "startup-script" "startup_sequence"
call :start_startup_heartbeat

if /i "%ENABLE_GIT_SYNC_BEFORE_START%"=="true" (
  if /i "%REQUIRE_EC2_INSTANCE_FOR_GIT_SYNC%"=="true" if not defined INSTANCE_ID (
    echo WARNING: ENABLE_GIT_SYNC_BEFORE_START is true, but no EC2 instance id was detected.
    echo WARNING: Skipping git sync to avoid wiping local workstation changes.
    goto continue_start
  )

  call :sync_repo_and_build
  if errorlevel 1 exit /b 1
)

:continue_start
call :stop_startup_heartbeat
call :set_runtime_status "waiting_for_streamer" "startup-script" "signalling_server_starting"
cd /d "%ROOT%\platform_scripts\cmd"

if /i "%ENABLE_REVERSE_PROXY%"=="true" goto start_signalling_with_reverse_proxy

call start.bat -- ^
  --peer_options_player_file="%ROOT%\peer_options.player.json" ^
  --peer_options_streamer_file="%ROOT%\peer_options.streamer.json" ^
  --auth_mode="%CONNECT_TICKET_AUTH_MODE%" ^
  --player_keepalive="%PLAYER_KEEPALIVE%" ^
  --player_keepalive_interval_ms="%PLAYER_KEEPALIVE_INTERVAL_MS%" ^
  --player_keepalive_max_missed_pongs="%PLAYER_KEEPALIVE_MAX_MISSED_PONGS%" ^
  --viewer_idle_stop="%VIEWER_IDLE_STOP%" ^
  --viewer_idle_grace_ms="%VIEWER_IDLE_GRACE_MS%" ^
  --viewer_idle_first_viewer_grace_ms="%VIEWER_IDLE_FIRST_VIEWER_GRACE_MS%" ^
  --viewer_idle_first_viewer_delay_ms="%VIEWER_IDLE_FIRST_VIEWER_DELAY_MS%" ^
  --viewer_idle_stop_retry_ms="%VIEWER_IDLE_STOP_RETRY_MS%" ^
  --viewer_idle_stop_dry_run="%VIEWER_IDLE_STOP_DRY_RUN%" ^
  --runtime_status="%RUNTIME_STATUS_ENABLED%" ^
  --runtime_status_aws_cli_path="%AWS_EXE%" ^
  --runtime_status_source="signalling-server" ^
  --instance_agent="%INSTANCE_AGENT%" ^
  --instance_agent_api_base_url="%INSTANCE_AGENT_API_BASE_URL%" ^
  --instance_agent_bootstrap_shared_secret="%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET%" ^
  --instance_agent_instance_id="%INSTANCE_AGENT_INSTANCE_ID%" ^
  --instance_agent_region="%INSTANCE_AGENT_REGION%" ^
  --instance_agent_require_identity_proof="%INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF%" ^
  --instance_agent_lane="%INSTANCE_AGENT_LANE%" ^
  --instance_agent_route_key="%INSTANCE_AGENT_ROUTE_KEY%" ^
  --instance_agent_scope_value="%INSTANCE_AGENT_SCOPE_VALUE%" ^
  --instance_agent_version="%INSTANCE_AGENT_VERSION%" ^
  --instance_agent_runtime_version="%INSTANCE_AGENT_RUNTIME_VERSION%" ^
  --instance_agent_heartbeat_ms="%INSTANCE_AGENT_HEARTBEAT_MS%" ^
  --instance_agent_desired_state_path="%INSTANCE_AGENT_DESIRED_STATE_PATH%" ^
  --instance_agent_artifact_upload_enabled="%INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED%" ^
  --instance_agent_artifact_bucket="%INSTANCE_AGENT_ARTIFACT_BUCKET%" ^
  --instance_agent_artifact_prefix="%INSTANCE_AGENT_ARTIFACT_PREFIX%" ^
  --instance_agent_artifact_aws_cli_path="%AWS_EXE%" ^
  --instance_agent_artifact_queue_path="%INSTANCE_AGENT_ARTIFACT_QUEUE_PATH%" ^
  --instance_agent_artifact_max_bytes="%INSTANCE_AGENT_ARTIFACT_MAX_BYTES%" ^
  --instance_agent_artifact_unreal_log_directory="%INSTANCE_AGENT_ARTIFACT_UNREAL_LOG_DIRECTORY%" ^
  --instance_agent_screenshot_artifact_upload_enabled="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED%" ^
  --instance_agent_screenshot_artifact_bucket="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_BUCKET%" ^
  --instance_agent_screenshot_artifact_prefix="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_PREFIX%" ^
  --instance_agent_screenshot_source_folder="%INSTANCE_AGENT_SCREENSHOT_SOURCE_FOLDER%" ^
  --instance_agent_screenshot_artifact_queue_path="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_QUEUE_PATH%" ^
  --instance_agent_screenshot_artifact_max_files="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_FILES%" ^
  --instance_agent_screenshot_artifact_max_bytes="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_BYTES%" ^
  --instance_agent_screenshot_artifact_retention_days="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS%" ^
  --instance_agent_screenshot_artifact_settle_delay_ms="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_SETTLE_DELAY_MS%"

exit /b %errorlevel%

:start_signalling_with_reverse_proxy
call start.bat -- ^
  --peer_options_player_file="%ROOT%\peer_options.player.json" ^
  --peer_options_streamer_file="%ROOT%\peer_options.streamer.json" ^
  --auth_mode="%CONNECT_TICKET_AUTH_MODE%" ^
  --player_keepalive="%PLAYER_KEEPALIVE%" ^
  --player_keepalive_interval_ms="%PLAYER_KEEPALIVE_INTERVAL_MS%" ^
  --player_keepalive_max_missed_pongs="%PLAYER_KEEPALIVE_MAX_MISSED_PONGS%" ^
  --viewer_idle_stop="%VIEWER_IDLE_STOP%" ^
  --viewer_idle_grace_ms="%VIEWER_IDLE_GRACE_MS%" ^
  --viewer_idle_first_viewer_grace_ms="%VIEWER_IDLE_FIRST_VIEWER_GRACE_MS%" ^
  --viewer_idle_first_viewer_delay_ms="%VIEWER_IDLE_FIRST_VIEWER_DELAY_MS%" ^
  --viewer_idle_stop_retry_ms="%VIEWER_IDLE_STOP_RETRY_MS%" ^
  --viewer_idle_stop_dry_run="%VIEWER_IDLE_STOP_DRY_RUN%" ^
  --runtime_status="%RUNTIME_STATUS_ENABLED%" ^
  --runtime_status_aws_cli_path="%AWS_EXE%" ^
  --runtime_status_source="signalling-server" ^
  --instance_agent="%INSTANCE_AGENT%" ^
  --instance_agent_api_base_url="%INSTANCE_AGENT_API_BASE_URL%" ^
  --instance_agent_bootstrap_shared_secret="%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET%" ^
  --instance_agent_instance_id="%INSTANCE_AGENT_INSTANCE_ID%" ^
  --instance_agent_region="%INSTANCE_AGENT_REGION%" ^
  --instance_agent_require_identity_proof="%INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF%" ^
  --instance_agent_lane="%INSTANCE_AGENT_LANE%" ^
  --instance_agent_route_key="%INSTANCE_AGENT_ROUTE_KEY%" ^
  --instance_agent_scope_value="%INSTANCE_AGENT_SCOPE_VALUE%" ^
  --instance_agent_version="%INSTANCE_AGENT_VERSION%" ^
  --instance_agent_runtime_version="%INSTANCE_AGENT_RUNTIME_VERSION%" ^
  --instance_agent_heartbeat_ms="%INSTANCE_AGENT_HEARTBEAT_MS%" ^
  --instance_agent_desired_state_path="%INSTANCE_AGENT_DESIRED_STATE_PATH%" ^
  --instance_agent_artifact_upload_enabled="%INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED%" ^
  --instance_agent_artifact_bucket="%INSTANCE_AGENT_ARTIFACT_BUCKET%" ^
  --instance_agent_artifact_prefix="%INSTANCE_AGENT_ARTIFACT_PREFIX%" ^
  --instance_agent_artifact_aws_cli_path="%AWS_EXE%" ^
  --instance_agent_artifact_queue_path="%INSTANCE_AGENT_ARTIFACT_QUEUE_PATH%" ^
  --instance_agent_artifact_max_bytes="%INSTANCE_AGENT_ARTIFACT_MAX_BYTES%" ^
  --instance_agent_artifact_unreal_log_directory="%INSTANCE_AGENT_ARTIFACT_UNREAL_LOG_DIRECTORY%" ^
  --instance_agent_screenshot_artifact_upload_enabled="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED%" ^
  --instance_agent_screenshot_artifact_bucket="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_BUCKET%" ^
  --instance_agent_screenshot_artifact_prefix="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_PREFIX%" ^
  --instance_agent_screenshot_source_folder="%INSTANCE_AGENT_SCREENSHOT_SOURCE_FOLDER%" ^
  --instance_agent_screenshot_artifact_queue_path="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_QUEUE_PATH%" ^
  --instance_agent_screenshot_artifact_max_files="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_FILES%" ^
  --instance_agent_screenshot_artifact_max_bytes="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_BYTES%" ^
  --instance_agent_screenshot_artifact_retention_days="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS%" ^
  --instance_agent_screenshot_artifact_settle_delay_ms="%INSTANCE_AGENT_SCREENSHOT_ARTIFACT_SETTLE_DELAY_MS%" ^
  --reverse-proxy ^
  --reverse-proxy-num-proxies="%REVERSE_PROXY_NUM_PROXIES%"

exit /b %errorlevel%

:load_runtime_parameters
set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM="
set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM_NAME="
set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM="
set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM_NAME="
set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM="
set "INSTANCE_AGENT_ARTIFACT_BUCKET_LOADED_FROM_PARAM="
set "RUNTIME_PARAMETER_NAMES=%TURN_USER_PARAM% %TURN_CREDENTIAL_PARAM%"

if /i not "%CONNECT_TICKET_AUTH_MODE%"=="off" (
  if not defined CONNECT_TICKET_SIGNING_KEY (
    set "RUNTIME_PARAMETER_NAMES=%RUNTIME_PARAMETER_NAMES% %CONNECT_TICKET_SIGNING_KEY_PARAM%"
  )
)

if not defined INSTANCE_AGENT_API_BASE_URL (
  if defined INSTANCE_AGENT_API_BASE_URL_PARAM (
    set "RUNTIME_PARAMETER_NAMES=%RUNTIME_PARAMETER_NAMES% %INSTANCE_AGENT_API_BASE_URL_PARAM%"
  )
  if defined INSTANCE_AGENT_API_BASE_URL_FALLBACK_PARAM (
    set "RUNTIME_PARAMETER_NAMES=%RUNTIME_PARAMETER_NAMES% %INSTANCE_AGENT_API_BASE_URL_FALLBACK_PARAM%"
  )
)

if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV (
  if defined INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM (
    set "RUNTIME_PARAMETER_NAMES=%RUNTIME_PARAMETER_NAMES% %INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM%"
  )
  if defined INSTANCE_AGENT_CONTROL_PLANE_ENV_FALLBACK_PARAM (
    set "RUNTIME_PARAMETER_NAMES=%RUNTIME_PARAMETER_NAMES% %INSTANCE_AGENT_CONTROL_PLANE_ENV_FALLBACK_PARAM%"
  )
)

if not defined INSTANCE_AGENT_ARTIFACT_BUCKET (
  if defined INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM (
    set "RUNTIME_PARAMETER_NAMES=%RUNTIME_PARAMETER_NAMES% %INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM%"
  )
)

for /f "usebackq tokens=1,*" %%I in (`%AWS_CALL% ssm get-parameters --names %RUNTIME_PARAMETER_NAMES% --with-decryption --region "%REGION%" --query "Parameters[].[Name,Value]" --output text`) do (
  if /i "%%I"=="%TURN_USER_PARAM%" set "TURN_USERNAME=%%J"
  if /i "%%I"=="%TURN_CREDENTIAL_PARAM%" set "TURN_CREDENTIAL=%%J"
  if /i "%%I"=="%CONNECT_TICKET_SIGNING_KEY_PARAM%" set "CONNECT_TICKET_SIGNING_KEY=%%J"
  if /i "%%I"=="%INSTANCE_AGENT_API_BASE_URL_PARAM%" (
    set "INSTANCE_AGENT_API_BASE_URL=%%J"
    set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM=true"
    set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM_NAME=%%I"
  )
  if defined INSTANCE_AGENT_API_BASE_URL_FALLBACK_PARAM (
    if /i "%%I"=="%INSTANCE_AGENT_API_BASE_URL_FALLBACK_PARAM%" (
      if not defined INSTANCE_AGENT_API_BASE_URL (
        set "INSTANCE_AGENT_API_BASE_URL=%%J"
        set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM=true"
        set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM_NAME=%%I"
      )
    )
  )
  if /i "%%I"=="%INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM%" (
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV=%%J"
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM=true"
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM_NAME=%%I"
  )
  if defined INSTANCE_AGENT_CONTROL_PLANE_ENV_FALLBACK_PARAM (
    if /i "%%I"=="%INSTANCE_AGENT_CONTROL_PLANE_ENV_FALLBACK_PARAM%" (
      if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV (
        set "INSTANCE_AGENT_CONTROL_PLANE_ENV=%%J"
        set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM=true"
        set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM_NAME=%%I"
      )
    )
  )
  if /i "%%I"=="%INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM%" (
    set "INSTANCE_AGENT_ARTIFACT_BUCKET=%%J"
    set "INSTANCE_AGENT_ARTIFACT_BUCKET_LOADED_FROM_PARAM=true"
  )
)

if /i "%INSTANCE_AGENT_API_BASE_URL%"=="None" (
  set "INSTANCE_AGENT_API_BASE_URL="
  set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM="
  set "INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM_NAME="
)

if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="None" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV="
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM="
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM_NAME="
)

if /i "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET%"=="None" (
  set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET="
  set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM="
)

if /i "%INSTANCE_AGENT_ARTIFACT_BUCKET%"=="None" (
  set "INSTANCE_AGENT_ARTIFACT_BUCKET="
  set "INSTANCE_AGENT_ARTIFACT_BUCKET_LOADED_FROM_PARAM="
)

if defined INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM (
  if defined INSTANCE_AGENT_API_BASE_URL (
    echo Loaded instance-agent API base URL from SSM parameter "%INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM_NAME%".
  )
)

if defined INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM (
  if defined INSTANCE_AGENT_CONTROL_PLANE_ENV (
    echo Loaded instance-agent control-plane environment from SSM parameter "%INSTANCE_AGENT_CONTROL_PLANE_ENV_LOADED_FROM_PARAM_NAME%".
  )
)

if defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM (
  if defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET (
    echo Loaded instance-agent bootstrap shared secret from SSM parameter "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM%".
  )
)

if defined INSTANCE_AGENT_ARTIFACT_BUCKET_LOADED_FROM_PARAM (
  if defined INSTANCE_AGENT_ARTIFACT_BUCKET (
    echo Loaded instance-agent artifact bucket from SSM parameter "%INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM%".
  )
)

exit /b 0

:resolve_instance_agent_control_plane_env
set "INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL="
call :normalize_instance_agent_control_plane_env
if errorlevel 1 exit /b 1

if defined INSTANCE_AGENT_API_BASE_URL (
  call :infer_instance_agent_control_plane_env_from_url
  if errorlevel 1 exit /b 1
  if defined INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL (
    if defined INSTANCE_AGENT_CONTROL_PLANE_ENV (
      if /i not "!INSTANCE_AGENT_CONTROL_PLANE_ENV!"=="!INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL!" (
        echo WARNING: Instance-agent control-plane environment "!INSTANCE_AGENT_CONTROL_PLANE_ENV!" conflicts with API base URL "!INSTANCE_AGENT_API_BASE_URL!".
        echo WARNING: Using "!INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL!" so the API URL and bootstrap secret stay paired.
      )
    ) else (
      if defined INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM (
        echo WARNING: Inferred instance-agent control-plane environment "!INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL!" from API base URL "!INSTANCE_AGENT_API_BASE_URL!".
        echo WARNING: Prefer setting "!INSTANCE_AGENT_CONTROL_PLANE_ENV_PARAM!" so API URL and bootstrap secret stay paired explicitly.
      )
    )
    set "INSTANCE_AGENT_CONTROL_PLANE_ENV=!INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL!"
    exit /b 0
  )

  if defined INSTANCE_AGENT_CONTROL_PLANE_ENV exit /b 0

  if defined INSTANCE_AGENT_API_BASE_URL_LOADED_FROM_PARAM (
    echo WARNING: Instance-agent API URL override "!INSTANCE_AGENT_API_BASE_URL!" did not match a known Dev, Stage, or Prod host.
    echo WARNING: Falling back to deployment track "!SCALEWORLD_DEPLOYMENT_TRACK!" for bootstrap secret selection.
  )
)

if defined INSTANCE_AGENT_CONTROL_PLANE_ENV exit /b 0

if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="prod" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=prod"
) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="stage" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=stage"
) else if /i "%SCALEWORLD_DEPLOYMENT_TRACK%"=="dev" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=dev"
) else if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=prod"
) else (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=stage"
)

call :normalize_instance_agent_control_plane_env
if errorlevel 1 exit /b 1
exit /b 0

:normalize_instance_agent_control_plane_env
if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV exit /b 0
if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="dev" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=dev"
  exit /b 0
)
if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="stage" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=stage"
  exit /b 0
)
if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="prod" (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV=prod"
  exit /b 0
)
echo ERROR: Unsupported INSTANCE_AGENT_CONTROL_PLANE_ENV "%INSTANCE_AGENT_CONTROL_PLANE_ENV%". Expected dev, stage, or prod.
exit /b 1

:infer_instance_agent_control_plane_env_from_url
if not defined INSTANCE_AGENT_API_BASE_URL exit /b 0
echo(%INSTANCE_AGENT_API_BASE_URL%| findstr /i /c:"scaleaq-dev.net" >nul
if not errorlevel 1 (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL=dev"
  exit /b 0
)
echo(%INSTANCE_AGENT_API_BASE_URL%| findstr /i /c:"scaleaq-stage.net" >nul
if not errorlevel 1 (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL=stage"
  exit /b 0
)
echo(%INSTANCE_AGENT_API_BASE_URL%| findstr /i /c:"scaleaq.net" >nul
if not errorlevel 1 (
  set "INSTANCE_AGENT_CONTROL_PLANE_ENV_INFERRED_FROM_URL=prod"
  exit /b 0
)
exit /b 0

:apply_instance_agent_control_plane_defaults
if not defined INSTANCE_AGENT_CONTROL_PLANE_ENV (
  echo ERROR: Instance-agent control-plane environment was not resolved.
  exit /b 1
)

if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" (
  if /i not "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="prod" (
    echo ERROR: Prod streaming lane cannot use instance-agent control-plane environment "%INSTANCE_AGENT_CONTROL_PLANE_ENV%".
    exit /b 1
  )
) else if /i "%SCALEWORLD_STREAMING_LANE%"=="nonprod" (
  if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="prod" (
    echo ERROR: Nonprod streaming lane cannot use the prod instance-agent control-plane environment.
    exit /b 1
  )
)

if not defined INSTANCE_AGENT_API_BASE_URL (
  if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="prod" (
    set "INSTANCE_AGENT_API_BASE_URL=https://scaleworld.api.scaleaq.net"
  ) else if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="stage" (
    set "INSTANCE_AGENT_API_BASE_URL=https://scaleworld.api.scaleaq-stage.net"
  ) else (
    set "INSTANCE_AGENT_API_BASE_URL=https://scaleworld.api.scaleaq-dev.net"
  )
)

if not defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM (
  if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="prod" (
    set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM=/pixelstreaming/prod/instance-agent-bootstrap-shared-secret"
  ) else if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="stage" (
    set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM=/pixelstreaming/stage/instance-agent-bootstrap-shared-secret"
  ) else (
    set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM=/pixelstreaming/dev/instance-agent-bootstrap-shared-secret"
  )
)

echo Using instance-agent control-plane environment: "%INSTANCE_AGENT_CONTROL_PLANE_ENV%".
echo Using instance-agent API base URL: "%INSTANCE_AGENT_API_BASE_URL%".
if defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM echo Using instance-agent bootstrap shared secret parameter: "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM%".
exit /b 0

:load_instance_agent_bootstrap_shared_secret
if defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET exit /b 0
if not defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM exit /b 0

set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM="
for /f "usebackq tokens=1,*" %%I in (`%AWS_CALL% ssm get-parameters --names "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM%" --with-decryption --region "%REGION%" --query "Parameters[].[Name,Value]" --output text`) do (
  if /i "%%I"=="%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM%" (
    set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET=%%J"
    set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM=true"
  )
)

if /i "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET%"=="None" (
  set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET="
  set "INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM="
)

if defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_LOADED_FROM_PARAM (
  if defined INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET (
    echo Loaded instance-agent bootstrap shared secret from SSM parameter "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM%".
  )
) else (
  echo WARNING: Instance-agent bootstrap shared secret was not loaded from SSM parameter "%INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM%".
)

exit /b 0

:apply_instance_agent_defaults
if not defined INSTANCE_AGENT (
  if defined INSTANCE_ID (
    set "INSTANCE_AGENT=true"
  ) else (
    set "INSTANCE_AGENT=false"
  )
)

if /i not "%INSTANCE_AGENT%"=="false" (
  if not defined INSTANCE_AGENT_API_BASE_URL (
    if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="prod" (
      set "INSTANCE_AGENT_API_BASE_URL=https://scaleworld.api.scaleaq.net"
    ) else if /i "%INSTANCE_AGENT_CONTROL_PLANE_ENV%"=="stage" (
      set "INSTANCE_AGENT_API_BASE_URL=https://scaleworld.api.scaleaq-stage.net"
    ) else (
      set "INSTANCE_AGENT_API_BASE_URL=https://scaleworld.api.scaleaq-dev.net"
    )
  )
)

if defined INSTANCE_ID (
  if not defined INSTANCE_AGENT_INSTANCE_ID set "INSTANCE_AGENT_INSTANCE_ID=%INSTANCE_ID%"
)
if not defined INSTANCE_AGENT_REGION set "INSTANCE_AGENT_REGION=%REGION%"
if not defined INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED (
  if defined INSTANCE_AGENT_ARTIFACT_BUCKET (
    set "INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED=true"
  ) else (
    set "INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED=false"
  )
)
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_BUCKET (
  if defined INSTANCE_AGENT_ARTIFACT_BUCKET set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_BUCKET=%INSTANCE_AGENT_ARTIFACT_BUCKET%"
)
if not defined INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED (
  set "INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED=%INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED%"
)
exit /b 0

:resolve_streaming_lane_from_instance_tag
set "RESOLVED_STREAMING_LANE="
set "RESOLVE_STREAMING_LANE_EXIT=0"
set /a STREAMING_LANE_TAG_ATTEMPT=0
set "RESOLVE_STREAMING_LANE_SCRIPT=%ROOT%\platform_scripts\powershell\resolve_streaming_lane_from_instance_tag.ps1"

:resolve_streaming_lane_retry
set /a STREAMING_LANE_TAG_ATTEMPT+=1
set "RESOLVED_STREAMING_LANE="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_STREAMING_LANE_SCRIPT%"`) do (
  set "RESOLVED_STREAMING_LANE=%%I"
)
set "RESOLVE_STREAMING_LANE_EXIT=%errorlevel%"

if defined RESOLVED_STREAMING_LANE exit /b 0
if "%RESOLVE_STREAMING_LANE_EXIT%"=="0" (
  if %STREAMING_LANE_TAG_ATTEMPT% geq %STREAMING_LANE_TAG_RETRY_COUNT% exit /b 0
  echo WARNING: Failed to resolve ScaleWorldLane instance tag on attempt %STREAMING_LANE_TAG_ATTEMPT% of %STREAMING_LANE_TAG_RETRY_COUNT%.
  echo WARNING: Retrying in %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% seconds before falling back to default lane.
  timeout /t %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
  goto resolve_streaming_lane_retry
)

if %STREAMING_LANE_TAG_ATTEMPT% geq %STREAMING_LANE_TAG_RETRY_COUNT% (
  echo ERROR: ScaleWorldLane instance tag resolution failed after %STREAMING_LANE_TAG_RETRY_COUNT% attempts.
  echo ERROR: Refusing to continue with an inferred default lane after a real tag lookup failure.
  exit /b 1
)

echo WARNING: ScaleWorldLane instance tag lookup failed on attempt %STREAMING_LANE_TAG_ATTEMPT% of %STREAMING_LANE_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% seconds before failing startup.
timeout /t %STREAMING_LANE_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_streaming_lane_retry

exit /b 0

:resolve_deployment_track_from_instance_tag
set "RESOLVED_DEPLOYMENT_TRACK="
set "RESOLVE_DEPLOYMENT_TRACK_EXIT=0"
set /a DEPLOYMENT_TRACK_TAG_ATTEMPT=0
set "RESOLVE_DEPLOYMENT_TRACK_SCRIPT=%ROOT%\platform_scripts\powershell\resolve_deployment_track_from_instance_tag.ps1"
if not exist "%RESOLVE_DEPLOYMENT_TRACK_SCRIPT%" exit /b 0

:resolve_deployment_track_retry
set /a DEPLOYMENT_TRACK_TAG_ATTEMPT+=1
set "RESOLVED_DEPLOYMENT_TRACK="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_DEPLOYMENT_TRACK_SCRIPT%"`) do (
  set "RESOLVED_DEPLOYMENT_TRACK=%%I"
)
set "RESOLVE_DEPLOYMENT_TRACK_EXIT=%errorlevel%"

if defined RESOLVED_DEPLOYMENT_TRACK exit /b 0
if "%RESOLVE_DEPLOYMENT_TRACK_EXIT%"=="0" (
  if %DEPLOYMENT_TRACK_TAG_ATTEMPT% geq %DEPLOYMENT_TRACK_TAG_RETRY_COUNT% exit /b 0
  echo WARNING: Failed to resolve ScaleWorldDeploymentTrack instance tag on attempt %DEPLOYMENT_TRACK_TAG_ATTEMPT% of %DEPLOYMENT_TRACK_TAG_RETRY_COUNT%.
  echo WARNING: Retrying in %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% seconds before falling back to default deployment track.
  timeout /t %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
  goto resolve_deployment_track_retry
)

if %DEPLOYMENT_TRACK_TAG_ATTEMPT% geq %DEPLOYMENT_TRACK_TAG_RETRY_COUNT% (
  echo ERROR: ScaleWorldDeploymentTrack instance tag resolution failed after %DEPLOYMENT_TRACK_TAG_RETRY_COUNT% attempts.
  echo ERROR: Refusing to continue with an inferred default deployment track after a real tag lookup failure.
  exit /b 1
)

echo WARNING: ScaleWorldDeploymentTrack instance tag lookup failed on attempt %DEPLOYMENT_TRACK_TAG_ATTEMPT% of %DEPLOYMENT_TRACK_TAG_RETRY_COUNT%.
echo WARNING: Retrying in %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% seconds before failing startup.
timeout /t %DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS% /nobreak >nul
goto resolve_deployment_track_retry

:delegate_to_active_runtime_if_required
set "ACTIVE_RUNTIME_WILBUR_DELEGATED=false"

if /i "%SCALEWORLD_DISABLE_ACTIVE_RUNTIME_WILBUR_DELEGATION%"=="true" exit /b 0
if /i "%ROOT%"=="%SCALEWORLD_ACTIVE_RUNTIME_ROOT%" exit /b 0
if not exist "%ACTIVE_RUNTIME_WILBUR_LAUNCHER%" if not defined SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE exit /b 0

call :resolve_pixelstreaming_delivery_mode_for_wilbur
if errorlevel 1 exit /b %errorlevel%

if /i "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"=="git_ref" exit /b 0
if not defined SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE exit /b 0

if not exist "%ACTIVE_RUNTIME_WILBUR_LAUNCHER%" (
  if /i "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"=="runtime_artifact" (
    echo ERROR: PixelStreaming delivery mode runtime_artifact requires active Wilbur launcher "%ACTIVE_RUNTIME_WILBUR_LAUNCHER%".
    exit /b 1
  )

  echo WARNING: Active PixelStreaming runtime launcher "%ACTIVE_RUNTIME_WILBUR_LAUNCHER%" was not found. Continuing with bootstrap Wilbur root.
  exit /b 0
)

echo Delegating Wilbur startup to active PixelStreaming runtime "%ACTIVE_RUNTIME_WILBUR_LAUNCHER%".
set "ACTIVE_RUNTIME_WILBUR_DELEGATED=true"
call "%ACTIVE_RUNTIME_WILBUR_LAUNCHER%" %*
exit /b %errorlevel%

:resolve_pixelstreaming_delivery_mode_for_wilbur
if defined SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE (
  if not exist "%NORMALIZE_DELIVERY_MODE_SCRIPT%" (
    echo ERROR: PixelStreaming delivery mode normalizer not found at "%NORMALIZE_DELIVERY_MODE_SCRIPT%".
    exit /b 1
  )

  set "NORMALIZED_PIXELSTREAMING_DELIVERY_MODE="
  for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%NORMALIZE_DELIVERY_MODE_SCRIPT%" -Value "%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%"`) do (
    set "NORMALIZED_PIXELSTREAMING_DELIVERY_MODE=%%I"
  )
  if not defined NORMALIZED_PIXELSTREAMING_DELIVERY_MODE exit /b 1
  set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=%NORMALIZED_PIXELSTREAMING_DELIVERY_MODE%"
  exit /b 0
)

if not exist "%RESOLVE_DELIVERY_MODE_SCRIPT%" exit /b 0

set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE="
if not defined TEMP set "TEMP=%SystemRoot%\Temp"
set "DELIVERY_MODE_OUTPUT=%TEMP%\scaleworld-delivery-mode-%RANDOM%%RANDOM%.txt"
set "DELIVERY_MODE_ERROR=%TEMP%\scaleworld-delivery-mode-%RANDOM%%RANDOM%.err"
powershell -NoProfile -ExecutionPolicy Bypass -File "%RESOLVE_DELIVERY_MODE_SCRIPT%" > "%DELIVERY_MODE_OUTPUT%" 2> "%DELIVERY_MODE_ERROR%"
set "RESOLVE_DELIVERY_MODE_EXIT=%errorlevel%"
if not "%RESOLVE_DELIVERY_MODE_EXIT%"=="0" (
  if exist "%DELIVERY_MODE_ERROR%" type "%DELIVERY_MODE_ERROR%"
  if exist "%DELIVERY_MODE_OUTPUT%" del /f /q "%DELIVERY_MODE_OUTPUT%" >nul 2>nul
  if exist "%DELIVERY_MODE_ERROR%" del /f /q "%DELIVERY_MODE_ERROR%" >nul 2>nul
  exit /b %RESOLVE_DELIVERY_MODE_EXIT%
)
for /f "usebackq delims=" %%I in ("%DELIVERY_MODE_OUTPUT%") do (
  if not defined RESOLVED_PIXELSTREAMING_DELIVERY_MODE set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE=%%I"
)
if exist "%DELIVERY_MODE_OUTPUT%" del /f /q "%DELIVERY_MODE_OUTPUT%" >nul 2>nul
if exist "%DELIVERY_MODE_ERROR%" del /f /q "%DELIVERY_MODE_ERROR%" >nul 2>nul
if defined RESOLVED_PIXELSTREAMING_DELIVERY_MODE set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=%RESOLVED_PIXELSTREAMING_DELIVERY_MODE%"
exit /b 0

:sync_repo_and_build
for %%I in ("%ROOT%\..") do set "REPO_ROOT=%%~fI"
set "REPO_SYNC_SCRIPT=%ROOT%\platform_scripts\powershell\ensure_repo_current.ps1"

if not exist "%REPO_SYNC_SCRIPT%" (
  echo ERROR: Repo sync helper not found at "%REPO_SYNC_SCRIPT%".
  call :set_runtime_status "runtime_fault" "startup-script" "repo_sync_script_missing"
  call :stop_startup_heartbeat
  exit /b 1
)

echo Checking PixelStreaming repo using git sync mode "%SCALEWORLD_GIT_SYNC_MODE%".
call :set_runtime_status "booting" "startup-script" "git_sync_check"
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_SYNC_SCRIPT%" -RepoRoot "%REPO_ROOT%" -Mode "startup"
set "REPO_SYNC_EXIT=%errorlevel%"
if "%REPO_SYNC_EXIT%"=="42" (
  echo Repo sync launched a fresh stack from the updated checkout. Exiting this pre-update launcher.
  call :stop_startup_heartbeat
  exit /b 0
)
if not "%REPO_SYNC_EXIT%"=="0" (
  echo ERROR: Repo sync helper failed.
  call :set_runtime_status "runtime_fault" "startup-script" "repo_sync_failed"
  call :stop_startup_heartbeat
  exit /b %REPO_SYNC_EXIT%
)

exit /b 0

:reset_startup_heartbeat
if not defined INSTANCE_ID exit /b 0
set "STARTUP_HEARTBEAT_TOKEN=%INSTANCE_ID%-%RANDOM%%RANDOM%"
set "STARTUP_HEARTBEAT_STATE_FILE=%TEMP%\scaleworld-startup-status-%STARTUP_HEARTBEAT_TOKEN%.state"
set "STARTUP_HEARTBEAT_STOP_FILE=%TEMP%\scaleworld-startup-status-%STARTUP_HEARTBEAT_TOKEN%.stop"
if exist "%STARTUP_HEARTBEAT_STATE_FILE%" del /f /q "%STARTUP_HEARTBEAT_STATE_FILE%" >nul 2>nul
if exist "%STARTUP_HEARTBEAT_STOP_FILE%" del /f /q "%STARTUP_HEARTBEAT_STOP_FILE%" >nul 2>nul
exit /b 0

:start_startup_heartbeat
if /i not "%RUNTIME_STATUS_ENABLED%"=="true" exit /b 0
if not defined INSTANCE_ID exit /b 0
if not defined STARTUP_HEARTBEAT_STATE_FILE exit /b 0
start "ScaleWorld Startup Status Heartbeat" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\platform_scripts\powershell\runtime-status-heartbeat.ps1" -InstanceId "%INSTANCE_ID%" -Region "%REGION%" -AwsCliPath "%AWS_EXE%" -StateFilePath "%STARTUP_HEARTBEAT_STATE_FILE%" -StopFilePath "%STARTUP_HEARTBEAT_STOP_FILE%" -IntervalSeconds %STARTUP_RUNTIME_STATUS_HEARTBEAT_INTERVAL_SECONDS%
exit /b 0

:stop_startup_heartbeat
if not defined STARTUP_HEARTBEAT_STOP_FILE exit /b 0
> "%STARTUP_HEARTBEAT_STOP_FILE%" echo stop
exit /b 0

:write_startup_status_state
if not defined STARTUP_HEARTBEAT_STATE_FILE exit /b 0
> "%STARTUP_HEARTBEAT_STATE_FILE%" (
  echo status=%STATUS_VALUE%
  echo source=%STATUS_SOURCE%
  echo reason=%STATUS_REASON%
  echo version=%STATUS_VERSION%
  echo status_at_utc=%UTC_TIMESTAMP%
)
exit /b 0

:set_runtime_status
if /i not "%RUNTIME_STATUS_ENABLED%"=="true" exit /b 0
if not defined INSTANCE_ID exit /b 0
set "STATUS_VALUE=%~1"
set "STATUS_SOURCE=%~2"
set "STATUS_REASON=%~3"
set "STATUS_VERSION=%~4"
if not defined STATUS_SOURCE set "STATUS_SOURCE=startup-script"

set "UTC_TIMESTAMP="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "[DateTime]::UtcNow.ToString('o')"`) do set "UTC_TIMESTAMP=%%I"
if not defined UTC_TIMESTAMP exit /b 0

call :write_startup_status_state

if not exist "%ROOT%\platform_scripts\powershell\publish_runtime_status_tags.ps1" (
  echo WARNING: Runtime status publish helper not found. Skipping EC2 tag publish for "%STATUS_VALUE%".
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\platform_scripts\powershell\publish_runtime_status_tags.ps1" ^
  -InstanceId "%INSTANCE_ID%" ^
  -Region "%REGION%" ^
  -AwsCliPath "%AWS_EXE%" ^
  -Status "%STATUS_VALUE%" ^
  -Source "%STATUS_SOURCE%" ^
  -Reason "%STATUS_REASON%" ^
  -Version "%STATUS_VERSION%" ^
  -StatusAtUtc "%UTC_TIMESTAMP%" >nul 2>nul

if errorlevel 1 (
  echo WARNING: Failed to publish runtime status "%STATUS_VALUE%" ^(reason=%STATUS_REASON%^).
  exit /b 0
)

echo Published runtime status "%STATUS_VALUE%" ^(reason=%STATUS_REASON%^).
exit /b 0
