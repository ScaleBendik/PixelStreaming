[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
$script:Assertions=0
function Assert-True {param([bool]$Value,[string]$Message)$script:Assertions++;if(-not $Value){throw $Message}}
$ownedSources=@('stack_launch_lease.ps1','invoke_stack_launch_lease.ps1','stack_launch_reserved_entry.ps1','stack_launch_maintenance.ps1','invoke_update_mode.ps1','invoke_provisioning_mode.ps1','install_pixelstreaming_runtime.ps1','test_stack_launch_maintenance_integration.ps1')
$sourceHashes=@{};foreach($name in $ownedSources){$sourceHashes[$name]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash}
$batPath=Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat';$batHash=(Get-FileHash -LiteralPath $batPath).Hash
$batLines=Get-Content -LiteralPath $batPath
$tokens=$null;$errors=$null;$updateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'invoke_update_mode.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw 'Actual update-mode source did not parse.'}
$validationFunction=$updateAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Start-ValidationStack'},$true).Extent.Text
function Get-BatBlock {
    param([string]$StartText,[string]$NextText)
    $start=-1;$end=-1
    for($i=0;$i -lt $batLines.Count;$i++){
        if($start -lt 0 -and $batLines[$i].StartsWith($StartText)){$start=$i;continue}
        if($start -ge 0 -and $batLines[$i].StartsWith($NextText)){$end=$i;break}
    }
    if($start -lt 0 -or $end -le $start){throw 'Actual maintenance BAT block was not found.'}
    return ($batLines[$start..($end-1)] -join "`r`n")
}
$updateBlock=Get-BatBlock 'if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_UPDATE_MODE%"' 'if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_PROVISIONING_MODE%"'
$provisionBlock=Get-BatBlock 'if /i not "%STACK_MODE%"=="recovery" if /i "%STACK_ENABLE_PROVISIONING_MODE%"' 'if not defined WATCHDOG_RESTART_COMMAND'
$prefix=@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "ROOT=%SCRIPT_DIR%..\.."
set "MODE=normal"
if /i "%~1"=="--validation" set "MODE=validation"
set "RECEIPT=%TEMP%\scaleworld-stack-launch-%RANDOM%-%RANDOM%.env"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\invoke_stack_launch_lease.ps1" -Mode Enter -RepoRoot "%ROOT%" -InstallBase "%SCALEWORLD_INSTALL_BASE%" -LaunchMode "%MODE%" -GenerationId "%SCALEWORLD_STACK_LAUNCH_GENERATION%" -Grant "%SCALEWORLD_STACK_LAUNCH_GRANT%" -OutputFile "%RECEIPT%"
set "ENTRY_EXIT=!errorlevel!"
if "!ENTRY_EXIT!"=="10" exit /b 0
if not "!ENTRY_EXIT!"=="0" exit /b !ENTRY_EXIT!
for /f "usebackq delims=" %%L in ("%RECEIPT%") do %%L
del "%RECEIPT%" >nul 2>&1
set "SCALEWORLD_STACK_LAUNCH_GRANT="
if /i "%MODE%"=="validation" goto claimed
if "%FIXTURE_RECEIVER%"=="true" goto claimed
set "STACK_MODE=normal"
set "STACK_ENABLE_UPDATE_MODE=true"
set "STACK_ENABLE_PROVISIONING_MODE=false"
if "%FIXTURE_OPERATION%"=="provision" (
  set "STACK_ENABLE_UPDATE_MODE=false"
  set "STACK_ENABLE_PROVISIONING_MODE=true"
)
set "UPDATE_MODE_SCRIPT=%SCRIPT_DIR%..\powershell\fixture_maintenance.ps1"
set "PROVISIONING_MODE_SCRIPT=%UPDATE_MODE_SCRIPT%"
'@
$tail=@'
echo source_continued>"%FIXTURE_CONTINUATION%"
exit /b 99
:claimed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\fixture_claim.ps1"
exit /b %errorlevel%
:startup_phase
exit /b %~2
'@
$receiver=@'
@echo off
rem Deliberately different layout from the source BAT; no maintenance blocks.
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "ROOT=%SCRIPT_DIR%..\.."
set "MODE=normal"
if /i "%~1"=="--validation" set "MODE=validation"
set "RECEIPT=%TEMP%\scaleworld-stack-launch-%RANDOM%-%RANDOM%.env"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\invoke_stack_launch_lease.ps1" -Mode Enter -RepoRoot "%ROOT%" -InstallBase "%SCALEWORLD_INSTALL_BASE%" -LaunchMode "%MODE%" -GenerationId "%SCALEWORLD_STACK_LAUNCH_GENERATION%" -Grant "%SCALEWORLD_STACK_LAUNCH_GRANT%" -OutputFile "%RECEIPT%"
set "ENTRY_EXIT=!errorlevel!"
if "!ENTRY_EXIT!"=="10" exit /b 0
if not "!ENTRY_EXIT!"=="0" exit /b !ENTRY_EXIT!
for /f "usebackq delims=" %%L in ("%RECEIPT%") do %%L
del "%RECEIPT%" >nul 2>&1
set "SCALEWORLD_STACK_LAUNCH_GRANT="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\powershell\fixture_claim.ps1"
exit /b %errorlevel%
'@
$legacyReceiver=@'
@echo off
setlocal
set "MODE=normal"
if /i "%~1"=="--validation" set "MODE=validation"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\powershell\fixture_claim.ps1"
exit /b %errorlevel%
'@
$claim=@'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$value=@{mode=$env:MODE;generation=$env:SCALEWORLD_STACK_LAUNCH_GENERATION;healthPath=$env:WATCHDOG_STREAMER_HEALTH_PATH;restart=$env:WATCHDOG_RESTART_COMMAND;provisionEnabled=$env:STACK_ENABLE_PROVISIONING_MODE}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')){
  . (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
  $scope=Get-StackLaunchLeaseScope $root $env:SCALEWORLD_INSTALL_BASE
  $lease=Read-StackLaunchLease $scope
  $value.root=$lease.repoRoot;$value.phase=$lease.phase
}else{$value.root=$root;$value.phase='legacy_unclaimed'}
[IO.File]::WriteAllText($env:FIXTURE_CLAIM,($value|ConvertTo-Json -Compress))
Start-Sleep -Seconds 30
'@
$maintenance=@'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_launch_maintenance.ps1')
$source=Get-StackLaunchCanonicalPath (Join-Path $PSScriptRoot '..\..')
$context=Get-StackLaunchMaintenanceContext -SourceRepoRoot $source -InstallBase $env:SCALEWORLD_INSTALL_BASE -GenerationId $env:SCALEWORLD_STACK_LAUNCH_GENERATION -CallerScriptPath $PSCommandPath
$script:StackMaintenanceContext=$context
. (Join-Path $PSScriptRoot 'fixture_validation_function.ps1')
$originalGeneration=$context.GenerationId
$probe=[Diagnostics.ProcessStartInfo]::new();$probe.FileName=$env:ComSpec;$probe.UseShellExecute=$false;$probe.CreateNoWindow=$true
$probe.Arguments='/d /s /c ""{0}" --validation"' -f $context.Scope.EntryPath
$duplicate=[Diagnostics.Process]::Start($probe);if(-not $duplicate.WaitForExit(15000)){throw 'Duplicate probe hung.'};$duplicate.Dispose()
if(Test-Path -LiteralPath $env:FIXTURE_CLAIM){throw 'Ungranted duplicate mutated receiver health.'}
if($env:FIXTURE_RETARGET -eq 'true'){
  $alias=Join-Path $env:SCALEWORLD_INSTALL_BASE 'PixelStreaming'
  $item=Get-Item -LiteralPath $alias -Force
  if($item.LinkType -ne 'Junction'){throw 'Fixture alias is not a junction.'}
  [IO.Directory]::Delete($alias)
  [void](New-Item -ItemType Junction -Path $alias -Target $env:FIXTURE_TARGET_BUNDLE)
}
if($env:FIXTURE_PIN_FAILURE -eq 'true'){
  function Set-StackLaunchHandoffEntry {
    param($Scope,$Grant,$EntryIdentity,$LockHandle)
    [IO.File]::WriteAllText($env:FIXTURE_FAILED_CHILD,($EntryIdentity|ConvertTo-Json -Compress))
    throw 'Fixture reserved child pinning failure.'
  }
}
try{
  $mode=if($env:FIXTURE_OPERATION -eq 'provision'){'normal'}else{'validation'}
  if($env:FIXTURE_OPERATION -eq 'provision'){
    $result=Start-StackLaunchProvisioningHandoffIfChanged -Context $context -InstalledRoot $env:FIXTURE_TARGET_BUNDLE
  }else{
    Start-ValidationStack -LauncherPath $env:FIXTURE_TARGET_LAUNCHER -RuntimeArtifact
    $afterLease=Read-StackLaunchLease $context.Scope
    $result=[pscustomobject]@{GenerationId=$afterLease.generationId;LeaseAware=(Test-Path -LiteralPath (Join-Path $env:FIXTURE_TARGET_BUNDLE 'SignallingWebServer\platform_scripts\powershell\stack_launch_lease.ps1'));LaunchMode='validation'}
  }
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not(Test-Path -LiteralPath $env:FIXTURE_CLAIM) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
  if(-not(Test-Path -LiteralPath $env:FIXTURE_CLAIM)){throw 'Reserved receiver did not enter.'}
  if(-not(Test-StackLaunchProcessIdentity $context.Owner)){throw 'Source owner was misclassified dead after alias retarget.'}
  [IO.File]::WriteAllText($env:FIXTURE_RESULT,(@{success=$true;sourceOwnerLive=$true;sourcePhysical=$context.Scope.RepoRoot;sourceInvocation=$context.Owner.invocationPath;originalGeneration=$originalGeneration;generation=$result.GenerationId;leaseAware=$result.LeaseAware;launchMode=$result.LaunchMode}|ConvertTo-Json -Compress))
  if($env:FIXTURE_OPERATION -eq 'provision'){exit 42}else{exit 10}
}catch{
  $lease=Read-StackLaunchLease $context.Scope
  [IO.File]::WriteAllText($env:FIXTURE_RESULT,(@{success=$false;error=$_.Exception.Message;sourceOwnerLive=(Test-StackLaunchProcessIdentity $context.Owner);phase=$lease.phase;generation=$lease.generationId;originalGeneration=$originalGeneration}|ConvertTo-Json -Compress))
  Start-Sleep -Seconds 1
  exit 11
}
'@
function New-FixtureBundle {
    param([string]$CaseRoot,[string]$Name,[string]$Bat,[switch]$Legacy)
    $bundle=Join-Path $CaseRoot ('runtime-releases\'+$Name);$root=Join-Path $bundle 'SignallingWebServer';$cmd=Join-Path $root 'platform_scripts\cmd';$ps=Join-Path $root 'platform_scripts\powershell'
    [void](New-Item -ItemType Directory -Path (Join-Path $cmd 'node') -Force);[void](New-Item -ItemType Directory -Path $ps -Force)
    [IO.File]::WriteAllText((Join-Path $cmd 'start_streamer_stack.bat'),$Bat)
    [IO.File]::WriteAllText((Join-Path $cmd 'node\node.exe'),'unused fixture Node placeholder')
    [IO.File]::WriteAllText((Join-Path $ps 'fixture_claim.ps1'),$claim)
    if(-not $Legacy){foreach($file in @('stack_launch_lease.ps1','invoke_stack_launch_lease.ps1','stack_launch_reserved_entry.ps1','stack_launch_maintenance.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $ps $file)};[IO.File]::WriteAllText((Join-Path $ps 'fixture_maintenance.ps1'),$maintenance);[IO.File]::WriteAllText((Join-Path $ps 'fixture_validation_function.ps1'),$validationFunction)}
    return $bundle
}
function Start-FixtureCmd {
    param([string]$Launcher,[hashtable]$Variables,[string]$Arguments='')
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$env:ComSpec;$info.Arguments='/d /s /c ""{0}"{1}"' -f $Launcher,$Arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.EnvironmentVariables['SCALEWORLD_STACK_LAUNCH_GENERATION']='';$info.EnvironmentVariables['SCALEWORLD_STACK_LAUNCH_GRANT']=''
    foreach($key in $Variables.Keys){$info.EnvironmentVariables[$key]=[string]$Variables[$key]}
    return [Diagnostics.Process]::Start($info)
}
function Stop-FixtureProcesses {
    param([string]$CaseRoot)
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)){
        if($process.ProcessId -eq $PID -or ([string]$process.CommandLine).IndexOf($CaseRoot,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
        $pin=Get-StackLaunchProcessIdentity -ProcessId ([int]$process.ProcessId) -Process $process
        if(Test-StackLaunchProcessIdentity $pin){Stop-Process -Id $pin.pid -Force -ErrorAction SilentlyContinue}
    }
}
$parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')+'\'
$scratch=Join-Path $parent ('scaleworld-maintenance-integration-'+[Guid]::NewGuid().ToString('N'))
try{
    [void](New-Item -ItemType Directory -Path $scratch)
    foreach($case in @(@{Name='same-root-validation';Retarget=$false;Operation='update';Legacy=$false;PinFailure=$false},@{Name='retarget-validation';Retarget=$true;Operation='update';Legacy=$false;PinFailure=$false},@{Name='retarget-provision42';Retarget=$true;Operation='provision';Legacy=$false;PinFailure=$false},@{Name='pin-failure-held';Retarget=$true;Operation='update';Legacy=$false;PinFailure=$true},@{Name='legacy-rollback-roundtrip';Retarget=$true;Operation='update';Legacy=$true;PinFailure=$false})){
        $caseRoot=Join-Path $scratch $case.Name;[void](New-Item -ItemType Directory -Path $caseRoot)
        $sourceBundle=New-FixtureBundle $caseRoot 'source' ($prefix+"`r`n"+$updateBlock+"`r`n"+$provisionBlock+"`r`n"+$tail)
        $targetBundle=if($case.Retarget){New-FixtureBundle $caseRoot 'target' $(if($case.Legacy){$legacyReceiver}else{$receiver}) -Legacy:$case.Legacy}else{$sourceBundle}
        $alias=Join-Path $caseRoot 'PixelStreaming';[void](New-Item -ItemType Junction -Path $alias -Target $sourceBundle)
        $targetLauncher=Join-Path $(if($case.Retarget){$alias}else{$sourceBundle}) 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
        $variables=@{SCALEWORLD_INSTALL_BASE=$caseRoot;FIXTURE_OPERATION=$case.Operation;FIXTURE_RETARGET=$case.Retarget.ToString().ToLowerInvariant();FIXTURE_PIN_FAILURE=$case.PinFailure.ToString().ToLowerInvariant();FIXTURE_TARGET_BUNDLE=$targetBundle;FIXTURE_TARGET_LAUNCHER=$targetLauncher;FIXTURE_RECEIVER='true';FIXTURE_CLAIM=(Join-Path $caseRoot 'claim.json');FIXTURE_RESULT=(Join-Path $caseRoot 'result.json');FIXTURE_CONTINUATION=(Join-Path $caseRoot 'source-continued.txt');FIXTURE_FAILED_CHILD=(Join-Path $caseRoot 'failed-child.json');WATCHDOG_STREAMER_HEALTH_PATH='source-only-health';WATCHDOG_RESTART_COMMAND='source-only-restart'}
        # Only a reserved child may use the receiver shortcut; initial source
        # enters maintenance, and validation takes its explicit argument route.
        $variables.FIXTURE_RECEIVER=''
        $owner=Start-FixtureCmd (Join-Path $alias 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat') $variables
        try{
            if(-not $owner.WaitForExit(40000)){throw ('Fixture source owner hung: '+$case.Name)}
            if($owner.ExitCode -ne 0){throw ('Fixture source exited '+$owner.ExitCode+': '+$owner.StandardOutput.ReadToEnd()+$owner.StandardError.ReadToEnd())}
            Assert-True ($owner.ExitCode -eq 0) ($case.Name+': actual source maintenance BAT block must exit harmlessly.')
            Assert-True (-not(Test-Path -LiteralPath $variables.FIXTURE_CONTINUATION)) ($case.Name+': source must never continue after ownership transfer/hold.')
            $result=Get-Content -LiteralPath $variables.FIXTURE_RESULT -Raw | ConvertFrom-Json
            Assert-True $result.sourceOwnerLive ($case.Name+': immutable literal pin must preserve live original owner across alias retarget.')
            Assert-True ($result.generation -cne $result.originalGeneration) ($case.Name+': old generation must be revoked.')
            if($case.PinFailure){
                Assert-True (-not $result.success -and $result.phase -ceq 'handoff' -and -not(Test-Path -LiteralPath $variables.FIXTURE_CLAIM)) 'Pin failure retains durable revoked handoff and cannot create receiver health.'
                $failed=Get-Content -LiteralPath $variables.FIXTURE_FAILED_CHILD -Raw | ConvertFrom-Json
                Assert-True (-not(Test-StackLaunchProcessIdentity $failed)) 'Reserved child that failed pinning must be terminated by its retained exact handle.'
            }else{
                Assert-True $result.success ($case.Name+': maintenance handoff must succeed while original parent waits.')
                $claimed=Get-Content -LiteralPath $variables.FIXTURE_CLAIM -Raw | ConvertFrom-Json
                Assert-True ($claimed.mode -ceq $(if($case.Operation -ceq 'provision'){'normal'}else{'validation'})) ($case.Name+': exact actual child mode must be preserved.')
                Assert-True ($claimed.healthPath -ceq '' -and $claimed.restart -ceq '') ($case.Name+': child must not retain source health/restart paths.')
                if($case.Legacy){
                    Assert-True (-not $result.leaseAware -and $claimed.phase -ceq 'legacy_unclaimed' -and [string]::IsNullOrEmpty($claimed.generation)) 'Legacy rollback must be explicit, unclaimed, and have no inherited managed generation.'
                    Stop-FixtureProcesses $caseRoot
                    Remove-Item -LiteralPath $variables.FIXTURE_CLAIM
                    $nextBundle=New-FixtureBundle $caseRoot 'next-leased' $receiver
                    $variables.FIXTURE_RECEIVER='true'
                    $next=Start-FixtureCmd (Join-Path $nextBundle 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat') $variables ' --validation'
                    try{
                        $deadline=[DateTime]::UtcNow.AddSeconds(15);while(-not(Test-Path -LiteralPath $variables.FIXTURE_CLAIM) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
                        Assert-True (Test-Path -LiteralPath $variables.FIXTURE_CLAIM) 'Legacy/noGEN to leased validation roundtrip must enter after prior actors stop.'
                        $nextClaim=Get-Content -LiteralPath $variables.FIXTURE_CLAIM -Raw|ConvertFrom-Json
                        Assert-True ($nextClaim.phase -ceq 'starting' -and $nextClaim.generation -cne $result.generation) 'Roundtrip must create fresh lease proof, not promote legacy reservation.'
                    }finally{if(-not $next.HasExited){$next.Kill()};$next.Dispose()}
                }else{Assert-True ($claimed.phase -ceq 'starting' -and $claimed.generation -ceq $result.generation) ($case.Name+': new target must consume exactly the reserved generation.')}
                if($case.Operation -ceq 'provision'){Assert-True ($claimed.provisionEnabled -ceq 'false') 'Normal provision handoff must avoid recursive provisioning.'}
            }
            Write-Output ('PASS '+$case.Name)
        }finally{
            if(-not $owner.HasExited){$owner.Kill()};$owner.Dispose();Stop-FixtureProcesses $caseRoot
            if(Test-Path -LiteralPath $alias){$item=Get-Item -LiteralPath $alias -Force;if($item.LinkType -ne 'Junction'){throw 'Unsafe fixture alias cleanup.'};[IO.Directory]::Delete($alias)}
        }
    }
    foreach($name in $ownedSources){Assert-True ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -ceq $sourceHashes[$name]) ('Source changed during maintenance matrix: '+$name)}
    Assert-True ((Get-FileHash -LiteralPath $batPath).Hash -ceq $batHash) 'BAT source changed during maintenance matrix.'
    Write-Output ("Stack launch maintenance integration: {0} assertions passed, five real CMD/PS5.1 junction/maintenance scenarios; no AWS/network/native UE." -f $script:Assertions)
}finally{
    Stop-FixtureProcesses $scratch
    $absolute=[IO.Path]::GetFullPath($scratch)
    if(-not $absolute.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'scaleworld-maintenance-integration-*'){throw 'Unsafe fixture cleanup target.'}
    foreach($junction in @(Get-ChildItem -LiteralPath $absolute -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})){[IO.Directory]::Delete($junction.FullName)}
    if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
