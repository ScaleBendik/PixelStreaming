[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_launch_maintenance.ps1')
$script:Assertions=0;$script:Processes=@{};$script:FailSpawn=$false;$script:LastSpawn=$null
function Assert-True {param([bool]$Value,[string]$Message)$script:Assertions++;if(-not $Value){throw $Message}}
function Assert-Throws {param([scriptblock]$Action,[string]$Message)$script:Assertions++;$threw=$false;try{&$Action|Out-Null}catch{$threw=$true};if(-not $threw){throw $Message}}
function Get-CimInstance {param([string]$ClassName,[string]$Filter,[string]$ErrorAction)if($Filter -match 'ProcessId\s*=\s*(\d+)'){return $script:Processes[[int]$Matches[1]]};return @($script:Processes.Values)}
function New-FixtureProcess {
    param([int]$Id,[string]$Name,[string]$Exe,[string]$Command,[int]$Parent=0)
    $value=[pscustomobject]@{ProcessId=$Id;Name=$Name;ExecutablePath=$Exe;CommandLine=$Command;ParentProcessId=$Parent;CreationDate=[DateTime]::UtcNow.AddMinutes(-2)}
    $script:Processes[$Id]=$value;return $value
}
function New-FixtureRoot {
    param([string]$Base,[string]$Name,[switch]$Legacy)
    $root=Join-Path $Base ('runtime-releases\'+$Name+'\SignallingWebServer')
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'platform_scripts\cmd\node') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'platform_scripts\powershell') -Force)
    foreach($relative in @('platform_scripts\cmd\start_streamer_stack.bat','platform_scripts\cmd\start_wilbur_native.bat','platform_scripts\cmd\node\node.exe','platform_scripts\powershell\invoke_update_mode.ps1')){[IO.File]::WriteAllText((Join-Path $root $relative),'fixture')}
    if(-not $Legacy){foreach($file in @('stack_launch_lease.ps1','invoke_stack_launch_lease.ps1')){[IO.File]::WriteAllText((Join-Path $root ('platform_scripts\powershell\'+$file)),'fixture')}}
    return $root
}
function Start-StackLaunchReservedEntry {
    param($Scope,[string]$Grant,[string]$Kind,$LockHandle,[hashtable]$EnvironmentOverrides,[string]$TargetRepoRoot,[string]$LaunchMode)
    $script:LastSpawn=$PSBoundParameters
    if($script:FailSpawn){throw 'Fixture failure after revocation.'}
    $entry=Join-Path $TargetRepoRoot 'platform_scripts\cmd\start_streamer_stack.bat'
    $process=New-FixtureProcess 501 'cmd.exe' $env:ComSpec ('"'+$env:ComSpec+'" /c ""'+$entry+'" --'+$LaunchMode+'"')
    $identity=Get-StackLaunchProcessIdentity -ProcessId 501 -Process $process
    $identity|Add-Member -NotePropertyName entryPath -NotePropertyValue $entry
    [void](Set-StackLaunchHandoffEntry -Scope $Scope -Grant $Grant -EntryIdentity $identity -LockHandle $LockHandle)
    return $identity
}
function Import-InstallerFunctions {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install_pixelstreaming_runtime.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw 'Installer fixture parse failed.'}
    foreach($name in @('Assert-ChildPath','Get-NormalizedFullPath','Get-InstalledLeasePruneProtection')){
        $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
        . ([scriptblock]::Create($function.Extent.Text))
        Set-Item -LiteralPath ('Function:script:'+ $name) -Value (Get-Item ('Function:'+ $name)).ScriptBlock
    }
}
$scratch=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))) ('scaleworld-maintenance-unit-'+[Guid]::NewGuid().ToString('N'))
$handle=$null
try{
    [void](New-Item -ItemType Directory -Path $scratch)
    $root=New-FixtureRoot $scratch 'one';$root2=New-FixtureRoot $scratch 'two';$legacy=New-FixtureRoot $scratch 'legacy' -Legacy
    $scope=Get-StackLaunchLeaseScope $root $scratch;$scope2=Get-StackLaunchLeaseScope $root2 $scratch
    $ownerProcess=New-FixtureProcess 500 'cmd.exe' $env:ComSpec ('"'+$env:ComSpec+'" /c ""'+$scope.EntryPath+'""')
    $owner=Get-StackLaunchProcessIdentity -ProcessId 500 -Process $ownerProcess;$owner|Add-Member -NotePropertyName entryPath -NotePropertyValue $scope.EntryPath
    $callerPath=Join-Path $root 'platform_scripts\powershell\invoke_update_mode.ps1'
    $caller=New-FixtureProcess $PID 'powershell.exe' (Get-Process -Id $PID).Path ('"'+(Get-Process -Id $PID).Path+'" -NoProfile -ExecutionPolicy Bypass -File "'+$callerPath+'"') 500
    $caller.CreationDate=$ownerProcess.CreationDate.AddSeconds(1)
    $handle=Enter-StackLaunchLeaseLock $scope;$entered=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $owner -LockHandle $handle;Exit-StackLaunchLeaseLock $handle;$handle=$null
    $context=Get-StackLaunchMaintenanceContext -SourceRepoRoot $root -InstallBase $scratch -GenerationId $entered.GenerationId -CallerScriptPath $callerPath
    Assert-True ($context.Scope.RepoRoot -ceq $scope.RepoRoot -and $context.Owner.pid -eq 500) 'Context must pin source physical root and direct owner before activation.'
    Assert-True ($null -eq (Get-StackLaunchMaintenanceContext -SourceRepoRoot $root -InstallBase $scratch -CallerScriptPath $callerPath)) 'No-generation source preserves legacy behavior.'
    $hash=(Get-FileHash $scope.LeasePath).Hash
    Assert-Throws {Get-StackLaunchMaintenanceContext -SourceRepoRoot $root -InstallBase $scratch -GenerationId ([Guid]::NewGuid().ToString('D')) -CallerScriptPath $callerPath} 'Ambient generation alone must not authorize maintenance.'
    $caller.ParentProcessId=999
    Assert-Throws {Get-StackLaunchMaintenanceContext -SourceRepoRoot $root -InstallBase $scratch -GenerationId $entered.GenerationId -CallerScriptPath $callerPath} 'An unrelated PowerShell caller cannot transfer the owner.'
    $caller.ParentProcessId=500;$caller.CreationDate=$ownerProcess.CreationDate.AddSeconds(-1)
    Assert-Throws {Get-StackLaunchMaintenanceContext -SourceRepoRoot $root -InstallBase $scratch -GenerationId $entered.GenerationId -CallerScriptPath $callerPath} 'Parent birth must precede maintenance caller birth.'
    $caller.CreationDate=$ownerProcess.CreationDate.AddSeconds(1)
    Assert-Throws {Get-StackMaintenanceScriptInvocation ('powershell.exe -Command "echo -File '+$callerPath+'"')} 'A -Command mention cannot prove the executing script.'
    Assert-True ((Get-FileHash $scope.LeasePath).Hash -ceq $hash) 'Rejected context must not mutate ownership.'
    foreach($targetScope in @($scope,$scope2)){
        [void](New-FixtureProcess 502 'node.exe' $targetScope.NodePath ('"'+$targetScope.NodePath+'" .\dist\index.js'))
        Assert-Throws {Start-StackLaunchMaintenanceHandoff -Context $context -LauncherPath $scope2.EntryPath} 'Live source or target Node must deny handoff.'
        Assert-True ((Get-FileHash $scope.LeasePath).Hash -ceq $hash -and $script:Processes.ContainsKey(502)) 'Denied handoff preserves lease and live Node.'
        $script:Processes.Remove(502)
        [void](New-FixtureProcess 503 'cmd.exe' $env:ComSpec ('"'+$env:ComSpec+'" /c ""'+(Join-Path $targetScope.RepoRoot 'platform_scripts\cmd\start_wilbur_native.bat')+'""'))
        Assert-Throws {Start-StackLaunchMaintenanceHandoff -Context $context -LauncherPath $scope2.EntryPath} 'Already-born native producer must deny handoff before Node birth.'
        $script:Processes.Remove(503)
    }
    $result=Start-StackLaunchMaintenanceHandoff -Context $context -LauncherPath $scope2.EntryPath -LaunchMode validation
    Assert-True ($result.LeaseAware -and $result.LaunchMode -ceq 'validation' -and $script:LastSpawn.LaunchMode -ceq 'validation') 'Changed-root validation must reserve validation, not normal.'
    Assert-True ((Read-StackLaunchLease $scope).generationId -cne $entered.GenerationId -and (Read-StackLaunchLease $scope).handoffMode -ceq 'validation') 'Handoff durably revokes old generation with mode binding.'
    Assert-True ($script:LastSpawn.EnvironmentOverrides.WATCHDOG_STREAMER_HEALTH_PATH -ceq '' -and $script:LastSpawn.EnvironmentOverrides.WATCHDOG_RESTART_COMMAND -ceq '') 'Target must regenerate source-specific watchdog paths.'
    $handle=Enter-StackLaunchLeaseLock $scope;Write-StackLaunchLease $scope $entered.Lease $handle;Exit-StackLaunchLeaseLock $handle;$handle=$null;$script:Processes.Remove(501)
    $script:FailSpawn=$true
    Assert-Throws {Start-StackLaunchMaintenanceHandoff -Context $context -LauncherPath $scope.EntryPath} 'Spawn failure must propagate to maintenance failure handling.'
    $failed=Read-StackLaunchLease $scope
    Assert-True ($failed.phase -ceq 'handoff' -and $failed.generationId -cne $entered.GenerationId -and $failed.owner.pid -eq $owner.pid) 'Failed spawn must retain revoked handoff and original live owner.'
    Assert-Throws {Start-StackLaunchProvisioningHandoffIfChanged -Context $context -InstalledRoot (Split-Path -Parent $root)} 'Revoked source cannot return unchanged-root provisioning success on a retry.'
    Assert-True ((Read-StackLaunchLease $scope).generationId -ceq $failed.generationId) 'Provisioning retry must preserve revoked ownership without source continuation.'
    $script:FailSpawn=$false;$handle=Enter-StackLaunchLeaseLock $scope;Write-StackLaunchLease $scope $entered.Lease $handle;Exit-StackLaunchLeaseLock $handle;$handle=$null
    Assert-True ($null -eq (Start-StackLaunchProvisioningHandoffIfChanged -Context $context -InstalledRoot (Split-Path -Parent $root))) 'Owned unchanged-root provisioning continues in the same attempt.'
    $result=Start-StackLaunchMaintenanceHandoff -Context $context -LauncherPath (Join-Path $legacy 'platform_scripts\cmd\start_streamer_stack.bat')
    Assert-True (-not $result.LeaseAware -and $script:LastSpawn.EnvironmentOverrides.SCALEWORLD_STACK_LAUNCH_GENERATION -ceq '' -and (Read-StackLaunchLease $scope).phase -ceq 'handoff') 'Legacy target is intentionally unclaimed, never presented as completed/admitted.'
    $rootMoved=$root+'-moved';$scratchPrefix=[IO.Path]::GetFullPath($scratch).TrimEnd('\')+'\'
    foreach($path in @($root,$rootMoved)){if(-not ([IO.Path]::GetFullPath($path)).StartsWith($scratchPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe relocated-root fixture target.'}}
    $relocationHash=(Get-FileHash $scope.LeasePath).Hash
    [IO.Directory]::Move($root,$rootMoved)
    try{
        [void](New-Item -ItemType Junction -Path $root -Target $root2)
        Assert-Throws {Start-StackLaunchMaintenanceHandoff -Context $context -LauncherPath $scope2.EntryPath} 'A formerly physical source converted to an alias must not gain retargeted authority.'
        Assert-True ((Get-FileHash $scope.LeasePath).Hash -ceq $relocationHash) 'Relocated managed Git source must fail before any lease write.'
    }finally{
        if(Test-Path -LiteralPath $root){$junction=Get-Item -LiteralPath $root -Force;if($junction.LinkType -ne 'Junction'){throw 'Unsafe relocated-root fixture cleanup.'};[IO.Directory]::Delete($root)}
        [IO.Directory]::Move($rootMoved,$root)
    }
    Import-InstallerFunctions
    $handle=Enter-StackLaunchLeaseLock $scope;Write-StackLaunchLease $scope $entered.Lease $handle;Exit-StackLaunchLeaseLock $handle;$handle=$null
    $releases=Join-Path $scratch 'runtime-releases'
    $protection=Get-InstalledLeasePruneProtection $scratch $releases
    Assert-True (-not $protection.SkipPrune -and $protection.ProtectedRoot -ieq (Split-Path -Parent $root)) 'Exact source release is retained independently of argv and target helpers.'
    [IO.File]::WriteAllText($scope.LeasePath,'{')
    Assert-True (Get-InstalledLeasePruneProtection $scratch $releases).SkipPrune 'Malformed lease must prevent pruning.'
    [IO.File]::WriteAllText($scope.LeasePath,('x'*32769))
    Assert-True (Get-InstalledLeasePruneProtection $scratch $releases).SkipPrune 'Oversized lease must prevent pruning.'
    [IO.File]::WriteAllBytes($scope.LeasePath,[byte[]]@(0xc3,0x28))
    Assert-True (Get-InstalledLeasePruneProtection $scratch $releases).SkipPrune 'Invalid UTF8 lease must prevent pruning.'
    [IO.File]::WriteAllText($scope.LeasePath,(@{schemaVersion=1;repoRoot=(Join-Path $scratch 'outside\SignallingWebServer')}|ConvertTo-Json))
    Assert-True (Get-InstalledLeasePruneProtection $scratch $releases).SkipPrune 'Unclassified root must not authorize deletion.'
    Remove-Item -LiteralPath $scope.LeasePath
    Assert-True (-not (Get-InstalledLeasePruneProtection $scratch $releases).SkipPrune) 'Missing lease preserves legacy installer behavior.'
    Write-Output ("Stack launch maintenance: {0} assertions passed (mocked process discovery/spawn; real filesystem/mutex)." -f $script:Assertions)
}finally{
    if($null -ne $handle){Exit-StackLaunchLeaseLock $handle}
    $absolute=[IO.Path]::GetFullPath($scratch);$parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'scaleworld-maintenance-unit-*'){throw 'Unsafe fixture cleanup target.'}
    if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
