# Dot-source before any runtime activation. Maintenance transfers launch
# ownership; it never proves Ready, reset completion, or admission.
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_reserved_entry.ps1')

function Get-StackMaintenanceScriptInvocation {
    param([string]$CommandLine)
    $pattern='(?i)^\s*(?:"[^"]+"|\S+)\s+(?:(?:-NoProfile|-NonInteractive|-NoLogo)\s+|-ExecutionPolicy\s+\S+\s+|-WindowStyle\s+\S+\s+)*-File\s+(?:"(?<path>[^"]+)"|(?<path>[^\s"]+))(?:\s|$)'
    if($CommandLine -notmatch $pattern){throw 'Maintenance must use a direct -File invocation.'}
    return Get-StackLaunchInvocationPath $Matches.path
}

function Get-StackLaunchMaintenanceContext {
    param([Parameter(Mandatory=$true)][string]$SourceRepoRoot,[string]$InstallBase='C:\PixelStreaming',[string]$GenerationId='', [Parameter(Mandatory=$true)][string]$CallerScriptPath)
    if([string]::IsNullOrWhiteSpace($GenerationId)){return $null}
    $generation=ConvertTo-StackLaunchUuid $GenerationId
    $scope=Get-StackLaunchLeaseScope $SourceRepoRoot $InstallBase
    $caller=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop | Select-Object -First 1
    if($null -eq $caller -or $caller.Name -ine 'powershell.exe'){throw 'Managed maintenance requires the direct PowerShell process.'}
    $scriptPath=Get-StackMaintenanceScriptInvocation ([string]$caller.CommandLine)
    if((Get-StackLaunchCanonicalPath $scriptPath) -ine (Get-StackLaunchCanonicalPath $CallerScriptPath)){throw 'Maintenance caller script is not the expected source script.'}
    $callerIdentity=Get-StackLaunchProcessIdentity -ProcessId $PID -Process $caller
    $handle=Enter-StackLaunchLeaseLock $scope
    try{
        $lease=Read-StackLaunchLease $scope
        if($null -eq $lease -or $lease.phase -cne 'starting' -or $lease.repoRoot -ine $scope.RepoRoot -or $lease.generationId -cne $generation -or $null -eq $lease.owner -or [int]$caller.ParentProcessId -ne [int]$lease.owner.pid -or -not(Test-StackLaunchProcessIdentity $lease.owner)){throw 'Maintenance is not a direct child of the current launch owner.'}
        if([DateTimeOffset]::Parse($lease.owner.creationUtc) -gt [DateTimeOffset]::Parse($callerIdentity.creationUtc)){throw 'Maintenance parent PID was reused after this caller began.'}
        return [pscustomobject]@{Scope=$scope;GenerationId=$generation;Owner=$lease.owner;Caller=$callerIdentity;CallerScriptInvocationPath=$scriptPath}
    }finally{Exit-StackLaunchLeaseLock $handle}
}

function Assert-StackLaunchMaintenanceContext {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Context.Scope $LockHandle
    if((Get-StackLaunchCanonicalPath $Context.Scope.RepoRoot) -ine $Context.Scope.RepoRoot -or (Get-StackLaunchCanonicalPath $Context.Scope.EntryPath) -ine $Context.Scope.EntryPath){throw 'The captured source root was relocated during activation; managed maintenance handoff is unsupported.'}
    $caller=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop | Select-Object -First 1
    if($null -eq $caller -or $Context.Caller.pid -ne $PID -or -not(Test-StackLaunchProcessIdentity -Identity $Context.Caller -Process $caller) -or [int]$caller.ParentProcessId -ne [int]$Context.Owner.pid -or (Get-StackMaintenanceScriptInvocation ([string]$caller.CommandLine)) -ine $Context.CallerScriptInvocationPath -or -not(Test-StackLaunchProcessIdentity $Context.Owner)){throw 'The captured maintenance caller/owner changed.'}
    $lease=Read-StackLaunchLease $Context.Scope
    if($null -eq $lease -or $lease.phase -cne 'starting' -or $lease.repoRoot -ine $Context.Scope.RepoRoot -or $lease.generationId -cne $Context.GenerationId -or -not(Test-StackLaunchIdentityEqual $lease.owner $Context.Owner)){throw 'The captured maintenance launch was revoked.'}
    $monitor=Get-StackLaunchLeaseMonitor $lease
    if((Test-StackLaunchProcessIdentity $lease.recycler) -or ($null -ne $monitor -and (Test-StackLaunchProcessIdentity $monitor.identity))){throw 'A live recovery owns this launch.'}
}

