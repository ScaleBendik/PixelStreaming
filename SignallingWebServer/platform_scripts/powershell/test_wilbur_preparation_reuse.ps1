param([string]$LauncherPath=(Join-Path $PSScriptRoot '..\cmd\start_dev_turn.bat'))
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $LauncherPath))
# Execute the real CMD initialization and required-field checks. External I/O
# and the later IMDS/heartbeat/Node stages are replaced by local dummy fixtures.
$cut=$source.IndexOf('set /a IMDS_INSTANCE_ID_ATTEMPT=0')
if($cut -lt 0){throw 'Launcher checkpoint missing.'}
$loader=[regex]::Match($source,'(?m)^:load_runtime_parameters\r?\n([^\r\n]+)').Groups[1].Value
if(-not $loader){throw 'Loader entry missing.'}
$prefix=$source.Substring(0,$cut)
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $tempBase ('scaleworld-wilbur-prep-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
try{
 $bat=Join-Path $fixture 'launcher-fixture.bat'
 $tail=@'
if /i "%SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED%"=="true" (
 if not "%INSTANCE_ID%"=="i-00000000000000000" exit /b 31
 if not "%TURN_USERNAME%"=="inherited-user" exit /b 32
 if not "%TURN_CREDENTIAL%"=="inherited-credential" exit /b 33
 if defined MOCK_PARAMETER_FETCH exit /b 34
) else (
 if defined INSTANCE_ID exit /b 35
 if not "%TURN_USERNAME%"=="fresh-user" exit /b 36
 if not "%TURN_CREDENTIAL%"=="fresh-credential" exit /b 37
 if not defined MOCK_PARAMETER_FETCH exit /b 38
)
echo PREPARATION_CHECK_PASSED
exit /b 0
:startup_phase
:resolve_instance_agent_control_plane_env
:apply_instance_agent_control_plane_defaults
:load_instance_agent_bootstrap_shared_secret
exit /b 0
:load_runtime_parameters
'@
 $body=$prefix+$tail+"`r`n"+$loader+"`r`n"+@'
set "MOCK_PARAMETER_FETCH=true"
set "TURN_USERNAME=fresh-user"
set "TURN_CREDENTIAL=fresh-credential"
exit /b 0
'@
 [IO.File]::WriteAllText($bat,$body,[Text.ASCIIEncoding]::new())
 foreach($mode in @('true','false','')){
  $wrapper=Join-Path $fixture 'run.bat'
  $setup=@'
@echo off
setlocal
set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA=true"
set "SCALEWORLD_STREAMING_LANE=nonprod"
set "SCALEWORLD_DEPLOYMENT_TRACK=dev"
set "INSTANCE_ID=i-00000000000000000"
set "TURN_USERNAME=inherited-user"
set "TURN_CREDENTIAL=inherited-credential"
set "CONNECT_TICKET_AUTH_MODE=required"
set "CONNECT_TICKET_SIGNING_KEY=dummy-fixture-key"
set "MOCK_PARAMETER_FETCH="
'@
  $setup+="`r`nset `"SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED=$mode`"`r`ncall `"$bat`"`r`nexit /b %errorlevel%`r`n"
  [IO.File]::WriteAllText($wrapper,$setup,[Text.ASCIIEncoding]::new())
  $output=& $env:ComSpec /d /c $wrapper 2>&1
  if($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'PREPARATION_CHECK_PASSED'){
   throw "CMD preparation mode '$mode' failed, exit=$LASTEXITCODE. $($output -join ' ')"
  }
 }
 Write-Output 'Real CMD preparation initialization passed: reuse, disabled, and ordinary modes.'
}finally{
 $resolved=[IO.Path]::GetFullPath($fixture)
 if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^scaleworld-wilbur-prep-[0-9a-f]{32}$'){throw 'Unsafe fixture cleanup path.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
