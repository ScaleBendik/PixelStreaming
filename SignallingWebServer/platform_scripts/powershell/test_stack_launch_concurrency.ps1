[CmdletBinding()]
param([switch]$KeepFixtures, [switch]$MonitorOnly)

# Real local CMD/Windows PowerShell processes only. All registry/marker files,
# native children and canonical paths are disposable fixtures. No AWS, Unreal,
# ScheduledTasks or installed runtime is invoked.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$leaseSource = Join-Path $PSScriptRoot 'stack_launch_lease.ps1'
$entrySource = Join-Path $PSScriptRoot 'invoke_stack_launch_lease.ps1'
$processSource = Join-Path $PSScriptRoot 'stack_launch_processes.ps1'
$reservedSource=Join-Path $PSScriptRoot 'stack_launch_reserved_entry.ps1'
foreach ($dependency in @($leaseSource, $entrySource, $processSource,$reservedSource)) {
    if (-not (Test-Path -LiteralPath $dependency)) { throw "Concurrency dependency is missing: $dependency" }
}
$auditedSources=@($leaseSource,$entrySource,$processSource,$reservedSource,(Join-Path $PSScriptRoot 'scaleworld_process_helpers.ps1'),(Join-Path $PSScriptRoot 'recycle_intent_guard.ps1'),(Join-Path $PSScriptRoot 'invoke_stack_recycle.ps1'),(Join-Path $PSScriptRoot 'stack_recycle_monitor.ps1'),(Join-Path $PSScriptRoot 'invoke_stack_recycle_monitor.ps1'),(Join-Path $PSScriptRoot 'start_wilbur_leased.ps1'),(Join-Path $PSScriptRoot 'start_scaleworld.ps1'),(Join-Path $PSScriptRoot 'start_stack_watchdog.ps1'),(Join-Path $PSScriptRoot 'watchdog.ps1'),(Join-Path $PSScriptRoot 'ensure_repo_current.ps1'),(Join-Path $PSScriptRoot '..\cmd\start_wilbur_native.bat'),(Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat'),(Join-Path $PSScriptRoot '..\cmd\common.bat'))
$auditedSources+=@((Join-Path $PSScriptRoot 'stack_launch_maintenance.ps1'),(Join-Path $PSScriptRoot 'invoke_update_mode.ps1'),(Join-Path $PSScriptRoot 'invoke_provisioning_mode.ps1'),(Join-Path $PSScriptRoot 'install_pixelstreaming_runtime.ps1'))
$sourceProvenance=@($auditedSources|ForEach-Object{[pscustomobject]@{name=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()}})
$harnessHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
. $leaseSource
. $reservedSource
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$portableNode=Join-Path $PSScriptRoot '..\cmd\node\node.exe'
$nodeExe=if(Test-Path -LiteralPath $portableNode){[IO.Path]::GetFullPath($portableNode)}else{(Get-Command node.exe -ErrorAction Stop).Source}
$nodeSource=if(Test-Path -LiteralPath $portableNode){'runtime-portable'}else{'workstation-path'}
$nodeVersion=& $nodeExe --version
$nodeSha256=(Get-FileHash -LiteralPath $nodeExe -Algorithm SHA256).Hash.ToLowerInvariant()
$fixtureParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$fixtureBase = Join-Path $fixtureParent ('scaleworld-stack-concurrency-' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$owned = [Collections.Generic.List[object]]::new()
$receipts = [Collections.Generic.List[string]]::new()
$results = [Collections.Generic.List[object]]::new()
$checks = 0
$lastCaseCheck = 0
New-Item -ItemType Directory -Path $fixtureBase -Force | Out-Null

function Write-FixtureText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Assert-Local([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Body, [string]$Message) {
    $threw = $false
    try { & $Body | Out-Null } catch { $threw = $true }
    Assert-Local $threw $Message
}
function Wait-File([string]$Path, [int]$Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($Path.EndsWith('.gate-held') -and (Test-Path -LiteralPath $Path.Replace('.gate-held','.denied'))) {
            throw ('Fixture native gate failed: '+[IO.File]::ReadAllText($Path.Replace('.gate-held','.denied')))
        }
        if ([DateTime]::UtcNow -gt $deadline) { throw "Fixture file did not arrive: $(Split-Path -Leaf $Path)" }
        Start-Sleep -Milliseconds 40
    }
}
function Start-Owned([string]$FileName, [string]$Arguments, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $fixtureBase) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName; $info.Arguments = $Arguments; $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start(); $null = $process.Handle
    $item = [pscustomobject]@{ Process=$process; Stdout=$process.StandardOutput.ReadToEndAsync(); Stderr=$process.StandardError.ReadToEndAsync() }
    $owned.Add($item); return $item
}
function Wait-Owned($Child, [int]$Expected = 0, [int]$Seconds = 15) {
    if (-not $Child.Process.WaitForExit($Seconds * 1000)) { throw "Fixture process $($Child.Process.Id) did not finish." }
    if ($Child.Process.ExitCode -ne $Expected) {
        $errorText=if($null -eq $Child.Stderr){'stderr is inherited'}elseif($Child.Stderr.IsCompleted){$Child.Stderr.Result}else{'stderr stream is still open'}
        Assert-Local $false ("Unexpected fixture exit {0}, expected {1}: {2}" -f $Child.Process.ExitCode,$Expected,$errorText)
    } else { Assert-Local $true 'Fixture returned the expected exit code.' }
}
function Track-ChildPid([int]$ProcessId,$ExpectedIdentity=$null) {
    $process = [Diagnostics.Process]::GetProcessById($ProcessId)
    $null = $process.Handle
    if($null -ne $ExpectedIdentity){
        $expected=[DateTimeOffset]::Parse([string]$ExpectedIdentity.creationUtc).UtcDateTime
        if($process.HasExited -or [Math]::Floor([decimal]$process.StartTime.ToUniversalTime().Ticks/10) -ne [Math]::Floor([decimal]$expected.Ticks/10) -or (Get-StackLaunchCanonicalPath $process.MainModule.FileName) -ine (Get-StackLaunchCanonicalPath $ExpectedIdentity.executablePath)){$process.Dispose();throw 'Fixture child identity changed before its retained handle was tracked.'}
    }
    $owned.Add([pscustomobject]@{ Process=$process; Stdout=$null; Stderr=$null })
}
function Get-EntryIdentity($Fixture, [int]$ProcessId) {
    $identity = Get-StackLaunchProcessIdentity -ProcessId $ProcessId
    $identity | Add-Member -NotePropertyName entryPath -NotePropertyValue $Fixture.Scope.EntryPath -Force
    return $identity
}
function Read-FixtureLease($Scope) {
    $handle=Enter-StackLaunchLeaseLock $Scope
    try{return Read-StackLaunchLease $Scope}finally{Exit-StackLaunchLeaseLock $handle}
}
function New-Fixture([string]$Name) {
    $base = Join-Path $fixtureBase $Name
    $root = Join-Path $base 'SignallingWebServer'
    $cmd = Join-Path $root 'platform_scripts\cmd'
    New-Item -ItemType Directory -Path (Join-Path $cmd 'node'),(Join-Path $root 'dist'),(Join-Path $base 'state') -Force | Out-Null
    Copy-Item -LiteralPath $nodeExe -Destination (Join-Path $cmd 'node\node.exe')
    Write-FixtureText (Join-Path $root 'dist\index.js') @'
const fs=require('fs');
const timer=setInterval(()=>{if(process.env.SW_TEST_NODE_STOP&&fs.existsSync(process.env.SW_TEST_NODE_STOP)){clearInterval(timer);process.exit(0);}},40);
'@
    $fixture = [pscustomobject]@{ Base=$base; Root=$root; Scope=(Get-StackLaunchLeaseScope -RepoRoot $root -InstallBase $base) }
    Write-FixtureText $fixture.Scope.EntryPath @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
"%SW_TEST_PS%" -NoProfile -ExecutionPolicy Bypass -File "%SW_TEST_ENTRY%" -Mode Enter -LaunchMode "%SW_TEST_MODE%" -RepoRoot "%SW_TEST_ROOT%" -InstallBase "%SW_TEST_BASE%" -OutputFile "%SW_TEST_RECEIPT%"
if errorlevel 10 goto skipped
if errorlevel 1 exit /b 1
for /f "usebackq delims=" %%L in ("%SW_TEST_RECEIPT%") do %%L
set "SCALEWORLD_STACK_LAUNCH_GRANT="
if not defined SCALEWORLD_STACK_LAUNCH_GENERATION exit /b 1
"%SW_TEST_PS%" -NoProfile -ExecutionPolicy Bypass -File "%SW_TEST_PRODUCER%"
exit /b %errorlevel%
:skipped
> "%SW_TEST_SKIPPED%" echo Skip
exit /b 0
'@
    return $fixture
}

$producerPath = Join-Path $fixtureBase 'fixture-producer.ps1'
Write-FixtureText $producerPath @'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. $env:SW_TEST_LEASE
$utf8=[Text.UTF8Encoding]::new($false)
$scope=Get-StackLaunchLeaseScope -RepoRoot $env:SW_TEST_ROOT -InstallBase $env:SW_TEST_BASE
$owner=Get-StackLaunchOwnerIdentity $scope
$generation=$env:SCALEWORLD_STACK_LAUNCH_GENERATION
$record=[pscustomobject]@{generation=$generation; owner=$owner; producerPid=$PID}
[IO.File]::WriteAllText($env:SW_TEST_ENTERED,($record|ConvertTo-Json -Depth 6),$utf8)
if($env:SW_TEST_ACTION -eq 'monitor-parent'){
    while(-not(Test-Path -LiteralPath $env:SW_TEST_MONITOR_CONFIG)){Start-Sleep -Milliseconds 40}
    $helper=Start-Process -FilePath $env:SW_TEST_PS -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$env:SW_TEST_MONITOR_WORKER+'"') -WorkingDirectory $scope.RepoRoot -PassThru -WindowStyle Hidden
    [IO.File]::WriteAllText($env:SW_TEST_MONITOR_WORKER_PID,[string]$helper.Id,$utf8)
    while($true){Start-Sleep -Milliseconds 100}
}
if($env:SW_TEST_ACTION -in @('complete','partial')){
    $node=Start-Process -FilePath $scope.NodePath -ArgumentList '.\dist\index.js' -WorkingDirectory $scope.RepoRoot -PassThru -WindowStyle Hidden
    $nodeIdentity=Get-StackLaunchProcessIdentity -ProcessId $node.Id
    [IO.File]::WriteAllText($env:SW_TEST_NODE_RECORD,($nodeIdentity|ConvertTo-Json),$utf8)
    $handle=Enter-StackLaunchLeaseLock $scope
    try{[void](Register-StackLaunchNode -Scope $scope -GenerationId $generation -NodeIdentity $nodeIdentity -LockHandle $handle)}finally{Exit-StackLaunchLeaseLock $handle}
    if($env:SW_TEST_ACTION -eq 'complete'){
        $handle=Enter-StackLaunchLeaseLock $scope
        try{[void](Complete-StackLaunchAttempt -Scope $scope -GenerationId $generation -OwnerIdentity $owner -NodeIdentity $nodeIdentity -LockHandle $handle)}finally{Exit-StackLaunchLeaseLock $handle}
        [IO.File]::WriteAllText($env:SW_TEST_COMPLETED,'complete',$utf8)
        exit 0
    }
}
if($env:SW_TEST_ACTION -in @('native','native-held')){
    if($env:SW_TEST_ACTION -eq 'native'){
        while(-not(Test-Path -LiteralPath $env:SW_TEST_RELEASE)){Start-Sleep -Milliseconds 40}
    }
    $gate=$null
    try{
        $gate=Enter-StackLaunchGate -RepoRoot $scope.RepoRoot -InstallBase $scope.InstallBase -GenerationId $generation
        [IO.File]::WriteAllText($env:SW_TEST_GATE_HELD,'held',$utf8)
        if($env:SW_TEST_ACTION -eq 'native-held'){
            while(-not(Test-Path -LiteralPath $env:SW_TEST_RELEASE)){Start-Sleep -Milliseconds 40}
        }
        $psi=[Diagnostics.ProcessStartInfo]::new()
        $psi.FileName=$env:SW_TEST_PS
        $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$env:SW_TEST_SENTINEL+'"'
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $child=[Diagnostics.Process]::new();$child.StartInfo=$psi
        $null=$child.Start();$null=$child.Handle
        [IO.File]::WriteAllText($env:SW_TEST_CHILD_BORN,($child.StartTime.ToUniversalTime().ToString('o')),$utf8)
    }catch{
        [IO.File]::WriteAllText($env:SW_TEST_NATIVE_DENIED,$_.Exception.Message,$utf8)
        exit 0
    }finally{if($null -ne $gate){Exit-StackLaunchGate $gate}}
    if(-not $child.WaitForExit(10000)){ $child.Kill(); throw 'Sentinel child timed out.' }
    $exitCode=$child.ExitCode;$child.Dispose()
    if($exitCode -ne 0){throw 'Sentinel failed.'}
    exit 0
}
while(-not(Test-Path -LiteralPath $env:SW_TEST_RELEASE)){Start-Sleep -Milliseconds 40}
'@
$sentinelPath = Join-Path $fixtureBase 'native-sentinel.ps1'
Write-FixtureText $sentinelPath '[IO.File]::WriteAllText($env:SW_TEST_MUTATION,''native-created'')'

function Start-Launch($Fixture, [string]$Name, [string]$Action='hold', [string]$Mode='normal', [string]$Generation='', [string]$Grant='', [string]$ReservedKind='', $LockHandle=$null) {
    $run = Join-Path $Fixture.Base $Name
    $receipt = Join-Path $fixtureBase ('scaleworld-stack-launch-' + [Guid]::NewGuid().ToString('D') + '.env')
    $receipts.Add($receipt)
    $files = [pscustomobject]@{ Entered=$run+'.entered.json'; Skipped=$run+'.skipped'; Release=$run+'.release'; GateHeld=$run+'.gate-held'; Denied=$run+'.denied'; Mutation=$run+'.mutation'; ChildBorn=$run+'.child-born'; Node=$run+'.node.json'; NodeStop=$run+'.node-stop'; Completed=$run+'.completed' }
    $environment = @{
        SW_TEST_PS=$psExe; SW_TEST_ENTRY=$entrySource; SW_TEST_LEASE=$leaseSource
        SW_TEST_ROOT=$Fixture.Root; SW_TEST_BASE=$Fixture.Base; SW_TEST_RECEIPT=$receipt
        SW_TEST_PRODUCER=$producerPath; SW_TEST_SENTINEL=$sentinelPath; SW_TEST_ACTION=$Action; SW_TEST_MODE=$Mode
        SW_TEST_ENTERED=$files.Entered; SW_TEST_SKIPPED=$files.Skipped; SW_TEST_RELEASE=$files.Release
        SW_TEST_GATE_HELD=$files.GateHeld; SW_TEST_NATIVE_DENIED=$files.Denied; SW_TEST_MUTATION=$files.Mutation
        SW_TEST_CHILD_BORN=$files.ChildBorn
        SW_TEST_NODE_RECORD=$files.Node; SW_TEST_NODE_STOP=$files.NodeStop; SW_TEST_COMPLETED=$files.Completed
        SW_TEST_MONITOR_CONFIG=(Join-Path $Fixture.Base 'monitor-config.json')
        SW_TEST_MONITOR_WORKER=(Join-Path $Fixture.Root 'platform_scripts\powershell\invoke_stack_recycle.ps1')
        SW_TEST_MONITOR_WORKER_PID=(Join-Path $Fixture.Base 'monitor-worker.pid')
        SCALEWORLD_STACK_LAUNCH_GENERATION=$Generation; SCALEWORLD_STACK_LAUNCH_GRANT=$Grant
        TEMP=$fixtureBase; TMP=$fixtureBase
    }
    if($ReservedKind){
        $identity=Start-StackLaunchReservedEntry -Scope $Fixture.Scope -Grant $Grant -Kind $ReservedKind -LockHandle $LockHandle -EnvironmentOverrides $environment
        $process=[Diagnostics.Process]::GetProcessById([int]$identity.pid);$null=$process.Handle
        $child=[pscustomobject]@{Process=$process;Stdout=$null;Stderr=$null};$owned.Add($child)
    }else{$child = Start-Owned $env:ComSpec ('/d /s /c ""'+$Fixture.Scope.EntryPath+'""') $environment $Fixture.Root}
    return [pscustomobject]@{ Child=$child; Files=$files; Receipt=$receipt }
}
function Release-Launch($Launch) { Write-FixtureText $Launch.Files.Release 'release'; Wait-Owned $Launch.Child }
function Stop-FixtureNode($Launch) {
    Wait-File $Launch.Files.Node
    $identity = Get-Content -LiteralPath $Launch.Files.Node -Raw | ConvertFrom-Json
    Track-ChildPid $identity.pid
    Write-FixtureText $Launch.Files.NodeStop 'stop'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(Test-StackLaunchProcessIdentity $identity){if([DateTime]::UtcNow -gt $deadline){throw 'Fixture Node did not stop.'};Start-Sleep -Milliseconds 40}
}
function Add-Result([string]$Name) {
    $results.Add([pscustomobject]@{case=$Name;status='passed';assertions=($script:checks-$script:lastCaseCheck)})
    $script:lastCaseCheck=$script:checks
}

function New-MonitorFixture([string]$Name, [string]$Stage='after-begin', [int]$DeadlineSeconds=6, [switch]$Descendant) {
    $fixture=New-Fixture ('monitor-'+$Name)
    $fixturePs=Join-Path $fixture.Root 'platform_scripts\powershell'
    New-Item -ItemType Directory -Path $fixturePs -Force|Out-Null
    foreach($name in @('stack_launch_lease.ps1','stack_launch_processes.ps1','scaleworld_process_helpers.ps1','stack_launch_reserved_entry.ps1','recycle_intent_guard.ps1','stack_recycle_monitor.ps1','invoke_stack_recycle_monitor.ps1')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $fixturePs $name)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_wilbur_native.bat') -Destination (Join-Path $fixture.Root 'platform_scripts\cmd\start_wilbur_native.bat')
    # The production shutdown function is unconditionally replaced in this
    # disposable copy. There is no production flag or fallback to shutdown.exe.
    $fakeStop=Join-Path $fixture.Base 'fake-shutdown.jsonl'
    $fakeShutdown=@'
function Invoke-StackRecycleMonitorLocalShutdown {
    $fixtureScope=Get-StackLaunchLeaseScope $env:SW_TEST_ROOT $env:SW_TEST_BASE
    $stored=Read-StackLaunchLease $fixtureScope
    $diagnostics=@(Get-ChildItem -LiteralPath (Join-Path $fixtureScope.InstallBase 'state') -Filter 'stack-recycle-monitor-fault-*.json' -File)
    if($stored.phase -cne 'stopping' -or $diagnostics.Count -ne 1){throw 'Fake stop called before the durable stopping fence and fault.'}
    $value=[pscustomobject]@{action='fake_shutdown';phase=$stored.phase;diagnosticCount=$diagnostics.Count}
    [IO.File]::AppendAllText($env:SW_TEST_FAKE_STOP,($value|ConvertTo-Json -Compress)+[Environment]::NewLine)
}
# Diagnostic-only adapters in this disposable copy retain the actual function
# result/exception without changing its return value, deadline or authority.
function Write-FixtureMonitorTrace([string]$Operation,[string]$Result,[string]$ErrorText='') {
    try{
        $value=[pscustomobject]@{observedUtc=[DateTimeOffset]::UtcNow.ToString('o');operation=$Operation;result=$Result;error=$ErrorText}
        [IO.File]::AppendAllText((Join-Path $env:SW_TEST_BASE 'monitor-trace.jsonl'),($value|ConvertTo-Json -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    }catch{}
}
$script:fixtureActualDisposition=${function:Get-StackRecycleMonitorDisposition}
function Get-StackRecycleMonitorDisposition {
    param($Scope,$Intent,$MonitorIdentity,$RecyclerIdentity,[string]$GenerationId,$LockHandle)
    try{$value=& $script:fixtureActualDisposition @PSBoundParameters;Write-FixtureMonitorTrace 'disposition' ([string]$value);return $value}
    catch{Write-FixtureMonitorTrace 'disposition' 'exception' $_.Exception.Message;throw}
}
$script:fixtureActualDeadline=${function:Invoke-StackRecycleMonitorDeadline}
function Invoke-StackRecycleMonitorDeadline {
    param($Scope,$Intent,$MonitorIdentity,$RecyclerIdentity,[string]$GenerationId,[string]$MonitorId,$LockHandle)
    try{$value=& $script:fixtureActualDeadline @PSBoundParameters;Write-FixtureMonitorTrace 'deadline' ([string]$value);return $value}
    catch{Write-FixtureMonitorTrace 'deadline' 'exception' $_.Exception.Message;throw}
}
$script:fixtureActualJsonWriter=${function:Write-StackRecycleMonitorCreateNewJson}
function Write-StackRecycleMonitorCreateNewJson {
    param([string]$Path,$Value)
    & $script:fixtureActualJsonWriter @PSBoundParameters
    if($Path.IndexOf('\recycle-monitor-ready\',[StringComparison]::OrdinalIgnoreCase) -ge 0){
        try{[IO.File]::WriteAllText((Join-Path $env:SW_TEST_BASE 'monitor-ready-retained.json'),($Value|ConvertTo-Json -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))}catch{}
    }
}
'@
    $modulePath=Join-Path $fixturePs 'stack_recycle_monitor.ps1'
    Write-FixtureText $modulePath ([IO.File]::ReadAllText($modulePath)+[Environment]::NewLine+$fakeShutdown)
    $workerPath=Join-Path $fixturePs 'invoke_stack_recycle.ps1'
    Write-FixtureText $workerPath @'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_recycle_monitor.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_processes.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_reserved_entry.ps1')
$config=Get-Content -LiteralPath $env:SW_TEST_MONITOR_CONFIG -Raw|ConvertFrom-Json
$scope=Get-StackLaunchLeaseScope $config.repoRoot $config.installBase
$env:SW_TEST_ROOT=$scope.RepoRoot;$env:SW_TEST_BASE=$scope.InstallBase;$env:SW_TEST_FAKE_STOP=$config.fakeStop
foreach($field in @('nativePause','nativeRelease','nativeNodeRecord','nativeRace')){
    if($null -ne $config.PSObject.Properties[$field]){
        switch($field){
            nativePause {$env:SW_TEST_MONITOR_NATIVE_PAUSE=$config.nativePause}
            nativeRelease {$env:SW_TEST_MONITOR_NATIVE_RELEASE=$config.nativeRelease}
            nativeNodeRecord {$env:SW_TEST_MONITOR_NATIVE_NODE=$config.nativeNodeRecord}
            nativeRace {$env:SW_TEST_MONITOR_NATIVE_RACE=[string]$config.nativeRace}
        }
    }
}
$lock=$null
try{
    $lock=Enter-StackLaunchLeaseLock $scope
    $helper=Get-StackLaunchProcessIdentity -ProcessId $PID
    $intent=Read-ScaleWorldRecycleIntent -MarkerPath $config.markerPath -ExpectedRecycleId $config.recycleId -ExpectedSourcePid $config.source.pid -ExpectedHelperLaunchId $config.helperLaunchId -ExpectedLaunchGenerationId $config.sourceGeneration -ExpectedSourceCreationUtc $config.source.creationUtc
    $armed=Start-StackRecycleMonitor -Scope $scope -Intent $intent -RecyclerIdentity $helper -PlannedGenerationId $config.generation -DeadlineSeconds $config.deadlineSeconds
    $recycle=Begin-StackLaunchRecycle -Scope $scope -RecycleId $config.recycleId -RecyclerIdentity $helper -PlannedGenerationId $config.generation -MonitorIdentity $armed.MonitorIdentity -HelperLaunchId $config.helperLaunchId -LockHandle $lock
    if($config.stage -cin @('after-producers','after-absence','producer-descendant')){
        Stop-StackLaunchProducers -RepoRoot $scope.RepoRoot -OwnerIdentity $config.source -RecyclerPid $PID
    }
    if($config.stage -cin @('marker-before-cmd','before-pin','after-pin','partial-replacement','after-node-pin','unregistered-node')){
        $marker=$intent.Marker|Select-Object *
        $marker.phase='replacement_started'
        $marker|Add-Member -NotePropertyName replacementStartedAtUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o'))
        [IO.File]::WriteAllText($config.markerPath,($marker|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    }
    $replacement=$null
    if($config.stage -cin @('before-pin','after-pin','partial-replacement','after-node-pin','unregistered-node')){
        $environment=@{}
        foreach($property in $config.replacementEnvironment.PSObject.Properties){$environment[$property.Name]=[string]$property.Value}
        if($config.stage -ceq 'before-pin'){
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$env:ComSpec
            $start.Arguments='/d /s /c ""'+$scope.EntryPath+'""';$start.WorkingDirectory=$scope.RepoRoot
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            foreach($key in $environment.Keys){$start.EnvironmentVariables[$key]=[string]$environment[$key]}
            $child=[Diagnostics.Process]::Start($start);$null=$child.Handle
            $replacement=Get-StackLaunchProcessIdentity -ProcessId $child.Id
        }else{
            $replacement=Start-StackLaunchReservedEntry -Scope $scope -Grant $recycle.Grant -Kind recovery -LockHandle $lock -EnvironmentOverrides $environment
        }
    }
    if($config.stage -cin @('partial-replacement','after-node-pin','unregistered-node')){
        Exit-StackLaunchLeaseLock $lock;$lock=$null
        $until=[DateTime]::UtcNow.AddSeconds(12)
        while(-not(Test-Path -LiteralPath $config.replacementEntered)){if([DateTime]::UtcNow -gt $until){throw 'Replacement did not claim its exact reserved entry.'};Start-Sleep -Milliseconds 40}
        if($config.stage -ceq 'after-node-pin'){
            do{
                $readLock=Enter-StackLaunchLeaseLock $scope
                try{$current=Read-StackLaunchLease $scope}finally{Exit-StackLaunchLeaseLock $readLock}
                if($null -ne $current.activeNode){break}
                if([DateTime]::UtcNow -gt $until){throw 'Replacement did not register a live Node.'}
                Start-Sleep -Milliseconds 40
            }while($true)
        }elseif($config.stage -ceq 'unregistered-node'){
            $node=Start-Process -FilePath $scope.NodePath -ArgumentList '.\dist\index.js' -WorkingDirectory $scope.RepoRoot -PassThru -WindowStyle Hidden
            $unregistered=Get-StackLaunchProcessIdentity -ProcessId $node.Id
            [IO.File]::WriteAllText($config.unregisteredNode,($unregistered|ConvertTo-Json))
        }
    }
    $record=[pscustomobject]@{monitorIdentity=$armed.MonitorIdentity;monitorId=$armed.MonitorId;helperIdentity=$helper;generation=$recycle.Grant;replacement=$replacement;intent=$intent}
    [IO.File]::WriteAllText($config.checkpoint,($record|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))
    while($true){Start-Sleep -Milliseconds 100}
}catch{
    [IO.File]::WriteAllText($config.failure,$_.Exception.Message)
    exit 1
}finally{if($null -ne $lock){Exit-StackLaunchLeaseLock $lock}}
'@
    $initialAction=if($Descendant){'monitor-parent'}else{'hold'}
    $old=Start-Launch $fixture 'original' $initialAction
    Wait-File $old.Files.Entered
    $initial=Get-Content -LiteralPath $old.Files.Entered -Raw|ConvertFrom-Json
    $generation=[Guid]::NewGuid().ToString('D');$operation=[Guid]::NewGuid().ToString('D');$dispatch=[Guid]::NewGuid().ToString('D')
    $markerPath=Join-Path $fixture.Base 'state\instance-agent-recycle-marker.json'
    $marker=[pscustomobject]@{schemaVersion=2;phase='intent';recycleId=$operation;helperLaunchId=$dispatch;sourcePid=$initial.owner.pid;sourceLaunchGenerationId=$initial.generation;sourceCreationUtc=$initial.owner.creationUtc;reason='fixture';requestedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');requestedAtMs=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}
    Write-FixtureText $markerPath ($marker|ConvertTo-Json -Depth 8)
    $replacementRun=Join-Path $fixture.Base 'replacement'
    $receipt=Join-Path $fixtureBase ('scaleworld-stack-launch-'+[Guid]::NewGuid().ToString('D')+'.env');$receipts.Add($receipt)
    $replacementAction=if($Stage -ceq 'after-node-pin'){'partial'}else{'hold'}
    $environment=@{SW_TEST_PS=$psExe;SW_TEST_ENTRY=$entrySource;SW_TEST_LEASE=$leaseSource;SW_TEST_ROOT=$fixture.Root;SW_TEST_BASE=$fixture.Base;SW_TEST_RECEIPT=$receipt;SW_TEST_PRODUCER=$producerPath;SW_TEST_SENTINEL=$sentinelPath;SW_TEST_ACTION=$replacementAction;SW_TEST_MODE='recovery';SW_TEST_ENTERED=$replacementRun+'.entered.json';SW_TEST_SKIPPED=$replacementRun+'.skipped';SW_TEST_RELEASE=$replacementRun+'.release';SW_TEST_GATE_HELD=$replacementRun+'.gate-held';SW_TEST_NATIVE_DENIED=$replacementRun+'.denied';SW_TEST_MUTATION=$replacementRun+'.mutation';SW_TEST_CHILD_BORN=$replacementRun+'.child-born';SW_TEST_NODE_RECORD=$replacementRun+'.node.json';SW_TEST_NODE_STOP=$replacementRun+'.node-stop';SW_TEST_COMPLETED=$replacementRun+'.completed';SCALEWORLD_STACK_LAUNCH_GENERATION=$generation;SCALEWORLD_STACK_LAUNCH_GRANT=$generation;TEMP=$fixtureBase;TMP=$fixtureBase}
    $config=[pscustomobject]@{repoRoot=$fixture.Root;installBase=$fixture.Base;source=$initial.owner;sourceGeneration=$initial.generation;generation=$generation;recycleId=$operation;helperLaunchId=$dispatch;markerPath=$markerPath;fakeStop=$fakeStop;deadlineSeconds=$DeadlineSeconds;stage=$Stage;checkpoint=(Join-Path $fixture.Base 'monitor-checkpoint.json');failure=(Join-Path $fixture.Base 'monitor-failure.txt');replacementEnvironment=$environment;replacementEntered=$replacementRun+'.entered.json';unregisteredNode=(Join-Path $fixture.Base 'unregistered-node.json')}
    return [pscustomobject]@{Fixture=$fixture;Old=$old;Config=$config;ConfigPath=(Join-Path $fixture.Base 'monitor-config.json');WorkerPath=$workerPath;ModulePath=$modulePath;Worker=$null;Monitor=$null;Record=$null;Descendant=[bool]$Descendant}
}

function Start-MonitorFixture($Test, [switch]$ExpectArmFailure) {
    Write-FixtureText $Test.ConfigPath ($Test.Config|ConvertTo-Json -Depth 12)
    if($Test.Descendant){
        $pidFile=Join-Path $Test.Fixture.Base 'monitor-worker.pid';Wait-File $pidFile
        $workerProcess=[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidFile));$null=$workerProcess.Handle
        $Test.Worker=[pscustomobject]@{Process=$workerProcess;Stdout=$null;Stderr=$null};$owned.Add($Test.Worker)
    }else{
        $Test.Worker=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+$Test.WorkerPath+'"') @{SW_TEST_MONITOR_CONFIG=$Test.ConfigPath} $Test.Fixture.Root
    }
    if($ExpectArmFailure){
        Wait-Owned $Test.Worker 1
        if(-not(Test-Path -LiteralPath $Test.Config.failure)){throw ('Expected arm failure did not reach its fixture catch: '+$Test.Worker.Stderr.Result)}
        return
    }
    $until=[DateTime]::UtcNow.AddSeconds(15)
    while(-not(Test-Path -LiteralPath $Test.Config.checkpoint)){
        if(Test-Path -LiteralPath $Test.Config.failure){throw ('Monitor fixture failed: '+[IO.File]::ReadAllText($Test.Config.failure))}
        if($Test.Worker.Process.HasExited){
            $errorText=if($null -ne $Test.Worker.Stderr -and $Test.Worker.Stderr.IsCompleted){$Test.Worker.Stderr.Result}else{'stderr inherited or still open'}
            throw ('Monitor fixture '+$Test.Config.stage+' helper exited before checkpoint: '+$errorText)
        }
        if([DateTime]::UtcNow -gt $until){throw ('Monitor fixture '+$Test.Config.stage+' checkpoint did not arrive.')}
        Start-Sleep -Milliseconds 40
    }
    $Test.Record=Get-Content -LiteralPath $Test.Config.checkpoint -Raw|ConvertFrom-Json
    $monitorProcess=[Diagnostics.Process]::GetProcessById([int]$Test.Record.monitorIdentity.pid);$null=$monitorProcess.Handle
    $Test.Monitor=[pscustomobject]@{Process=$monitorProcess;Stdout=$null;Stderr=$null};$owned.Add($Test.Monitor)
    if($null -ne $Test.Record.replacement){try{Track-ChildPid $Test.Record.replacement.pid $Test.Record.replacement}catch{}}
}
function Stop-MonitorFixtureHelper($Test) {
    if(-not $Test.Worker.Process.HasExited){$Test.Worker.Process.Kill();[void]$Test.Worker.Process.WaitForExit(5000)}
}
function Save-MonitorFixtureFailure($Test,[int]$WaitSeconds) {
    $destination=[IO.Path]::GetFullPath((Join-Path $fixtureParent ('..\..\outputs\stack-concurrency-failure-'+[Guid]::NewGuid().ToString('N'))))
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    $monitorExited=$null;$monitorExitCode=$null;$helperExited=$null;$helperExitCode=$null
    try{$monitorExited=$Test.Monitor.Process.HasExited;if($monitorExited){$monitorExitCode=$Test.Monitor.Process.ExitCode}}catch{}
    try{$helperExited=$Test.Worker.Process.HasExited;if($helperExited){$helperExitCode=$Test.Worker.Process.ExitCode}}catch{}
    $files=@($Test.Config.checkpoint,$Test.Config.markerPath,$Test.Fixture.Scope.LeasePath,(Join-Path $Test.Fixture.Base 'monitor-trace.jsonl'),(Join-Path $Test.Fixture.Base 'monitor-ready-retained.json'))
    $files+=@(Get-ChildItem -LiteralPath (Join-Path $Test.Fixture.Base 'state') -Filter 'stack-recycle-monitor-fault-*.json' -File|Select-Object -ExpandProperty FullName)
    $snapshots=@(foreach($file in $files){
        if(Test-Path -LiteralPath $file -PathType Leaf){
            $item=Get-Item -LiteralPath $file
            if($item.Length -le 32768){Copy-Item -LiteralPath $file -Destination (Join-Path $destination $item.Name);[pscustomobject]@{name=$item.Name;sha256=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant();lastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}}
        }
    })
    $processes=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{([string]$_.CommandLine).IndexOf($Test.Fixture.Base,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.ExecutablePath).StartsWith($Test.Fixture.Base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}|Select-Object ProcessId,ParentProcessId,CreationDate,Name,ExecutablePath,CommandLine)
    $value=[pscustomobject]@{schemaVersion=1;stage=$Test.Config.stage;observedUtc=[DateTimeOffset]::UtcNow.ToString('o');waitSeconds=$WaitSeconds;armedDeadlineSeconds=$Test.Config.deadlineSeconds;monitorExitedBeforeCleanup=$monitorExited;monitorExitCode=$monitorExitCode;helperExitedBeforeCleanup=$helperExited;helperExitCode=$helperExitCode;files=$snapshots;fixtureProcesses=$processes}
    Write-FixtureText (Join-Path $destination 'failure.json') ($value|ConvertTo-Json -Depth 9)
    Write-Warning ('Local fixture failure diagnostics retained in '+[IO.Path]::GetFileName($destination)+'.')
}
function Wait-MonitorFakeStop($Test,[int]$Seconds=20) {
    try{Wait-File $Test.Config.fakeStop $Seconds}catch{
        try{Save-MonitorFixtureFailure $Test $Seconds}catch{Write-Warning 'Could not retain all local monitor fixture diagnostics.'}
        Stop-MonitorFixtureHelper $Test
        if($null -ne $Test.Monitor -and -not $Test.Monitor.Process.HasExited){$Test.Monitor.Process.Kill();[void]$Test.Monitor.Process.WaitForExit(5000)}
        $diagnostic=if($null -ne $Test.Worker.Stderr -and $Test.Worker.Stderr.Wait(2000)){$Test.Worker.Stderr.Result}else{'stderr inherited or still open'}
        $stdout=if($null -ne $Test.Worker.Stdout -and $Test.Worker.Stdout.Wait(2000)){$Test.Worker.Stdout.Result}else{'stdout inherited or still open'}
        throw ('Monitor fixture '+$Test.Config.stage+' did not reach fake shutdown: '+$diagnostic+' '+$stdout)
    }
}
function Stop-MonitorFixture($Test) {
    Stop-MonitorFixtureHelper $Test
    if($null -ne $Test.Monitor -and -not $Test.Monitor.Process.HasExited){$Test.Monitor.Process.Kill();[void]$Test.Monitor.Process.WaitForExit(5000)}
    if(-not $Test.Old.Child.Process.HasExited){Release-Launch $Test.Old}
    if(Test-Path -LiteralPath $Test.Config.unregisteredNode){
        $pin=Get-Content -LiteralPath $Test.Config.unregisteredNode -Raw|ConvertFrom-Json
        $module=New-Module -ScriptBlock {param($Source). $Source} -ArgumentList $processSource
        try{& $module {param($Identity)Stop-StackLaunchProcessIdentity $Identity} $pin}finally{Remove-Module $module -Force}
    }
}

function Invoke-MonitorFailureHarness {
    $armFailure=New-MonitorFixture 'prearm-failure'
    $before=[IO.File]::ReadAllText($armFailure.Fixture.Scope.LeasePath)
    Write-FixtureText (Join-Path (Split-Path -Parent $armFailure.ModulePath) 'invoke_stack_recycle_monitor.ps1') 'throw "Injected monitor pre-arm failure."'
    Start-MonitorFixture $armFailure -ExpectArmFailure
    Assert-Local ([IO.File]::ReadAllText($armFailure.Fixture.Scope.LeasePath) -ceq $before -and -not(Test-Path -LiteralPath $armFailure.Config.fakeStop) -and -not(Test-Path -LiteralPath $armFailure.Config.checkpoint)) 'Failed monitor arm revoked the generation or requested shutdown.'
    Stop-MonitorFixture $armFailure;Add-Result 'recycle-monitor-prearm-failure-zero-revocation'

    foreach($stage in @('after-begin','after-producers','after-absence','marker-before-cmd','before-pin','after-pin','partial-replacement','hung-lock','producer-descendant')){
        $deadline=if($stage -cin @('after-producers','after-absence','producer-descendant')){18}elseif($stage -ceq 'partial-replacement'){10}else{6}
        $test=New-MonitorFixture $stage $stage $deadline -Descendant:($stage -ceq 'producer-descendant')
        Start-MonitorFixture $test
        if($stage -ceq 'producer-descendant'){
            Assert-Local $test.Old.Child.Process.HasExited 'Producer cancellation did not stop the old full-stack parent.'
            Assert-Local (-not $test.Worker.Process.HasExited -and -not $test.Monitor.Process.HasExited) 'Producer cancellation killed the protected recycler/monitor branch.'
        }
        if($stage -cne 'hung-lock'){Stop-MonitorFixtureHelper $test}
        Wait-MonitorFakeStop $test 25
        Assert-Local (-not(Test-StackLaunchProcessIdentity $test.Record.helperIdentity)) 'Monitor deadline did not terminate its exact hung helper or detect the killed helper.'
        $lease=Read-FixtureLease $test.Fixture.Scope
        Assert-Local ($lease.phase -ceq 'stopping' -and $lease.generationId -ceq $test.Record.generation) 'Orphan deadline did not fence the exact replacement generation.'
        Assert-Local (@(Get-Content -LiteralPath $test.Config.fakeStop).Count -eq 1) 'Monitor requested more than one fake shutdown before its retry interval.'
        Assert-Throws {Enter-StackLaunchGate -RepoRoot $test.Fixture.Root -InstallBase $test.Fixture.Base -GenerationId $test.Record.generation} 'Stopping generation allowed a late native spawn.'
        if($stage -ceq 'partial-replacement'){
            Assert-Local ($null -ne $lease.monitor -and (Test-StackLaunchIdentityEqual $lease.monitor.identity $test.Record.monitorIdentity)) 'Reserved replacement claim dropped the exact monitor pin.'
        }
        Stop-MonitorFixture $test
        if($stage -ceq 'after-begin'){
            $bytes=[IO.File]::ReadAllText($test.Fixture.Scope.LeasePath)
            $handle=Enter-StackLaunchLeaseLock $test.Fixture.Scope
            try{Assert-Throws {Begin-StackLaunchRecycle -Scope $test.Fixture.Scope -RecycleId ([Guid]::NewGuid().ToString('D')) -RecyclerIdentity (Get-StackLaunchProcessIdentity -ProcessId $PID) -LockHandle $handle} 'Direct recycler Begin overwrote the durable stopping fence.'}finally{Exit-StackLaunchLeaseLock $handle}
            $retry=Start-Launch $test.Fixture 'same-boot-after-monitor-death'
            if(-not $retry.Child.Process.WaitForExit(10000)){throw 'Same-boot retry did not finish.'}
            Assert-Local (-not(Test-Path -LiteralPath $retry.Files.Entered) -and [IO.File]::ReadAllText($test.Fixture.Scope.LeasePath) -ceq $bytes) 'Monitor death removed the durable same-boot stopping fence.'
        }
        Add-Result ('recycle-monitor-orphan-fault-'+$stage)
    }

    foreach($nodeCase in @('registered-live','registered-then-dead','unregistered-live','completed-live')){
        $stage=if($nodeCase -ceq 'unregistered-live'){'unregistered-node'}else{'after-node-pin'}
        $test=New-MonitorFixture $nodeCase $stage 14
        Start-MonitorFixture $test;Stop-MonitorFixtureHelper $test
        $lease=Read-FixtureLease $test.Fixture.Scope
        if($nodeCase -ceq 'unregistered-live'){
            Assert-Local ($null -eq $lease.activeNode -and $null -eq $lease.completedNode) 'Unregistered Node fixture unexpectedly has a durable pin.'
            $pin=Get-Content -LiteralPath $test.Config.unregisteredNode -Raw|ConvertFrom-Json
        }else{$pin=$lease.activeNode;Assert-Local (Test-StackLaunchProcessIdentity $pin) 'Registered replacement Node was not alive.'}
        Track-ChildPid $pin.pid
        if($nodeCase -ceq 'completed-live'){
            Assert-Local (-not $test.Monitor.Process.HasExited) 'Starting Node retired its monitor before the full-stack completion contract.'
            $handle=Enter-StackLaunchLeaseLock $test.Fixture.Scope
            try{[void](Complete-StackLaunchAttempt -Scope $test.Fixture.Scope -GenerationId $test.Record.generation -OwnerIdentity $lease.owner -NodeIdentity $pin -LockHandle $handle)}finally{Exit-StackLaunchLeaseLock $handle}
            Wait-Owned $test.Monitor 0 8
            Assert-Local (-not(Test-Path -LiteralPath $test.Config.fakeStop) -and (Test-StackLaunchProcessIdentity $pin)) 'Completed full-stack Node was stopped instead of returning authority to existing supervision.'
        }elseif($nodeCase -ceq 'registered-then-dead'){
            $module=New-Module -ScriptBlock {param($Source). $Source} -ArgumentList $processSource
            try{& $module {param($Identity)Stop-StackLaunchProcessIdentity $Identity} $pin}finally{Remove-Module $module -Force}
            Wait-MonitorFakeStop $test 22
            Assert-Local ((Read-FixtureLease $test.Fixture.Scope).phase -ceq 'stopping') 'Early registered Node death retired the monitor before terminal fencing.'
        }else{
            Start-Sleep -Milliseconds 1200
            Assert-Local (-not $test.Monitor.Process.HasExited -and -not(Test-Path -LiteralPath $test.Config.fakeStop)) 'Node birth prematurely retired the operation monitor or requested stop.'
            Wait-Owned $test.Monitor 0 22
            Assert-Local (-not(Test-Path -LiteralPath $test.Config.fakeStop) -and (Test-StackLaunchProcessIdentity $pin)) 'Live registered/unregistered Node was stopped at the orphan deadline.'
            if($nodeCase -ceq 'unregistered-live'){
                $diagnostic=Get-ChildItem -LiteralPath (Join-Path $test.Fixture.Base 'state') -Filter 'stack-recycle-monitor-fault-*.json' -File
                $value=Get-Content -LiteralPath $diagnostic.FullName -Raw|ConvertFrom-Json
                Assert-Local ($value.reason -ceq 'recycle_monitor_unclassified_node_at_deadline' -and $value.action -ceq 'review_required_no_shutdown' -and (Read-FixtureLease $test.Fixture.Scope).phase -ceq 'starting') 'Unclassified Node did not produce its conservative no-shutdown diagnostic.'
                Add-Result 'recycle-monitor-unregistered-live-deadline'
                # Model the later ordinary Task Scheduler retry after all
                # tracked actors died but the unregistered portable Node
                # survived. Side effects deliberately follow the real Enter
                # CLI decision in the canonical disposable full-stack BAT.
                $module=New-Module -ScriptBlock {param($Source). $Source} -ArgumentList $processSource
                try{& $module {param($Identity)Stop-StackLaunchProcessIdentity $Identity} $lease.owner}finally{Remove-Module $module -Force}
                Assert-Local (-not(Test-StackLaunchProcessIdentity $lease.owner) -and -not(Test-StackLaunchProcessIdentity $test.Record.helperIdentity) -and $test.Monitor.Process.HasExited) 'Post-monitor retry fixture still has a live tracked actor.'
                $health=Join-Path $test.Fixture.Base 'post-monitor-health.json';$config=Join-Path $test.Fixture.Base 'post-monitor-config.json'
                Write-FixtureText $health 'original-health';Write-FixtureText $config 'original-config'
                $batch=[IO.File]::ReadAllText($test.Fixture.Scope.EntryPath)
                $anchor='set "SCALEWORLD_STACK_LAUNCH_GRANT="'
                Assert-Local ($batch.Contains($anchor)) 'Fixture entry side-effect insertion anchor is missing.'
                $effects='> "'+$health+'" echo mutated'+"`r`n"+'> "'+$config+'" echo mutated'+"`r`n"+$anchor
                Write-FixtureText $test.Fixture.Scope.EntryPath $batch.Replace($anchor,$effects)
                $leaseBytes=[IO.File]::ReadAllText($test.Fixture.Scope.LeasePath)
                $retry=Start-Launch $test.Fixture 'post-monitor-dead-owner-unknown-node'
                Wait-Owned $retry.Child 0 15
                Assert-Local ((Test-Path -LiteralPath $retry.Files.Skipped) -and -not(Test-Path -LiteralPath $retry.Files.Entered)) 'Unregistered scoped Node allowed ordinary entry after the monitor retired.'
                Assert-Local ([IO.File]::ReadAllText($test.Fixture.Scope.LeasePath) -ceq $leaseBytes) 'Unknown-Node retry mutated the durable lease.'
                Assert-Local ([IO.File]::ReadAllText($health) -ceq 'original-health' -and [IO.File]::ReadAllText($config) -ceq 'original-config') 'Unknown-Node retry performed early health/config side effects.'
                Assert-Local ((Test-StackLaunchProcessIdentity $pin) -and -not(Test-Path -LiteralPath $test.Config.fakeStop)) 'Unknown-Node retry killed the unclassified Node or requested shutdown.'
                Stop-MonitorFixture $test
                Add-Result 'recycle-monitor-retired-dead-owner-unregistered-node-entry-skip'
                continue
            }
        }
        Stop-MonitorFixture $test
        Add-Result ('recycle-monitor-'+$nodeCase+'-deadline')
    }

    foreach($nativeCase in @('kill-before-node-birth','node-born-during-cancellation')){
        $test=New-MonitorFixture $nativeCase 'partial-replacement' 20
        $fixturePs=Split-Path -Parent $test.ModulePath
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start_wilbur_leased.ps1') -Destination (Join-Path $fixturePs 'start_wilbur_leased.ps1')
        $pause=Join-Path $test.Fixture.Base 'native-pause.json';$release=Join-Path $test.Fixture.Base 'native-release';$nodeRecord=Join-Path $test.Fixture.Base 'native-node.json'
        foreach($field in @{nativePause=$pause;nativeRelease=$release;nativeNodeRecord=$nodeRecord;nativeRace=([int]($nativeCase -ceq 'node-born-during-cancellation'))}.GetEnumerator()){$test.Config|Add-Member -NotePropertyName $field.Key -NotePropertyValue $field.Value}
        $pauseScript=Join-Path $test.Fixture.Base 'pause-before-native-call.ps1'
        Write-FixtureText $pauseScript @'
$self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID) -ErrorAction Stop
$shell=Get-CimInstance Win32_Process -Filter ('ProcessId='+$self.ParentProcessId) -ErrorAction Stop
[IO.File]::WriteAllText($env:SW_TEST_MONITOR_NATIVE_PAUSE,([pscustomobject]@{pausePid=$PID;shellPid=[int]$shell.ProcessId;shellBirth=([DateTime]$shell.CreationDate).ToUniversalTime().ToString('o')}|ConvertTo-Json))
while(-not(Test-Path -LiteralPath $env:SW_TEST_MONITOR_NATIVE_RELEASE)){Start-Sleep -Milliseconds 40}
'@
        Write-FixtureText (Join-Path $test.Fixture.Root 'platform_scripts\cmd\start_wilbur_native.bat') ('@echo off'+"`r`n"+'setlocal EnableExtensions EnableDelayedExpansion'+"`r`n"+'"%SW_TEST_PS%" -NoProfile -ExecutionPolicy Bypass -File "%SW_TEST_NATIVE_PAUSE_SCRIPT%"'+"`r`n"+'call "%NODE_EXE%" .\dist\index.js %SERVER_ARGS%'+"`r`n"+'exit /b %errorlevel%'+"`r`n")
        Write-FixtureText (Join-Path $test.Fixture.Root 'dist\index.js') 'require("fs").writeFileSync(process.env.SW_TEST_MONITOR_NATIVE_NODE,JSON.stringify({pid:process.pid}));setInterval(()=>{},1000);'
        if($nativeCase -ceq 'node-born-during-cancellation'){
            # Release the real paused CALL only when the actual monitor has
            # captured the exact native shell for cancellation. The production
            # Stop function still executes; only the interleaving is injected.
            $birthRace=@'
$script:actualFixtureStop=${function:Stop-StackLaunchProcessIdentity}
function Stop-StackLaunchProcessIdentity {
    param($Identity,[int]$TimeoutMilliseconds=5000)
    if($env:SW_TEST_MONITOR_NATIVE_RACE -eq '1' -and (Test-Path -LiteralPath $env:SW_TEST_MONITOR_NATIVE_PAUSE)){
        $paused=Get-Content -LiteralPath $env:SW_TEST_MONITOR_NATIVE_PAUSE -Raw|ConvertFrom-Json
        if($Identity.pid -eq $paused.shellPid -and -not(Test-Path -LiteralPath $env:SW_TEST_MONITOR_NATIVE_RELEASE)){
            [IO.File]::WriteAllText($env:SW_TEST_MONITOR_NATIVE_RELEASE,'release')
            $until=[DateTime]::UtcNow.AddSeconds(5)
            while(-not(Test-Path -LiteralPath $env:SW_TEST_MONITOR_NATIVE_NODE)){if([DateTime]::UtcNow -gt $until){throw 'Injected native race did not produce Node.'};Start-Sleep -Milliseconds 40}
        }
    }
    & $script:actualFixtureStop -Identity $Identity -TimeoutMilliseconds $TimeoutMilliseconds
}
'@
            Write-FixtureText $test.ModulePath ([IO.File]::ReadAllText($test.ModulePath)+[Environment]::NewLine+$birthRace)
        }
        Start-MonitorFixture $test;Stop-MonitorFixtureHelper $test
        $wrapperEnvironment=@{NODE_EXE=$test.Fixture.Scope.NodePath;SERVER_ARGS='';SCALEWORLD_INSTALL_BASE=$test.Fixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION=$test.Record.generation;SW_TEST_PS=$psExe;SW_TEST_NATIVE_PAUSE_SCRIPT=$pauseScript;SW_TEST_MONITOR_NATIVE_PAUSE=$pause;SW_TEST_MONITOR_NATIVE_RELEASE=$release;SW_TEST_MONITOR_NATIVE_NODE=$nodeRecord}
        $wrapper=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'" -NodeBirthTimeoutSeconds 60') $wrapperEnvironment $test.Fixture.Root
        Wait-File $pause
        $paused=Get-Content -LiteralPath $pause -Raw|ConvertFrom-Json
        Track-ChildPid $paused.shellPid;Track-ChildPid $paused.pausePid
        $nativeShell=Get-StackLaunchProcessIdentity -ProcessId $paused.shellPid
        $wrapper.Process.Kill();[void]$wrapper.Process.WaitForExit(5000)
        Assert-Local (-not(Test-Path -LiteralPath $nodeRecord) -and (Test-StackLaunchProcessIdentity $nativeShell)) 'Hard-killed wrapper did not leave the intended paused native CALL fixture.'
        if($nativeCase -ceq 'kill-before-node-birth'){
            Wait-MonitorFakeStop $test 28
            Assert-Local (-not(Test-StackLaunchProcessIdentity $nativeShell) -and (Read-FixtureLease $test.Fixture.Scope).phase -ceq 'stopping') 'Terminal monitor did not cancel the exact latent native shell before its stopping fence.'
            Write-FixtureText $release 'release';Start-Sleep -Milliseconds 800
            Assert-Local (-not(Test-Path -LiteralPath $nodeRecord)) 'Cancelled latent native CALL produced a Node after the stopping fence.'
        }else{
            Wait-File $nodeRecord 28;Wait-Owned $test.Monitor 0 10
            $nodePid=[int](Get-Content -LiteralPath $nodeRecord -Raw|ConvertFrom-Json).pid;Track-ChildPid $nodePid
            $nodeIdentity=Get-StackLaunchProcessIdentity -ProcessId $nodePid
            Assert-Local ((Test-StackLaunchProcessIdentity $nodeIdentity) -and -not(Test-Path -LiteralPath $test.Config.fakeStop) -and -not(Test-StackLaunchProcessIdentity $nativeShell)) 'Node born during exact native-shell cancellation was killed or allowed terminal shutdown.'
            $lease=Read-FixtureLease $test.Fixture.Scope
            Assert-Local ($lease.phase -ceq 'starting' -and $null -eq $lease.activeNode) 'Late unregistered Node was incorrectly pinned or put into stopping.'
        }
        Stop-MonitorFixture $test
        Add-Result ('recycle-monitor-latent-native-'+$nativeCase)
    }

    $test=New-MonitorFixture 'stale-tuples' 'partial-replacement' 20
    Start-MonitorFixture $test;Stop-MonitorFixtureHelper $test
    $module=New-Module -ScriptBlock {param($Source). $Source} -ArgumentList $test.ModulePath
    try{
        $before=[IO.File]::ReadAllText($test.Fixture.Scope.LeasePath)
        foreach($kind in @('operation','dispatch','generation','monitor-pid','monitor-birth','recycler-pid','recycler-birth')){
            $intent=$test.Record.intent|ConvertTo-Json -Depth 24|ConvertFrom-Json
            $monitor=$test.Record.monitorIdentity|Select-Object *;$helper=$test.Record.helperIdentity|Select-Object *;$generation=$test.Record.generation
            switch($kind){
                operation {$intent.ExpectedRecycleId=[Guid]::NewGuid().ToString('D')}
                dispatch {$intent.ExpectedHelperLaunchId=[Guid]::NewGuid().ToString('D')}
                generation {$generation=[Guid]::NewGuid().ToString('D')}
                monitor-pid {$monitor.pid=$PID}
                monitor-birth {$monitor.creationUtc=[DateTimeOffset]::Parse($monitor.creationUtc).AddSeconds(-1).UtcDateTime.ToString('o')}
                recycler-pid {$helper.pid=$PID}
                recycler-birth {$helper.creationUtc=[DateTimeOffset]::Parse($helper.creationUtc).AddSeconds(-1).UtcDateTime.ToString('o')}
            }
            $handle=Enter-StackLaunchLeaseLock $test.Fixture.Scope
            try{
                $result=& $module {param($Scope,$Intent,$Monitor,$Helper,$Generation,$MonitorId,$Handle)Invoke-StackRecycleMonitorDeadline -Scope $Scope -Intent $Intent -MonitorIdentity $Monitor -RecyclerIdentity $Helper -GenerationId $Generation -MonitorId $MonitorId -LockHandle $Handle} $test.Fixture.Scope $intent $monitor $helper $generation $test.Record.monitorId $handle
                Assert-Local ($result -ceq 'Superseded') ('Stale '+$kind+' monitor obtained terminal authority.')
            }finally{Exit-StackLaunchLeaseLock $handle}
            Assert-Local ([IO.File]::ReadAllText($test.Fixture.Scope.LeasePath) -ceq $before -and -not(Test-Path -LiteralPath $test.Config.fakeStop)) ('Stale '+$kind+' monitor mutated the lease or requested stop.')
        }
    }finally{Remove-Module $module -Force}
    Remove-Item -LiteralPath $test.Config.markerPath -Force;Wait-Owned $test.Monitor 0 10
    Stop-MonitorFixture $test;Add-Result 'recycle-monitor-stale-operation-dispatch-generation-birth-zero-mutation'

    foreach($completion in @('marker-removed','reset-completed','superseded-dispatch')){
        $test=New-MonitorFixture $completion 'partial-replacement' 12
        Start-MonitorFixture $test;Stop-MonitorFixtureHelper $test
        if($completion -ceq 'marker-removed'){Remove-Item -LiteralPath $test.Config.markerPath -Force}else{
            $marker=Get-Content -LiteralPath $test.Config.markerPath -Raw|ConvertFrom-Json
            if($completion -ceq 'reset-completed'){$marker|Add-Member -NotePropertyName resetCompletedAtUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o'))}else{$marker.helperLaunchId=[Guid]::NewGuid().ToString('D')}
            Write-FixtureText $test.Config.markerPath ($marker|ConvertTo-Json -Depth 16)
        }
        $before=[IO.File]::ReadAllText($test.Fixture.Scope.LeasePath)
        Wait-Owned $test.Monitor 0 10
        Assert-Local (-not(Test-Path -LiteralPath $test.Config.fakeStop) -and [IO.File]::ReadAllText($test.Fixture.Scope.LeasePath) -ceq $before) 'Completed/superseded operation requested shutdown or changed launch state.'
        Stop-MonitorFixture $test;Add-Result ('recycle-monitor-retire-'+$completion)
    }
}

try {
    if (-not $MonitorOnly) {
    $fixture=New-Fixture 'starting'
    $first=Start-Launch $fixture 'first';Wait-File $first.Files.Entered
    $before=[IO.File]::ReadAllText($fixture.Scope.LeasePath)
    $duplicate=Start-Launch $fixture 'duplicate';Wait-Owned $duplicate.Child
    Assert-Local (Test-Path -LiteralPath $duplicate.Files.Skipped) 'Concurrent normal entry must skip a live starting owner.'
    Assert-Local ([IO.File]::ReadAllText($fixture.Scope.LeasePath) -ceq $before) 'Duplicate entry mutated the lease.'
    Release-Launch $first;Add-Result 'concurrent-starting-owner'

    $fixture=New-Fixture 'gate-serialization'
    $gated=Start-Launch $fixture 'gated' 'native-held';Wait-File $gated.Files.GateHeld
    Assert-Throws {Enter-StackLaunchLeaseLock -Scope $fixture.Scope -TimeoutSeconds 0} 'Actual cross-process native gate did not own the lifecycle mutex.'
    $recycleScript=Join-Path $fixture.Base 'recycle-worker.ps1'
    $workerWaiting=Join-Path $fixture.Base 'worker-waiting';$workerDone=Join-Path $fixture.Base 'worker-done.json';$workerRelease=Join-Path $fixture.Base 'worker-release'
    Write-FixtureText $recycleScript @'
. $env:SW_TEST_LEASE
$scope=Get-StackLaunchLeaseScope $env:SW_TEST_ROOT $env:SW_TEST_BASE
[IO.File]::WriteAllText($env:SW_TEST_WAITING,'waiting')
$handle=Enter-StackLaunchLeaseLock $scope
try{
    [void](Begin-StackLaunchRecycle -Scope $scope -RecycleId ([Guid]::NewGuid().ToString('D')) -RecyclerIdentity (Get-StackLaunchProcessIdentity -ProcessId $PID) -LockHandle $handle)
    [IO.File]::WriteAllText($env:SW_TEST_DONE,([pscustomobject]@{revokedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json))
}finally{Exit-StackLaunchLeaseLock $handle}
while(-not(Test-Path -LiteralPath $env:SW_TEST_WORKER_RELEASE)){Start-Sleep -Milliseconds 40}
'@
    $worker=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+$recycleScript+'"') @{SW_TEST_LEASE=$leaseSource;SW_TEST_ROOT=$fixture.Root;SW_TEST_BASE=$fixture.Base;SW_TEST_WAITING=$workerWaiting;SW_TEST_DONE=$workerDone;SW_TEST_WORKER_RELEASE=$workerRelease}
    Wait-File $workerWaiting;Start-Sleep -Milliseconds 200
    Assert-Local (-not(Test-Path -LiteralPath $workerDone)) 'Recycler mutation passed a held native gate.'
    Release-Launch $gated;Wait-File $workerDone;Wait-File $gated.Files.Mutation
    $born=[DateTimeOffset]::Parse([IO.File]::ReadAllText($gated.Files.ChildBorn))
    $revoked=[DateTimeOffset]::Parse((Get-Content -LiteralPath $workerDone -Raw|ConvertFrom-Json).revokedUtc)
    Assert-Local ($born -le $revoked) 'Harmless native child was born after serialized revocation.'
    Write-FixtureText $workerRelease 'release';Wait-Owned $worker;Add-Result 'native-spawn-and-recycle-serialization'

    $fixture=New-Fixture 'revoked'
    $old=Start-Launch $fixture 'old' 'native';Wait-File $old.Files.Entered
    $oldRecord=Get-Content -LiteralPath $old.Files.Entered -Raw|ConvertFrom-Json
    $handle=Enter-StackLaunchLeaseLock $fixture.Scope
    try{
        $recycle=Begin-StackLaunchRecycle -Scope $fixture.Scope -RecycleId ([Guid]::NewGuid().ToString('D')) -RecyclerIdentity (Get-StackLaunchProcessIdentity -ProcessId $PID) -LockHandle $handle
    }finally{Exit-StackLaunchLeaseLock $handle}
    $before=[IO.File]::ReadAllText($fixture.Scope.LeasePath)
    $unreserved=Start-Launch $fixture 'unreserved' 'hold' 'recovery';Wait-Owned $unreserved.Child
    Assert-Local (Test-Path -LiteralPath $unreserved.Files.Skipped) 'Markerless recovery must skip live recycler work.'
    $badGrant=Start-Launch $fixture 'bad-grant' 'hold' 'recovery' '' ([Guid]::NewGuid().ToString('D'));Wait-Owned $badGrant.Child 1
    Assert-Local ([IO.File]::ReadAllText($fixture.Scope.LeasePath) -ceq $before) 'Unreserved or incorrect grant mutated the lease.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $fixture.Root -InstallBase $fixture.Base -GenerationId ''} 'Standalone native producer ignored a live recycler.'
    Release-Launch $old;Wait-File $old.Files.Denied
    Assert-Local (-not(Test-Path -LiteralPath $old.Files.Mutation)) 'Revoked generation created a native sentinel.'
    $handle=Enter-StackLaunchLeaseLock $fixture.Scope
    try{
        $replacement=Start-Launch $fixture 'replacement' 'hold' 'recovery' $oldRecord.generation $recycle.Grant 'recovery' $handle
        $duringReservation=Start-Launch $fixture 'normal-during-reservation'
    }finally{Exit-StackLaunchLeaseLock $handle}
    Wait-Owned $duringReservation.Child
    Assert-Local (Test-Path -LiteralPath $duringReservation.Files.Skipped) 'Normal concurrent entry bypassed a pinned replacement reservation.'
    Wait-File $replacement.Files.Entered
    $replacementRecord=Get-Content -LiteralPath $replacement.Files.Entered -Raw|ConvertFrom-Json
    Assert-Local ($replacementRecord.generation -ceq $recycle.Grant) 'Exact replacement grant did not override inherited old generation.'
    $intruder=Start-Launch $fixture 'stolen-grant' 'hold' 'recovery' '' $recycle.Grant;Wait-Owned $intruder.Child 1
    Release-Launch $replacement;Add-Result 'recycler-reservation-and-revoked-native-gate'

    $fixture=New-Fixture 'completed'
    $complete=Start-Launch $fixture 'complete' 'complete';Wait-File $complete.Files.Completed;Wait-Owned $complete.Child
    $before=[IO.File]::ReadAllText($fixture.Scope.LeasePath)
    $retry=Start-Launch $fixture 'scheduler-retry';Wait-Owned $retry.Child
    Assert-Local (Test-Path -LiteralPath $retry.Files.Skipped) 'Markerless simulated Scheduler retry must skip a completed pinned Node.'
    Assert-Local (-not(Test-Path -LiteralPath (Join-Path $fixture.Base 'state\instance-agent-recycle-marker.json'))) 'Completed retry fixture unexpectedly contains a recycle marker.'
    Assert-Local ([IO.File]::ReadAllText($fixture.Scope.LeasePath) -ceq $before) 'Completed retry mutated the registry.'
    $watchdogRepair=Start-Launch $fixture 'markerless-watchdog' 'hold' 'recovery';Wait-File $watchdogRepair.Files.Entered
    Assert-Local (-not(Test-Path -LiteralPath $watchdogRepair.Files.Skipped)) 'Completed Node must not suppress explicit markerless watchdog recovery.'
    Assert-Local ((Get-Content -LiteralPath $watchdogRepair.Files.Entered -Raw|ConvertFrom-Json).generation -ceq (Get-Content -LiteralPath $complete.Files.Entered -Raw|ConvertFrom-Json).generation) 'Recovery entry changed the generation of a retained live Node.'
    Release-Launch $watchdogRepair
    Stop-FixtureNode $complete;Add-Result 'completed-lease-markerless-scheduler-retry'

    $fixture=New-Fixture 'partial'
    $partial=Start-Launch $fixture 'partial' 'partial';Wait-File $partial.Files.Node;Release-Launch $partial
    $repair=Start-Launch $fixture 'repair';Wait-File $repair.Files.Entered
    Assert-Local (-not(Test-Path -LiteralPath $repair.Files.Skipped)) 'Dead incomplete owner with surviving Node must permit repair.'
    Assert-Local ((Get-Content -LiteralPath $repair.Files.Entered -Raw|ConvertFrom-Json).generation -ceq (Get-Content -LiteralPath $partial.Files.Entered -Raw|ConvertFrom-Json).generation) 'Partial repair changed the retained Node generation.'
    Release-Launch $repair;Stop-FixtureNode $partial;Add-Result 'dead-partial-owner-repair'

    $fixture=New-Fixture 'active-node-pin'
    $pinOwner=Start-Launch $fixture 'owner';Wait-File $pinOwner.Files.Entered
    $pinGeneration=(Get-Content -LiteralPath $pinOwner.Files.Entered -Raw|ConvertFrom-Json).generation
    $firstStop=Join-Path $fixture.Base 'first-node-stop';$secondStop=Join-Path $fixture.Base 'second-node-stop'
    $firstNode=Start-Owned $fixture.Scope.NodePath '.\dist\index.js' @{SW_TEST_NODE_STOP=$firstStop} $fixture.Root
    $secondNode=Start-Owned $fixture.Scope.NodePath '.\dist\index.js' @{SW_TEST_NODE_STOP=$secondStop} $fixture.Root
    $firstPin=Get-StackLaunchProcessIdentity -ProcessId $firstNode.Process.Id;$secondPin=Get-StackLaunchProcessIdentity -ProcessId $secondNode.Process.Id
    $handle=Enter-StackLaunchLeaseLock $fixture.Scope
    try{
        [void](Register-StackLaunchNode -Scope $fixture.Scope -GenerationId $pinGeneration -NodeIdentity $firstPin -LockHandle $handle)
        $before=[IO.File]::ReadAllText($fixture.Scope.LeasePath)
        Assert-Throws {Register-StackLaunchNode -Scope $fixture.Scope -GenerationId ([Guid]::NewGuid().ToString('D')) -NodeIdentity $firstPin -LockHandle $handle} 'Node registration accepted a revoked generation.'
        Assert-Throws {Register-StackLaunchNode -Scope $fixture.Scope -GenerationId $pinGeneration -NodeIdentity $secondPin -LockHandle $handle} 'A different live Node replaced the durable active pin.'
        $wrongPin=$firstPin|Select-Object *;$wrongPin.creationUtc=[DateTimeOffset]::Parse($firstPin.creationUtc).AddSeconds(-1).UtcDateTime.ToString('o')
        Assert-Throws {Register-StackLaunchNode -Scope $fixture.Scope -GenerationId $pinGeneration -NodeIdentity $wrongPin -LockHandle $handle} 'Node registration accepted PID with an incorrect birth.'
        Assert-Local ([IO.File]::ReadAllText($fixture.Scope.LeasePath) -ceq $before) 'Rejected Node registrations mutated the lease.'
    }finally{Exit-StackLaunchLeaseLock $handle}
    Write-FixtureText $firstStop 'stop';Write-FixtureText $secondStop 'stop';Wait-Owned $firstNode;Wait-Owned $secondNode;Release-Launch $pinOwner
    Add-Result 'durable-active-node-exact-identity-and-zero-mutation'

    $fixture=New-Fixture 'handoff'
    $original=Start-Launch $fixture 'original';Wait-File $original.Files.Entered
    $record=Get-Content -LiteralPath $original.Files.Entered -Raw|ConvertFrom-Json
    $handle=Enter-StackLaunchLeaseLock $fixture.Scope
    try{
        $handoff=Begin-StackLaunchHandoff -Scope $fixture.Scope -GenerationId $record.generation -OwnerIdentity $record.owner -TargetRepoRoot $fixture.Root -LockHandle $handle
        $fresh=Start-Launch $fixture 'fresh' 'hold' 'normal' $record.generation $handoff.Grant 'handoff' $handle
    }finally{Exit-StackLaunchLeaseLock $handle}
    Wait-File $fresh.Files.Entered
    Assert-Local ((Get-Content -LiteralPath $fresh.Files.Entered -Raw|ConvertFrom-Json).generation -ceq $handoff.Grant) 'Exact git-sync handoff failed while original CMD remained alive.'
    Release-Launch $original;Release-Launch $fresh;Add-Result 'git-sync-explicit-child-handoff'

    $fixture=New-Fixture 'identity'
    $live=Start-Launch $fixture 'live';Wait-File $live.Files.Entered
    $identity=Get-EntryIdentity $fixture $live.Child.Process.Id
    $wrong=$identity|Select-Object *;$wrong.creationUtc=[DateTimeOffset]::Parse($identity.creationUtc).AddSeconds(-1).UtcDateTime.ToString('o')
    Assert-Local (-not(Test-StackLaunchProcessIdentity $wrong)) 'PID alone must not match a different creation timestamp.'
    Release-Launch $live
    $marker=Join-Path $fixture.Base 'state\instance-agent-recycle-marker.json'
    Write-FixtureText $marker '{"phase":"intent","recycleId":"retained-fixture-intent"}'
    $markerBefore=[IO.File]::ReadAllText($marker)
    $bootRepair=Start-Launch $fixture 'new-boot';Wait-File $bootRepair.Files.Entered
    Assert-Local ([IO.File]::ReadAllText($marker) -ceq $markerBefore) 'Dead-lease reclaim must not clear durable recovery intent.'
    Release-Launch $bootRepair;Add-Result 'exact-pid-birth-and-dead-lease-marker-retention'

    $fixture=New-Fixture 'intent-fence'
    . (Join-Path $PSScriptRoot 'recycle_intent_guard.ps1')
    $marker=Join-Path $fixture.Base 'state\instance-agent-recycle-marker.json';$recycleId=[Guid]::NewGuid().ToString('D');$helperLaunchId=[Guid]::NewGuid().ToString('D');$sourceGeneration=[Guid]::NewGuid().ToString('D');$sourceCreation=(Get-StackLaunchProcessIdentity -ProcessId $PID).creationUtc
    Write-FixtureText $marker ([pscustomobject]@{schemaVersion=2;phase='intent';recycleId=$recycleId;sourcePid=$PID;helperLaunchId=$helperLaunchId;sourceLaunchGenerationId=$sourceGeneration;sourceCreationUtc=$sourceCreation;reason='fixture';requestedAtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json)
    $bytesBefore=[IO.File]::ReadAllText($marker)
    $sourceBinding=@{ExpectedLaunchGenerationId=$sourceGeneration;ExpectedSourceCreationUtc=$sourceCreation}
    $validIntent=Read-ScaleWorldRecycleIntent -MarkerPath $marker -ExpectedRecycleId $recycleId -ExpectedSourcePid $PID -ExpectedHelperLaunchId $helperLaunchId @sourceBinding
    Assert-Local ($validIntent.Marker.helperLaunchId -ceq $helperLaunchId) 'Current helper dispatch did not validate.'
    Assert-Throws {Read-ScaleWorldRecycleIntent -MarkerPath $marker -ExpectedRecycleId ([Guid]::NewGuid().ToString('D')) -ExpectedSourcePid $PID -ExpectedHelperLaunchId $helperLaunchId @sourceBinding} 'Wrong recycle operation was accepted.'
    Assert-Throws {Read-ScaleWorldRecycleIntent -MarkerPath $marker -ExpectedRecycleId $recycleId -ExpectedSourcePid ($PID+1) -ExpectedHelperLaunchId $helperLaunchId @sourceBinding} 'Wrong recycle source was accepted.'
    Assert-Throws {Read-ScaleWorldRecycleIntent -MarkerPath $marker -ExpectedRecycleId $recycleId -ExpectedSourcePid $PID -ExpectedHelperLaunchId ([Guid]::NewGuid().ToString('D')) @sourceBinding} 'A stale helper dispatch for the same operation and PID was accepted.'
    $wrongGeneration=$sourceBinding.Clone();$wrongGeneration.ExpectedLaunchGenerationId=[Guid]::NewGuid().ToString('D')
    Assert-Throws {Read-ScaleWorldRecycleIntent -MarkerPath $marker -ExpectedRecycleId $recycleId -ExpectedSourcePid $PID -ExpectedHelperLaunchId $helperLaunchId @wrongGeneration} 'A helper from a different launch generation was accepted.'
    $wrongCreation=$sourceBinding.Clone();$wrongCreation.ExpectedSourceCreationUtc=[DateTimeOffset]::Parse($sourceCreation).AddSeconds(-1).UtcDateTime.ToString('o')
    Assert-Throws {Read-ScaleWorldRecycleIntent -MarkerPath $marker -ExpectedRecycleId $recycleId -ExpectedSourcePid $PID -ExpectedHelperLaunchId $helperLaunchId @wrongCreation} 'A helper with stale source PID birth was accepted.'
    Assert-Local ([IO.File]::ReadAllText($marker) -ceq $bytesBefore -and -not(Test-Path -LiteralPath $fixture.Scope.LeasePath)) 'Nonauthoritative intent reads mutated marker or lease.'
    Add-Result 'nonauthoritative-helper-zero-mutation'

    # The recycler is a real descendant of the cancelled producer. Its own child
    # must survive, while a sibling old PowerShell producer is terminated.
    $fixture=New-Fixture 'producer-cancel';$other=New-Fixture 'other-root'
    $cancelProducer=Join-Path $fixture.Root 'platform_scripts\powershell\start_scaleworld.ps1'
    $fakeRecycler=Join-Path $fixture.Root 'platform_scripts\powershell\invoke_stack_recycle.ps1'
    $holdScript=Join-Path $fixture.Base 'hold-child.ps1';$cancelRecord=Join-Path $fixture.Base 'cancel-record.json';$helperRecord=Join-Path $fixture.Base 'helper-record.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $cancelProducer) -Force|Out-Null
    Write-FixtureText $holdScript 'while($true){Start-Sleep -Milliseconds 100}'
    Write-FixtureText $fakeRecycler @'
$child=Start-Process -FilePath $env:SW_TEST_PS -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$env:SW_TEST_HOLD+'"') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($env:SW_TEST_HELPER_RECORD,([pscustomobject]@{helperPid=$PID;helperChildPid=$child.Id}|ConvertTo-Json))
while($true){Start-Sleep -Milliseconds 100}
'@
    Write-FixtureText $cancelProducer @'
$oldChild=Start-Process -FilePath $env:SW_TEST_PS -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$env:SW_TEST_HOLD+'"') -WindowStyle Hidden -PassThru
$helper=Start-Process -FilePath $env:SW_TEST_PS -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$env:SW_TEST_RECYCLER+'"') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($env:SW_TEST_CANCEL_RECORD,([pscustomobject]@{producerPid=$PID;oldChildPid=$oldChild.Id;helperPid=$helper.Id}|ConvertTo-Json))
while($true){Start-Sleep -Milliseconds 100}
'@
    Write-FixtureText $fixture.Scope.EntryPath "@echo off`r`n`"%SW_TEST_PS%`" -NoProfile -ExecutionPolicy Bypass -File `"%SW_TEST_CANCEL_PRODUCER%`"`r`n"
    $cancelParent=Start-Owned $env:ComSpec ('/d /s /c ""'+$fixture.Scope.EntryPath+'""') @{SW_TEST_PS=$psExe;SW_TEST_CANCEL_PRODUCER=$cancelProducer;SW_TEST_HOLD=$holdScript;SW_TEST_RECYCLER=$fakeRecycler;SW_TEST_CANCEL_RECORD=$cancelRecord;SW_TEST_HELPER_RECORD=$helperRecord} $fixture.Root
    Wait-File $cancelRecord;Wait-File $helperRecord
    $cancel=Get-Content -LiteralPath $cancelRecord -Raw|ConvertFrom-Json;$helper=Get-Content -LiteralPath $helperRecord -Raw|ConvertFrom-Json
    foreach($id in @($cancel.producerPid,$cancel.oldChildPid,$helper.helperPid,$helper.helperChildPid)){Track-ChildPid $id}
    $unrelated=Start-Launch $other 'unrelated';Wait-File $unrelated.Files.Entered
    $mentionBat=Join-Path $fixture.Base 'path-mention.bat'
    Write-FixtureText $mentionBat "@echo off`r`necho `"$cancelProducer`" >nul`r`n`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$holdScript`"`r`n"
    $mention=Start-Owned $env:ComSpec ('/d /s /c "echo "'+$cancelProducer+'" >nul & "'+$psExe+'" -NoProfile -ExecutionPolicy Bypass -File "'+$holdScript+'""') @{} $fixture.Root
    $processModule=New-Module -ArgumentList $processSource -ScriptBlock {param($Source) . $Source}
    $owner=Get-EntryIdentity $fixture $cancelParent.Process.Id
    $wrong=$owner|Select-Object *;$wrong.creationUtc=[DateTimeOffset]::Parse($owner.creationUtc).AddSeconds(-1).UtcDateTime.ToString('o')
    Assert-Throws { & $processModule {param($Identity) Stop-StackLaunchProcessIdentity $Identity} $wrong } 'Cancellation accepted a reused-PID identity.'
    Assert-Local (-not $cancelParent.Process.HasExited) 'Birth-mismatch cancellation killed the live parent.'
    & $processModule {param($Root,$Owner,$Recycler) Stop-StackLaunchProducers -RepoRoot $Root -OwnerIdentity $Owner -RecyclerPid $Recycler} $fixture.Root $owner $helper.helperPid
    Assert-Local $cancelParent.Process.HasExited 'Exact old CMD producer survived cancellation.'
    Assert-Local ($null -eq (Get-StackLaunchProcessIdentity -ProcessId $cancel.producerPid)) 'Old PowerShell producer survived cancellation.'
    Assert-Local ($null -eq (Get-StackLaunchProcessIdentity -ProcessId $cancel.oldChildPid)) 'Old descendant producer survived cancellation.'
    Assert-Local ($null -ne (Get-StackLaunchProcessIdentity -ProcessId $helper.helperPid)) 'Detached recycler descendant was killed.'
    Assert-Local ($null -ne (Get-StackLaunchProcessIdentity -ProcessId $helper.helperChildPid)) 'Recycler child branch was killed.'
    Assert-Local (-not $unrelated.Child.Process.HasExited -and -not $mention.Process.HasExited) 'Other root or command-only path mention was cancelled.'
    Release-Launch $unrelated;Add-Result 'producer-cancellation-recycler-survival-and-root-isolation'

    # A child dies while holding the actual cross-process named mutex. Keep an
    # independent handle open so Windows reports abandonment rather than deleting it.
    $fixture=New-Fixture 'abandoned'
    $mutexScript=Join-Path $fixture.Base 'hold-mutex.ps1';$held=Join-Path $fixture.Base 'mutex-held'
    Write-FixtureText $mutexScript @'
. $env:SW_TEST_LEASE
$scope=Get-StackLaunchLeaseScope $env:SW_TEST_ROOT $env:SW_TEST_BASE
$handle=Enter-StackLaunchLeaseLock $scope
[IO.File]::WriteAllText($env:SW_TEST_HELD,'held')
while($true){Start-Sleep -Milliseconds 100}
'@
    $retainer=[Threading.Mutex]::new($false,$fixture.Scope.MutexName)
    try{
        $holder=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+$mutexScript+'"') @{SW_TEST_LEASE=$leaseSource;SW_TEST_ROOT=$fixture.Root;SW_TEST_BASE=$fixture.Base;SW_TEST_HELD=$held}
        Wait-File $held;$holder.Process.Kill();$null=$holder.Process.WaitForExit(10000)
        $handle=Enter-StackLaunchLeaseLock $fixture.Scope
        try{Assert-Local $handle.Abandoned 'Killed holder did not produce detectable mutex abandonment.'}finally{Exit-StackLaunchLeaseLock $handle}
    }finally{$retainer.Dispose()}
    $afterAbandon=Start-Launch $fixture 'after-abandon';Wait-File $afterAbandon.Files.Entered;Release-Launch $afterAbandon
    Add-Result 'abandoned-cross-process-mutex-recovery'

    $fixture=New-Fixture 'actual-wilbur-wrapper'
    $fixturePs=Join-Path $fixture.Root 'platform_scripts\powershell';New-Item -ItemType Directory -Path $fixturePs -Force|Out-Null
    foreach($source in @('stack_launch_lease.ps1','stack_launch_processes.ps1','scaleworld_process_helpers.ps1','start_wilbur_leased.ps1')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $source) -Destination (Join-Path $fixturePs $source)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_wilbur_native.bat') -Destination (Join-Path $fixture.Root 'platform_scripts\cmd\start_wilbur_native.bat')
    Write-FixtureText (Join-Path $fixture.Root 'dist\index.js') @'
const fs=require('fs');
fs.writeFileSync(process.env.SW_TEST_ARGV_RECORD,JSON.stringify(process.argv.slice(2)));
fs.writeFileSync(process.env.SW_TEST_ARGV_PID,String(process.pid));
const timer=setInterval(()=>{if(fs.existsSync(process.env.SW_TEST_ARGV_STOP)){clearInterval(timer);process.exit(Number(process.env.SW_TEST_NODE_EXIT));}},40);
'@
    $baselineBat=Join-Path $fixture.Base 'baseline-native-call.bat'
    Write-FixtureText $baselineBat @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
call "%NODE_EXE%" .\dist\index.js %SERVER_ARGS%
exit /b %errorlevel%
'@
    $argumentCases=@(
        '--peer_options_player_file="C:\Fixture With Spaces\peer_options.player.json" --auth_mode="connect_ticket" --runtime_status_aws_cli_path="C:\Program Files\Amazon\AWSCLIV2\aws.exe" --instance_agent_artifact_prefix="" --boolean=true',
        '--peer_options="{\"iceServers\":[{\"urls\":[\"stun:127.0.0.1:19303\",\"turn:127.0.0.1:19303\"],\"username\":\"fixture\",\"credential\":\"fixture\"}]}"',
        ('-ExecCmds="sg.ViewDistanceQuality 4,sg.ShadowQuality 4" --label="Alesund '+[char]0x65e5+[char]0x672c+'" --url="https://example.invalid/a?x=1&y=2"'),
        '--literal="value%%percent" --caret="a^b" --value="a!b"',
        '"" --after="continued"'
    )
    $wrapperOwner=Start-Launch $fixture 'wrapper-registration-owner';Wait-File $wrapperOwner.Files.Entered
    $wrapperEntry=Get-Content -LiteralPath $wrapperOwner.Files.Entered -Raw|ConvertFrom-Json
    $wrapperGeneration=$wrapperEntry.generation
    for($index=0;$index -lt $argumentCases.Count;$index++){
        $expectedExit=if($index -eq $argumentCases.Count-1){23}else{0}
        $baselineRecord=Join-Path $fixture.Base ('baseline-argv-'+$index+'.json')
        $wrapperRecord=Join-Path $fixture.Base ('wrapper-argv-'+$index+'.json')
        $baselineStop=$baselineRecord+'.stop';$wrapperStop=$wrapperRecord+'.stop'
        $environment=@{NODE_EXE=$fixture.Scope.NodePath;SERVER_ARGS=$argumentCases[$index];SCALEWORLD_INSTALL_BASE=$fixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION=$wrapperGeneration;SCALEWORLD_STACK_LAUNCH_GRANT='';SW_TEST_ARGV_RECORD=$baselineRecord;SW_TEST_ARGV_PID=$baselineRecord+'.pid';SW_TEST_ARGV_STOP=$baselineStop;SW_TEST_NODE_EXIT=$expectedExit}
        $baseline=Start-Owned $env:ComSpec ('/d /s /c ""'+$baselineBat+'""') $environment $fixture.Root
        Wait-File $baselineRecord;Write-FixtureText $baselineStop 'stop';Wait-Owned $baseline $expectedExit
        $environment.SW_TEST_ARGV_RECORD=$wrapperRecord
        $environment.SW_TEST_ARGV_PID=$wrapperRecord+'.pid';$environment.SW_TEST_ARGV_STOP=$wrapperStop
        $wrapped=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'"') $environment $fixture.Root
        Wait-File $wrapperRecord;Wait-File ($wrapperRecord+'.pid')
        $argvPid=[int][IO.File]::ReadAllText($wrapperRecord+'.pid')
        $until=[DateTime]::UtcNow.AddSeconds(15)
        do{
            $argvLease=Read-FixtureLease $fixture.Scope
            if($null -ne $argvLease.activeNode -and $argvLease.activeNode.pid -eq $argvPid){break}
            if([DateTime]::UtcNow -gt $until){throw 'Argv fixture Node was not certified before its requested exit.'}
            Start-Sleep -Milliseconds 40
        }while($true)
        Assert-Local (Test-StackLaunchProcessIdentity $argvLease.activeNode) 'Argv exit was requested before the actual wrapper certified a live Node.'
        Write-FixtureText $wrapperStop 'stop';Wait-Owned $wrapped $expectedExit
        Assert-Local ([IO.File]::ReadAllText($baselineRecord) -ceq [IO.File]::ReadAllText($wrapperRecord)) ('Actual gated Wilbur wrapper changed native argv case '+($index+1))
    }
    Add-Result 'actual-wilbur-wrapper-call-argv-and-exit-propagation'

    $wrapperNodeRecord=Join-Path $fixture.Base 'registered-wrapper-node.json';$wrapperNodeStop=Join-Path $fixture.Base 'registered-wrapper-node-stop'
    Write-FixtureText (Join-Path $fixture.Root 'dist\index.js') @'
const fs=require('fs');
fs.writeFileSync(process.env.SW_TEST_ARGV_RECORD,JSON.stringify({pid:process.pid,generation:process.env.SCALEWORLD_STACK_LAUNCH_GENERATION}));
const timer=setInterval(()=>{if(fs.existsSync(process.env.SW_TEST_NODE_STOP)){clearInterval(timer);process.exit(0);}},40);
'@
    $environment=@{NODE_EXE=$fixture.Scope.NodePath;SERVER_ARGS='--fixture=true';SCALEWORLD_INSTALL_BASE=$fixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION=$wrapperGeneration;SCALEWORLD_STACK_LAUNCH_GRANT='';SW_TEST_ARGV_RECORD=$wrapperNodeRecord;SW_TEST_NODE_STOP=$wrapperNodeStop}
    $registeredWrapper=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'"') $environment $fixture.Root
    Wait-File $wrapperNodeRecord
    $bornPid=[int](Get-Content -LiteralPath $wrapperNodeRecord -Raw|ConvertFrom-Json).pid
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do{$observedLease=Read-FixtureLease $fixture.Scope;if($null -ne $observedLease.activeNode -and $observedLease.activeNode.pid -eq $bornPid){break};Start-Sleep -Milliseconds 40}while([DateTime]::UtcNow -lt $deadline)
    $bornIdentity=Get-StackLaunchProcessIdentity -ProcessId $bornPid
    Assert-Local (Test-StackLaunchIdentityEqual $observedLease.activeNode $bornIdentity) 'Actual Wilbur wrapper did not durably pin its exact observed Node birth.'
    $handle=Enter-StackLaunchLeaseLock $fixture.Scope
    try{[void](Complete-StackLaunchAttempt -Scope $fixture.Scope -GenerationId $wrapperGeneration -OwnerIdentity $wrapperEntry.owner -NodeIdentity $bornIdentity -LockHandle $handle)}finally{Exit-StackLaunchLeaseLock $handle}
    Release-Launch $wrapperOwner;Write-FixtureText $wrapperNodeStop 'stop';Wait-Owned $registeredWrapper
    Add-Result 'actual-wilbur-wrapper-durable-observed-node-pin'

    $repairedRecord=Join-Path $fixture.Base 'standalone-repaired-node.json';$repairedStop=Join-Path $fixture.Base 'standalone-repaired-node-stop'
    $environment.SCALEWORLD_STACK_LAUNCH_GENERATION='';$environment.SW_TEST_ARGV_RECORD=$repairedRecord;$environment.SW_TEST_NODE_STOP=$repairedStop
    $standaloneRepair=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'"') $environment $fixture.Root
    Wait-File $repairedRecord
    $repairedPid=[int](Get-Content -LiteralPath $repairedRecord -Raw|ConvertFrom-Json).pid
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do{$repairedLease=Read-FixtureLease $fixture.Scope;if($repairedLease.activeNode.pid -eq $repairedPid){break};Start-Sleep -Milliseconds 40}while([DateTime]::UtcNow -lt $deadline)
    Assert-Local ($repairedLease.phase -ceq 'completed' -and $repairedLease.generationId -ceq $wrapperGeneration -and (Test-StackLaunchIdentityEqual $repairedLease.activeNode $repairedLease.completedNode) -and $repairedLease.activeNode.pid -eq $repairedPid) 'Markerless completed-dead-Node repair did not update both exact pins in the original generation.'
    Assert-Local ((Get-Content -LiteralPath $repairedRecord -Raw|ConvertFrom-Json).generation -ceq $wrapperGeneration) 'Standalone replacement Node did not inherit its safely resolved generation.'
    $duplicateNodeRecord=Join-Path $fixture.Base 'duplicate-standalone-node.json';$before=[IO.File]::ReadAllText($fixture.Scope.LeasePath)
    $environment.SW_TEST_ARGV_RECORD=$duplicateNodeRecord
    $duplicateStandalone=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'"') $environment $fixture.Root
    Wait-Owned $duplicateStandalone 1
    Assert-Local (-not(Test-Path -LiteralPath $duplicateNodeRecord) -and [IO.File]::ReadAllText($fixture.Scope.LeasePath) -ceq $before) 'Standalone duplicate mutated the completed live-Node lease or spawned Node.'
    Write-FixtureText $repairedStop 'stop';Wait-Owned $standaloneRepair
    Add-Result 'actual-wilbur-wrapper-markerless-completed-dead-node-repair'

    # Inject exactly one local CIM observation error only after the real native
    # BAT has born Node. The actual wrapper catch/cleanup must kill its pinned
    # shell and exact Node while it still owns the gate. Later CIM calls forward.
    $errorRecord=Join-Path $fixture.Base 'wrapper-observation-error.json'
    Write-FixtureText (Join-Path $fixture.Root 'dist\index.js') 'setInterval(()=>{},1000);'
    $clonedProcessSource=Join-Path $fixturePs 'stack_launch_processes.ps1'
    $observationInjection=@'
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName,[string]$Filter)
    if($env:SW_TEST_WRAPPER_INJECT_ERROR -eq '1' -and -not(Test-Path -LiteralPath $env:SW_TEST_WRAPPER_ERROR_RECORD)){
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        do{
            $snapshots=@(CimCmdlets\Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop)
            $nodes=@($snapshots|Where-Object{$_.Name -ieq 'node.exe'})
            if($nodes.Count -gt 0){break}
            Start-Sleep -Milliseconds 40
        }while([DateTime]::UtcNow -lt $deadline)
        if($nodes.Count -eq 0){throw 'Fixture failed to observe the real Node before injection.'}
        $shell=CimCmdlets\Get-CimInstance Win32_Process -Filter ('ProcessId='+$nodes[0].ParentProcessId) -ErrorAction Stop
        [IO.File]::WriteAllText($env:SW_TEST_WRAPPER_ERROR_RECORD,([pscustomobject]@{node=(Get-StackLaunchCancellationIdentity $nodes[0]);shell=(Get-StackLaunchCancellationIdentity $shell)}|ConvertTo-Json -Depth 4))
        throw 'Injected local observation failure after native Node birth.'
    }
    return CimCmdlets\Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop
}
'@
    Write-FixtureText $clonedProcessSource ([IO.File]::ReadAllText($clonedProcessSource)+[Environment]::NewLine+$observationInjection)
    $environment=@{NODE_EXE=$fixture.Scope.NodePath;SERVER_ARGS='--fixture=true';SCALEWORLD_INSTALL_BASE=$fixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION=$wrapperGeneration;SCALEWORLD_STACK_LAUNCH_GRANT='';SW_TEST_WRAPPER_INJECT_ERROR='1';SW_TEST_WRAPPER_ERROR_RECORD=$errorRecord}
    $failedWrapper=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'"') $environment $fixture.Root
    Wait-Owned $failedWrapper 1;Wait-File $errorRecord
    $failedIdentities=Get-Content -LiteralPath $errorRecord -Raw|ConvertFrom-Json
    Assert-Local (-not(Test-StackLaunchProcessIdentity $failedIdentities.node)) 'Observation-error cleanup left the born Node alive.'
    Assert-Local (-not(Test-StackLaunchProcessIdentity $failedIdentities.shell)) 'Observation-error cleanup left the producing CMD alive.'
    Copy-Item -LiteralPath $processSource -Destination $clonedProcessSource -Force
    Add-Result 'actual-wilbur-wrapper-born-node-observation-error-cleanup'

    # Simulate an externally killed native shell before its birth observation
    # returns. The real Node stays alive until the wrapper cleans it up; returning
    # an empty observation must not make an already exited shell count as success.
    $orphanRecord=Join-Path $fixture.Base 'wrapper-exited-shell-orphan.json'
    $orphanInjection=@'
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName,[string]$Filter)
    if($env:SW_TEST_WRAPPER_ORPHAN -eq '1' -and $Filter -match '^ParentProcessId\s*=' -and -not(Test-Path -LiteralPath $env:SW_TEST_WRAPPER_ERROR_RECORD)){
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        do{
            $snapshots=@(CimCmdlets\Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop)
            $nodes=@($snapshots|Where-Object{$_.Name -ieq 'node.exe'})
            if($nodes.Count -gt 0){break}
            Start-Sleep -Milliseconds 40
        }while([DateTime]::UtcNow -lt $deadline)
        if($nodes.Count -eq 0){throw 'Fixture failed to observe the real orphan Node.'}
        $shell=CimCmdlets\Get-CimInstance Win32_Process -Filter ('ProcessId='+$nodes[0].ParentProcessId) -ErrorAction Stop
        $identities=[pscustomobject]@{node=(Get-StackLaunchCancellationIdentity $nodes[0]);shell=(Get-StackLaunchCancellationIdentity $shell)}
        Stop-StackLaunchProcessIdentity $identities.shell
        [IO.File]::WriteAllText($env:SW_TEST_WRAPPER_ERROR_RECORD,($identities|ConvertTo-Json -Depth 4))
        return @()
    }
    return CimCmdlets\Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop
}
'@
    Write-FixtureText $clonedProcessSource ([IO.File]::ReadAllText($clonedProcessSource)+[Environment]::NewLine+$orphanInjection)
    $environment=@{NODE_EXE=$fixture.Scope.NodePath;SERVER_ARGS='--fixture=true';SCALEWORLD_INSTALL_BASE=$fixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION=$wrapperGeneration;SCALEWORLD_STACK_LAUNCH_GRANT='';SW_TEST_WRAPPER_ORPHAN='1';SW_TEST_WRAPPER_ERROR_RECORD=$orphanRecord}
    $orphanWrapper=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'"') $environment $fixture.Root
    Wait-Owned $orphanWrapper 1;Wait-File $orphanRecord
    $orphanIdentities=Get-Content -LiteralPath $orphanRecord -Raw|ConvertFrom-Json
    Assert-Local (-not(Test-StackLaunchProcessIdentity $orphanIdentities.node) -and -not(Test-StackLaunchProcessIdentity $orphanIdentities.shell)) 'Already-exited-shell failure left its uncertified Node alive.'
    Copy-Item -LiteralPath $processSource -Destination $clonedProcessSource -Force
    Add-Result 'actual-wilbur-wrapper-exited-shell-uncertified-node-cleanup'

    # A shell delayed before Node launch must not survive a birth timeout and
    # subsequently create Node after releasing the generation gate.
    $delayScript=Join-Path $fixture.Base 'delay-before-node.ps1'
    Write-FixtureText $delayScript 'Start-Sleep -Milliseconds 1500'
    $lateNodeRecord=Join-Path $fixture.Base 'late-node.json'
    Write-FixtureText (Join-Path $fixture.Root 'dist\index.js') 'require("fs").writeFileSync(process.env.SW_TEST_ARGV_RECORD,"late-node");'
    Write-FixtureText (Join-Path $fixture.Root 'platform_scripts\cmd\start_wilbur_native.bat') ('@echo off'+"`r`n"+'"%SW_TEST_PS%" -NoProfile -ExecutionPolicy Bypass -File "%SW_TEST_DELAY_SCRIPT%"'+"`r`n"+'call "%NODE_EXE%" .\dist\index.js %SERVER_ARGS%'+"`r`n"+'exit /b %errorlevel%'+"`r`n")
    $environment=@{NODE_EXE=$fixture.Scope.NodePath;SERVER_ARGS='';SCALEWORLD_INSTALL_BASE=$fixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION=$wrapperGeneration;SCALEWORLD_STACK_LAUNCH_GRANT='';SW_TEST_PS=$psExe;SW_TEST_DELAY_SCRIPT=$delayScript;SW_TEST_ARGV_RECORD=$lateNodeRecord}
    $timedOut=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixturePs 'start_wilbur_leased.ps1')+'" -NodeBirthTimeoutSeconds 0') $environment $fixture.Root
    Wait-Owned $timedOut 1
    Start-Sleep -Milliseconds 2000
    Assert-Local (-not(Test-Path -LiteralPath $lateNodeRecord)) 'Timed-out native CMD produced a late Node after gate release.'
    Add-Result 'actual-wilbur-wrapper-birth-timeout-no-late-node'

    $unownedFixture=New-Fixture 'managed-unowned-wilbur'
    $unownedPs=Join-Path $unownedFixture.Root 'platform_scripts\powershell';New-Item -ItemType Directory -Path $unownedPs -Force|Out-Null
    foreach($source in @('stack_launch_lease.ps1','stack_launch_processes.ps1','scaleworld_process_helpers.ps1','start_wilbur_leased.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $source) -Destination (Join-Path $unownedPs $source)}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_wilbur_native.bat') -Destination (Join-Path $unownedFixture.Root 'platform_scripts\cmd\start_wilbur_native.bat')
    $unownedNodeRecord=Join-Path $unownedFixture.Base 'unexpected-node.json'
    Write-FixtureText (Join-Path $unownedFixture.Root 'dist\index.js') 'require("fs").writeFileSync(process.env.SW_TEST_ARGV_RECORD,"unexpected");'
    $environment=@{NODE_EXE=$unownedFixture.Scope.NodePath;SERVER_ARGS='';SCALEWORLD_INSTALL_BASE=$unownedFixture.Base;SCALEWORLD_STACK_LAUNCH_GENERATION='';SCALEWORLD_STACK_LAUNCH_GRANT='';SW_TEST_ARGV_RECORD=$unownedNodeRecord}
    $withoutLease=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $unownedPs 'start_wilbur_leased.ps1')+'"') $environment $unownedFixture.Root
    Wait-Owned $withoutLease 1
    Assert-Local (-not(Test-Path -LiteralPath $unownedNodeRecord) -and -not(Test-Path -LiteralPath $unownedFixture.Scope.LeasePath)) 'Managed no-lease Wilbur wrapper spawned Node or fabricated a lease.'
    $incompleteOwner=Start-Launch $unownedFixture 'incomplete';Wait-File $incompleteOwner.Files.Entered;Release-Launch $incompleteOwner
    $before=[IO.File]::ReadAllText($unownedFixture.Scope.LeasePath)
    $withoutGeneration=Start-Owned $psExe ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $unownedPs 'start_wilbur_leased.ps1')+'"') $environment $unownedFixture.Root
    Wait-Owned $withoutGeneration 1
    Assert-Local (-not(Test-Path -LiteralPath $unownedNodeRecord) -and [IO.File]::ReadAllText($unownedFixture.Scope.LeasePath) -ceq $before) 'Managed incomplete no-generation wrapper spawned Node or mutated the lease.'
    Add-Result 'actual-wilbur-wrapper-managed-unowned-pre-spawn-rejection'

    }
    Invoke-MonitorFailureHarness

    foreach($source in $auditedSources){
        $expected=@($sourceProvenance|Where-Object{$_.name -ceq [IO.Path]::GetFileName($source)})[0]
        $actual=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Local ($actual -ceq $expected.sha256) ('Audited source changed during this run: '+$expected.name)
        $expected|Add-Member -NotePropertyName postRunSha256 -NotePropertyValue $actual
    }
    Assert-Local ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $harnessHash) 'Concurrency harness changed during its own run.'
    $command='powershell.exe -NoProfile -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_stack_launch_concurrency.ps1'
    if($MonitorOnly){$command+=' -MonitorOnly'}
    $report=[pscustomobject]@{schemaVersion=1;status='passed';suite=if($MonitorOnly){'monitor-failure-injection'}else{'complete-local-concurrency'};checks=$checks;powerShellVersion=$PSVersionTable.PSVersion.ToString();nodeVersion=$nodeVersion;nodeSource=$nodeSource;nodeSha256=$nodeSha256;sources=$sourceProvenance;sourceConsistency=[pscustomobject]@{prePostMatched=$true;owningSourceCount=$auditedSources.Count;harnessSha256=$harnessHash;assertions=($auditedSources.Count+1)};commands=@($command);fakeShutdownBoundary=[pscustomobject]@{function='Invoke-StackRecycleMonitorLocalShutdown';mode='unconditional override in every disposable monitor-module copy';workstationGuestShutdownExecuted=$false};cases=$results.ToArray();limitations=@('Scheduler restart timing and result codes are simulated entry calls; no real ScheduledTasks API is exercised.','Dead-owner reclaim retains a marker but does not simulate an OS reboot or boot-clock correction.','Harmless child creation tests the generation gate; hosted Unreal/Wilbur readiness, reset ACK, admission and media remain separate gates.','Node is copied from the recorded local executable into disposable canonical fixtures; hosted artifact installation remains a separate acceptance gate.','Wrapper error, exited-shell and timeout cases use fixture-only observation/delay injection while running the actual wrapper source.','Monitor tests copy the actual monitor/entry, unconditionally fake guest shutdown, add nonauthoritative result/exception/receipt tracing, and use short standard deadlines; real guest shutdown/provider stop requires hosted acceptance.','Recycler crash checkpoints simulate the guarded lease, marker, producer cancellation and real replacement entry sequence; the complete destructive helper is not executed.','The unregistered live Node models abrupt wrapper death before pinning; its absence of a durable pin must not authorize shutdown.')}
} finally {
    foreach($item in $owned){
        try{if(-not $item.Process.HasExited){$item.Process.Kill();[void]$item.Process.WaitForExit(5000)}}catch{}finally{$item.Process.Dispose()}
    }
    # A failing assertion can precede receipt tracking. Only this run's unique
    # disposable path can identify residual fixture children; retain a process
    # handle and compare its birth before termination, never kill a process tree.
    $leftovers=@()
    try{$leftovers=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{$_.ProcessId -ne $PID -and (([string]$_.CommandLine).IndexOf($fixtureBase,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.ExecutablePath).StartsWith($fixtureBase.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))})}
    catch{Write-Warning 'Residual fixture process discovery was unavailable; tracked handles were still cleaned up.'}
    foreach($leftover in $leftovers){
        $process=$null
        try{
            $process=[Diagnostics.Process]::GetProcessById([int]$leftover.ProcessId);$null=$process.Handle
            $birth=([DateTime]$leftover.CreationDate).ToUniversalTime()
            if([Math]::Floor([decimal]$process.StartTime.ToUniversalTime().Ticks/10) -eq [Math]::Floor([decimal]$birth.Ticks/10) -and $process.MainModule.FileName -ieq $leftover.ExecutablePath){$process.Kill();[void]$process.WaitForExit(5000)}
        }catch{}finally{if($null -ne $process){$process.Dispose()}}
    }
    foreach($receipt in $receipts){
        $full=[IO.Path]::GetFullPath($receipt);$temp=[IO.Path]::GetFullPath($fixtureBase).TrimEnd('\')+'\'
        if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^scaleworld-stack-launch-[0-9a-f-]+\.env$'){Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue}
    }
    if(-not $KeepFixtures){
        $full=[IO.Path]::GetFullPath($fixtureBase);$temp=[IO.Path]::GetFullPath($fixtureParent).TrimEnd('\')+'\'
        if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^scaleworld-stack-concurrency-[0-9a-f]+$'){throw 'Refusing unsafe concurrency fixture cleanup.'}
        $cleanupDeadline=[DateTime]::UtcNow.AddSeconds(15)
        while(Test-Path -LiteralPath $full){
            try{Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop}
            catch{if([DateTime]::UtcNow -ge $cleanupDeadline){throw};Start-Sleep -Milliseconds 200}
        }
    }
}
$survivors=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{$_.ProcessId -ne $PID -and (([string]$_.CommandLine).IndexOf($fixtureBase,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.ExecutablePath).StartsWith($fixtureBase.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))})
Assert-Local ($survivors.Count -eq 0) 'A disposable fixture producer survived cleanup.'
$report.checks=$checks
$report|Add-Member -NotePropertyName cleanup -NotePropertyValue ([pscustomobject]@{verified=$true;remainingFixtureProcesses=$survivors.Count;fixtureDirectoryRemoved=(-not(Test-Path -LiteralPath $fixtureBase));assertions=1})
$report|ConvertTo-Json -Depth 8