function Assert-StackMaintenanceNativeProducerAbsent {
    param([Parameter(Mandatory=$true)][object[]]$Scopes)
    $nativePaths=@($Scopes | ForEach-Object { Join-Path $_.RepoRoot 'platform_scripts\cmd\start_wilbur_native.bat' })
    foreach($process in @(Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction Stop)){
        if($process.Name -ine 'cmd.exe'){continue}
        if([string]::IsNullOrWhiteSpace([string]$process.CommandLine)){throw 'Cannot classify a live CMD before maintenance handoff.'}
        $invocation=Get-StackLaunchCmdInvocation ([string]$process.CommandLine)
        if($null -eq $invocation){
            if([string]$process.CommandLine -match '(?i)start_wilbur_native\.bat'){throw 'Cannot exclude a latent native Node producer.'}
            continue
        }
        try{$path=Get-StackLaunchCanonicalPath $invocation.Path}catch{
            if([IO.Path]::GetFileName($invocation.Path) -ieq 'start_wilbur_native.bat'){throw 'Cannot resolve a latent native Node producer.'}
            continue
        }
        if(@($nativePaths | Where-Object {$_ -ieq $path}).Count -gt 0){throw 'A live native Node producer prevents maintenance handoff.'}
    }
}

function Start-StackLaunchMaintenanceHandoff {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$LauncherPath,[ValidateSet('normal','validation')][string]$LaunchMode='validation',[hashtable]$EnvironmentOverrides=@{})
    $LaunchMode=$LaunchMode.ToLowerInvariant()
    $launcher=Get-StackLaunchCanonicalPath $LauncherPath
    $targetRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $launcher))
    $target=Get-StackLaunchLeaseScope $targetRoot $Context.Scope.InstallBase
    if($launcher -ine $target.EntryPath){throw 'Maintenance target must be the exact full-stack launcher.'}
    $leaseModule=Test-Path -LiteralPath (Join-Path $target.RepoRoot 'platform_scripts\powershell\stack_launch_lease.ps1') -PathType Leaf
    $leaseCli=Test-Path -LiteralPath (Join-Path $target.RepoRoot 'platform_scripts\powershell\invoke_stack_launch_lease.ps1') -PathType Leaf
    if($leaseModule -ne $leaseCli){throw 'Maintenance target has an incomplete launch lease helper pair.'}
    $overrides=@{WATCHDOG_STREAMER_HEALTH_PATH='';WATCHDOG_RESTART_COMMAND='';WATCHDOG_WILBUR_RESTART_COMMAND='';WATCHDOG_UNREAL_RESTART_COMMAND=''}
    foreach($key in $EnvironmentOverrides.Keys){$overrides[[string]$key]=[string]$EnvironmentOverrides[$key]}
    if(-not $leaseModule){$overrides.SCALEWORLD_STACK_LAUNCH_GENERATION=''}
    $handle=Enter-StackLaunchLeaseLock $Context.Scope
    try{
        Assert-StackLaunchMaintenanceContext $Context $handle
        foreach($scope in @($Context.Scope,$target)){
            if(-not(Test-StackLaunchEntryNodeOwnership -Scope $scope)){throw 'A live scoped Node prevents maintenance handoff.'}
        }
        Assert-StackMaintenanceNativeProducerAbsent @($Context.Scope,$target)
        $handoff=Begin-StackLaunchHandoff -Scope $Context.Scope -GenerationId $Context.GenerationId -OwnerIdentity $Context.Owner -TargetRepoRoot $target.RepoRoot -LaunchMode $LaunchMode -LockHandle $handle
        # A failed spawn deliberately leaves revoked, durable handoff ownership.
        # The existing maintenance failure path holds/stops the instance.
        $entry=Start-StackLaunchReservedEntry -Scope $Context.Scope -Grant $handoff.Grant -Kind handoff -LockHandle $handle -TargetRepoRoot $target.RepoRoot -LaunchMode $LaunchMode -EnvironmentOverrides $overrides
        if(-not $leaseModule){Write-Warning 'Reserved legacy runtime CMD does not consume the lease grant; existing maintenance validation and instance stop remain required.'}
        return [pscustomobject]@{GenerationId=$handoff.Grant;EntryIdentity=$entry;TargetScope=$target;LeaseAware=[bool]$leaseModule;LaunchMode=$LaunchMode}
    }finally{Exit-StackLaunchLeaseLock $handle}
}

function Start-StackLaunchProvisioningHandoffIfChanged {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$InstalledRoot)
    $targetRoot=Get-StackLaunchCanonicalPath (Join-Path $InstalledRoot 'SignallingWebServer')
    $handle=Enter-StackLaunchLeaseLock $Context.Scope
    try{
        Assert-StackLaunchMaintenanceContext $Context $handle
        if($targetRoot -ieq $Context.Scope.RepoRoot){return $null}
    }finally{Exit-StackLaunchLeaseLock $handle}
    return Start-StackLaunchMaintenanceHandoff -Context $Context -LauncherPath (Join-Path $targetRoot 'platform_scripts\cmd\start_streamer_stack.bat') -LaunchMode normal -EnvironmentOverrides @{STACK_ENABLE_PROVISIONING_MODE='false';STACK_ENABLE_UPDATE_MODE='false';STACK_ENABLE_BOOT_GIT_SYNC='false';SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE='runtime_artifact'}
}
