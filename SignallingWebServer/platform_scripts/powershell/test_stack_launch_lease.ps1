[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
$script:Assertions=0
$script:Processes=@{}
$script:CimFailure=$false
$script:OsBootUtc=[DateTime]::UtcNow.AddHours(-1).ToString('o')
$script:PathAlias='';$script:PathAliasTarget=''
function Test-Path {
    param([string]$LiteralPath,[string]$Path,[string]$PathType)
    if($script:PathAlias -and $LiteralPath -ieq $script:PathAlias){return $true}
    if($script:PathAlias -and $LiteralPath.StartsWith($script:PathAlias+'\',[StringComparison]::OrdinalIgnoreCase)){return Microsoft.PowerShell.Management\Test-Path -LiteralPath ($script:PathAliasTarget+$LiteralPath.Substring($script:PathAlias.Length))}
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Item {
    param([string]$LiteralPath,[switch]$Force,[string]$ErrorAction)
    if($script:PathAlias -and $LiteralPath -ieq $script:PathAlias){return [pscustomobject]@{LinkType='Junction';Target=@($script:PathAliasTarget)}}
    return Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function Get-CimInstance {
    param([string]$ClassName,[string]$Filter,[string]$ErrorAction)
    if($script:CimFailure){throw 'Fixture process discovery failure.'}
    if($Filter -match 'ProcessId\s*=\s*(\d+)'){return $script:Processes[[int]$Matches[1]]}
    return @($script:Processes.Values)
}
function Get-StackLaunchOsBootUtc {
    if([string]::IsNullOrWhiteSpace($script:OsBootUtc)){throw 'Fixture unavailable OS boot time.'}
    return $script:OsBootUtc
}
function Assert-True {param([bool]$Value,[string]$Message) $script:Assertions++;if(-not $Value){throw $Message}}
function Assert-Throws {param([scriptblock]$Action,[string]$Message) $script:Assertions++;$threw=$false;try{&$Action|Out-Null}catch{$threw=$true};if(-not $threw){throw $Message}}
function New-FakeProcess {
    param([int]$Id,[string]$Name,[string]$Exe,[string]$Command,[int]$Parent=0)
    $process=[pscustomobject]@{ProcessId=$Id;Name=$Name;ExecutablePath=$Exe;CommandLine=$Command;ParentProcessId=$Parent;CreationDate=([DateTime]::UtcNow.AddSeconds(-100+$Id))}
    $script:Processes[$Id]=$process
    return $process
}
function New-TestRoot {
    param([string]$Base,[string]$Name)
    $root=Join-Path $Base ($Name+'\SignallingWebServer');$cmd=Join-Path $root 'platform_scripts\cmd'
    [void](New-Item -ItemType Directory -Path (Join-Path $cmd 'node') -Force)
    foreach($file in @('start_streamer_stack.bat','start_dev_turn.bat','node\node.exe')){[IO.File]::WriteAllText((Join-Path $cmd $file),'fixture')}
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'dist') -Force)
    [IO.File]::WriteAllText((Join-Path $root 'dist\index.js'),'fixture')
    return $root
}
function New-TestOwner {
    param($Scope,[int]$Id)
    $process=New-FakeProcess $Id 'cmd.exe' $env:ComSpec ('"'+$env:ComSpec+'" /d /s /c ""'+$Scope.EntryPath+'""')
    $identity=Get-StackLaunchProcessIdentity -ProcessId $Id -Process $process
    $identity|Add-Member -NotePropertyName entryPath -NotePropertyValue $Scope.EntryPath
    return $identity
}
$tempRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'));$scratch=Join-Path $tempRoot ('scaleworld-stack-lease-test-'+[Guid]::NewGuid().ToString('N'))
$handle=$null
try{
    [void](New-Item -ItemType Directory -Path $scratch)
    $root=New-TestRoot $scratch 'runtime1';$scope=Get-StackLaunchLeaseScope $root $scratch
    $root2=New-TestRoot $scratch 'runtime2';$scope2=Get-StackLaunchLeaseScope $root2 $scratch
    Assert-True ($scope.MutexName -ceq $scope2.MutexName) 'Artifact roots must share the install-base lock.'
    Assert-True ($scope.RepoRoot -cne $scope2.RepoRoot) 'Exact artifact roots must remain distinct.'
    Assert-Throws {Get-StackLaunchCanonicalPath 'C:\'} 'Drive roots must not become relative launch scope paths.'
    $alias=Join-Path $scratch 'release-alias'
    $script:PathAlias=$alias;$script:PathAliasTarget=$root
    $aliasScope=Get-StackLaunchLeaseScope $alias $scratch
    Assert-True ($aliasScope.RepoRoot -ieq $scope.RepoRoot -and $aliasScope.MutexName -ceq $scope.MutexName) 'Junction and physical release must share canonical root and lock.'
    $script:PathAliasTarget=$alias
    Assert-Throws {Get-StackLaunchCanonicalPath $alias} 'Reparse cycles must fail closed.'
    $script:PathAlias=''
    $owner=New-TestOwner $scope 101;$other=New-TestOwner $scope 102
    Assert-True (Test-StackLaunchProcessIdentity $owner) 'Exact owner must be live.'
    $selfProcess=New-FakeProcess $PID 'powershell.exe' ((Get-Process -Id $PID).Path) 'fixture-entry' 101
    $selfProcess.CreationDate=$script:Processes[101].CreationDate.AddMilliseconds(100)
    Assert-True (Test-StackLaunchIdentityEqual (Get-StackLaunchOwnerIdentity $scope) $owner) 'Direct entry must bind the parent born before this helper.'
    $script:PathAlias=$alias;$script:PathAliasTarget=$root
    $originalCommand=$script:Processes[101].CommandLine
    $script:Processes[101].CommandLine='"'+$env:ComSpec+'" /c ""'+(Join-Path $alias 'platform_scripts\cmd\start_streamer_stack.bat')+'""'
    $aliasOwner=Get-StackLaunchOwnerIdentity $scope
    Assert-True ($aliasOwner.entryPath -ieq $scope.EntryPath -and $aliasOwner.invocationPath -ieq (Join-Path $alias 'platform_scripts\cmd\start_streamer_stack.bat')) 'Capture must retain physical root and original lexical invocation separately.'
    $script:PathAliasTarget=$root2
    Assert-True (Test-StackLaunchProcessIdentity $aliasOwner) 'Retargeting an alias must not erase a live original owner.'
    $script:Processes[101].CommandLine=$originalCommand
    Assert-True (-not(Test-StackLaunchProcessIdentity $aliasOwner)) 'A changed literal invocation must not match the captured owner.'
    $script:PathAlias=''
    $selfBirth=$selfProcess.CreationDate;$selfProcess.CreationDate=$script:Processes[101].CreationDate.AddMilliseconds(-100)
    Assert-Throws {Get-StackLaunchOwnerIdentity $scope} 'A same-root parent PID reused after entry birth must be rejected.'
    $selfProcess.CreationDate=$selfBirth;$script:Processes.Remove($PID)
    $birth=$script:Processes[101].CreationDate;$script:Processes[101].CreationDate=$birth.AddSeconds(1)
    Assert-True (-not(Test-StackLaunchProcessIdentity $owner)) 'PID reuse must not satisfy a lease.'
    $script:Processes[101].CreationDate=$birth
    Assert-True (-not(Test-StackLaunchCmdInvocation ('"'+$env:ComSpec+'" /c echo "'+$scope.EntryPath+'"') $scope.EntryPath)) 'A path mention must not be an invocation.'
    Assert-True (-not(Test-StackLaunchCmdInvocation ('"'+$env:ComSpec+'" /c "'+$scope.EntryPath+'" & echo other') $scope.EntryPath)) 'Shell chains must not claim ownership.'
    Assert-True (-not(Test-StackLaunchCmdInvocation $script:Processes[101].CommandLine $scope2.EntryPath)) 'Another root must be excluded.'
    $handle=Enter-StackLaunchLeaseLock $scope
    Assert-Throws {Write-StackLaunchLease -Scope $scope -Lease @{} -LockHandle $null} 'Mutation must require the lifecycle lock.'
    $first=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $owner -LockHandle $handle
    Assert-True ($first.Decision -ceq 'Enter') 'Initial entry must start.'
    Assert-True ((Read-StackLaunchLease $scope).generationId -ceq $first.GenerationId) 'Entry must be durable.'
    $fakeCmd=Join-Path $scratch 'cmd.exe';[IO.File]::WriteAllText($fakeCmd,'fixture')
    $fakeProcess=New-FakeProcess 110 'cmd.exe' $fakeCmd ('"'+$fakeCmd+'" /c "'+$scope.EntryPath+'"')
    $fakeIdentity=Get-StackLaunchProcessIdentity -ProcessId 110 -Process $fakeProcess
    $fakeIdentity|Add-Member -NotePropertyName entryPath -NotePropertyValue $scope.EntryPath
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $fakeIdentity -LockHandle $handle} 'A different executable merely named cmd.exe must not claim a launch.'
    $before=(Get-FileHash -LiteralPath $scope.LeasePath).Hash
    $duplicate=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $other -LockHandle $handle
    Assert-True ($duplicate.Decision -ceq 'Skip') 'An in-progress owner must suppress duplicate entry.'
    Assert-True ((Get-FileHash -LiteralPath $scope.LeasePath).Hash -ceq $before) 'Duplicate entry must not mutate the lease.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root -InstallBase $scratch} 'Empty generation must not bypass a live full-stack owner.'
    $nodeProcess=New-FakeProcess 120 'node.exe' $scope.NodePath ('"'+$scope.NodePath+'" .\dist\index.js') 101
    $node=Get-StackLaunchProcessIdentity -ProcessId 120 -Process $nodeProcess
    Assert-True (-not(Test-StackLaunchNodeInvocation ('"'+$scope.NodePath+'" other.js --log="'+(Join-Path $scope.RepoRoot 'dist\index.js')+'"') $scope.RepoRoot)) 'A script-path mention in later Node arguments must not count as Wilbur.'
    Assert-True (Test-StackLaunchNodeInvocation ('"'+$scope.NodePath+'" "'+(Join-Path $scope.RepoRoot 'dist\index.js')+'"') $scope.RepoRoot) 'Absolute Wilbur script argument must be recognized.'
    Assert-True ((Get-StackLaunchNodeIdentity $scope $owner).pid -eq 120) 'Completion must discover the exact owned Node.'
    Assert-Throws {Complete-StackLaunchAttempt -Scope $scope -GenerationId $first.GenerationId -OwnerIdentity $owner -NodeIdentity $node -LockHandle $handle} 'Completion must not invent a Node birth pin.'
    Assert-Throws {Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $node -LockHandle $null} 'Node registration must hold the lifecycle lock.'
    $beforePin=(Get-FileHash -LiteralPath $scope.LeasePath).Hash
    Assert-Throws {Register-StackLaunchNode -Scope $scope -GenerationId ([Guid]::NewGuid().ToString('D')) -NodeIdentity $node -LockHandle $handle} 'Wrong generation must not register a Node.'
    $originalNodeCommand=$nodeProcess.CommandLine;$nodeProcess.CommandLine='node.exe other.js'
    Assert-Throws {Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $node -LockHandle $handle} 'Portable Node running another script must not register.'
    $nodeProcess.CommandLine=$originalNodeCommand
    Assert-True ((Get-FileHash -LiteralPath $scope.LeasePath).Hash -ceq $beforePin) 'Rejected registration must not mutate the lease.'
    [void](Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $node -LockHandle $handle)
    Assert-True (Test-StackLaunchIdentityEqual (Read-StackLaunchLease $scope).activeNode $node) 'Node birth pin must be durable before completion.'
    $secondNodeProcess=New-FakeProcess 121 'node.exe' $scope.NodePath ('"'+$scope.NodePath+'" .\dist\index.js') 101
    $secondNode=Get-StackLaunchProcessIdentity -ProcessId 121 -Process $secondNodeProcess
    $pinnedHash=(Get-FileHash -LiteralPath $scope.LeasePath).Hash
    Assert-Throws {Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $secondNode -LockHandle $handle} 'A competing live Node must not replace the observed pin.'
    Assert-Throws {Complete-StackLaunchAttempt -Scope $scope -GenerationId $first.GenerationId -OwnerIdentity $owner -NodeIdentity $secondNode -LockHandle $handle} 'Completion must reject another live Node.'
    Assert-True ((Get-FileHash -LiteralPath $scope.LeasePath).Hash -ceq $pinnedHash) 'Competing Node rejection must not mutate the lease.'
    $script:Processes.Remove(121)
    $pinBirth=$nodeProcess.CreationDate;$nodeProcess.CreationDate=$pinBirth.AddSeconds(1)
    Assert-Throws {Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $node -LockHandle $handle} 'A reused Node PID must not satisfy the captured birth.'
    $nodeProcess.CreationDate=$pinBirth
    [void](Complete-StackLaunchAttempt -Scope $scope -GenerationId $first.GenerationId -OwnerIdentity $owner -NodeIdentity $node -LockHandle $handle)
    $completedLease=Read-StackLaunchLease $scope
    Assert-True (Test-StackLaunchIdentityEqual $completedLease.activeNode $completedLease.completedNode) 'Completion must promote the identical observed Node.'
    $secondNodeProcess=New-FakeProcess 121 'node.exe' $scope.NodePath ('"'+$scope.NodePath+'" .\dist\index.js') 101
    $secondNode=Get-StackLaunchProcessIdentity -ProcessId 121 -Process $secondNodeProcess
    Assert-Throws {Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $secondNode -LockHandle $handle} 'A completed live Node must not be replaced by a competing repair.'
    $script:Processes.Remove(120)
    [void](Register-StackLaunchNode -Scope $scope -GenerationId $first.GenerationId -NodeIdentity $secondNode -LockHandle $handle)
    $repairedNodeLease=Read-StackLaunchLease $scope
    Assert-True (Test-StackLaunchIdentityEqual $repairedNodeLease.activeNode $secondNode) 'A dead completed Node can be replaced within its generation.'
    Assert-True (Test-StackLaunchIdentityEqual $repairedNodeLease.activeNode $repairedNodeLease.completedNode) 'Dead-Node repair must atomically replace both pins.'
    $script:Processes.Remove(121);$script:Processes[120]=$nodeProcess
    Write-StackLaunchLease -Scope $scope -Lease $completedLease -LockHandle $handle
    $script:Processes.Remove(101)
    $nodeBirth=$script:Processes[120].CreationDate;$script:Processes[120].CreationDate=$nodeBirth.AddSeconds(1)
    $reusedNode=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $other -Mode normal -LockHandle $handle
    Assert-True ($reusedNode.Decision -ceq 'Skip' -and $reusedNode.Reason -ceq 'NodeUnclassified') 'A reused live portable Node birth must deny repair rather than borrow its predecessor pin.'
    $script:Processes[120].CreationDate=$nodeBirth
    Write-StackLaunchLease -Scope $scope -Lease $completedLease -LockHandle $handle
    $retry=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $other -Mode normal -LockHandle $handle
    Assert-True ($retry.Decision -ceq 'Skip') 'Post-completion scheduled retry must skip while pinned Node lives.'
    $repair=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $other -Mode recovery -InheritedGeneration $first.GenerationId -LockHandle $handle
    Assert-True ($repair.Decision -ceq 'Enter') 'Markerless watchdog recovery must repair even with an existing Node.'
    Assert-True ($repair.GenerationId -ceq $first.GenerationId) 'Retained Node must keep its environment generation during component repair.'
    Assert-True ((Get-StackLaunchNodeIdentity $scope $other).pid -eq 120) 'Recovery may retain its prior exact Node pin.'
    Assert-True (Test-StackLaunchIdentityEqual $repair.Lease.activeNode $node) 'Markerless recovery must preserve its live source birth pin.'
    $script:Processes.Remove(102)
    $third=New-TestOwner $scope 103
    $resumed=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $third -Mode normal -LockHandle $handle
    Assert-True ($resumed.Decision -ceq 'Enter') 'Dead incomplete owner must permit missing-component repair.'
    Assert-True ($resumed.GenerationId -ceq $first.GenerationId) 'A live retained Node must not borrow a newly minted generation.'
    Assert-True (Test-StackLaunchIdentityEqual $resumed.Lease.activeNode $node) 'Incomplete-owner repair must preserve its live Node pin.'
    $helperProcess=New-FakeProcess 130 'powershell.exe' ((Get-Process -Id $PID).Path) 'fixture-recycler'
    $helper=Get-StackLaunchProcessIdentity -ProcessId 130 -Process $helperProcess
    $recycle=Begin-StackLaunchRecycle -Scope $scope -RecycleId 'opaque-test-operation' -RecyclerIdentity $helper -LockHandle $handle
    Assert-True ($recycle.PreviousLease.generationId -ceq $resumed.GenerationId) 'Recycle must retain the old lease for scoped cancellation.'
    Assert-True ((Read-StackLaunchLease $scope).recycler.recycleId -ceq 'opaque-test-operation') 'Operation identity is opaque, not a launch UUID.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root -InstallBase $scratch -GenerationId $resumed.GenerationId} 'Old native spawn must be fenced.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root -InstallBase $scratch} 'Standalone native spawn must reject a live recycler.'
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $third -Mode recovery -Grant $recycle.Grant -LockHandle $handle} 'Unpinned replacement grant must be rejected.'
    $script:Processes.Remove(120) # Model the recycler's required old-Node absence.
    $replacement=New-TestOwner $scope 104
    [void](Set-StackLaunchReplacementEntry -Scope $scope -Grant $recycle.Grant -EntryIdentity $replacement -LockHandle $handle)
    $replacementBirth=$script:Processes[104].CreationDate;$script:Processes[104].CreationDate=$replacementBirth.AddSeconds(1)
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $replacement -Mode recovery -Grant $recycle.Grant -LockHandle $handle} 'Reused replacement CMD PID must not redeem a reserved grant.'
    $script:Processes[104].CreationDate=$replacementBirth
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $third -Mode recovery -Grant $recycle.Grant -LockHandle $handle} 'A grant must not transfer to another PID.'
    $entered=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $replacement -Mode recovery -InheritedGeneration $resumed.GenerationId -Grant $recycle.Grant -LockHandle $handle
    Assert-True ($entered.GenerationId -ceq $recycle.Grant) 'Exact replacement grant must override stale inherited epoch.'
    $gate=Enter-StackLaunchGate -RepoRoot $root -InstallBase $scratch -GenerationId $entered.GenerationId
    Exit-StackLaunchGate $gate
    $stale=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $third -Mode recovery -InheritedGeneration $resumed.GenerationId -LockHandle $handle
    Assert-True ($stale.Decision -ceq 'Skip') 'Old watchdog/full entry must not steal replacement ownership.'
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $replacement -Mode recovery -Grant $recycle.Grant -LockHandle $handle} 'Replacement grant is single-use.'
    $script:Processes.Remove(130)
    $handoff=Begin-StackLaunchHandoff -Scope $scope -GenerationId $entered.GenerationId -OwnerIdentity $replacement -TargetRepoRoot $root2 -LockHandle $handle
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root -InstallBase $scratch -GenerationId $entered.GenerationId} 'Git handoff must revoke the old attempt.'
    $target=New-TestOwner $scope2 105
    [void](Set-StackLaunchHandoffEntry -Scope $scope -Grant $handoff.Grant -EntryIdentity $target -LockHandle $handle)
    $newRoot=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $target -Grant $handoff.Grant -InheritedGeneration $entered.GenerationId -LockHandle $handle
    Assert-True ($newRoot.Lease.repoRoot -ceq $scope2.RepoRoot) 'Pinned handoff must change the exact root.'
    $normalLease=$newRoot.Lease
    $validationHandoff=Begin-StackLaunchHandoff -Scope $scope2 -GenerationId $newRoot.GenerationId -OwnerIdentity $target -TargetRepoRoot $root2 -LaunchMode validation -LockHandle $handle
    $validationOwner=New-TestOwner $scope2 150
    [void](Set-StackLaunchHandoffEntry -Scope $scope2 -Grant $validationHandoff.Grant -EntryIdentity $validationOwner -LockHandle $handle)
    $validationHash=(Get-FileHash -LiteralPath $scope.LeasePath).Hash
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $validationOwner -Grant $validationHandoff.Grant -Mode normal -LockHandle $handle} 'Validation grant must not authorize normal maintenance recursion.'
    Assert-True ((Get-FileHash -LiteralPath $scope.LeasePath).Hash -ceq $validationHash) 'Wrong launch mode must not consume a grant.'
    $validationEntry=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $validationOwner -Grant $validationHandoff.Grant -Mode validation -LockHandle $handle
    Assert-True ($validationEntry.Decision -ceq 'Enter') 'Same-root validation must redeem its exact mode-bound grant.'
    $legacyModeLease=$normalLease.PSObject.Copy();$legacyModeLease.PSObject.Properties.Remove('handoffMode')
    Assert-True ((Get-StackLaunchHandoffMode $legacyModeLease) -ceq 'normal') 'Old handoff schema defaults only to normal.'
    Assert-Throws {Begin-StackLaunchHandoff -Scope $scope2 -GenerationId $newRoot.GenerationId -OwnerIdentity $target -TargetRepoRoot $root2 -LaunchMode recovery -LockHandle $handle} 'Maintenance must not accept recovery launch mode.'
    Write-StackLaunchLease -Scope $scope2 -Lease $normalLease -LockHandle $handle
    $script:Processes.Remove(150)
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root -InstallBase $scratch -GenerationId $newRoot.GenerationId} 'Active UUID must not authorize another artifact root.'
    $script:Processes.Remove(105)
    $reboot=New-TestOwner $scope2 106
    [IO.File]::WriteAllText((Join-Path $scratch 'retained-marker.json'),'{"phase":"intent"}')
    $boot=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $reboot -LockHandle $handle
    Assert-True ($boot.Decision -ceq 'Enter') 'Dead prior-boot owners must not become a marker-only deadlock.'
    $valid=[IO.File]::ReadAllText($scope.LeasePath)
    [IO.File]::WriteAllText($scope.LeasePath,'{')
    Assert-Throws {Read-StackLaunchLease $scope} 'Unreadable registry must fail closed.'
    [IO.File]::WriteAllText($scope.LeasePath,$valid)
    [IO.File]::WriteAllBytes($scope.LeasePath,[byte[]]@(0xc3,0x28))
    Assert-Throws {Read-StackLaunchLease $scope} 'Invalid UTF8 registry must fail closed.'
    [IO.File]::WriteAllText($scope.LeasePath,('x'*32769))
    Assert-Throws {Read-StackLaunchLease $scope} 'Bounded registry snapshot must reject oversized content.'
    [IO.File]::WriteAllText($scope.LeasePath,$valid)
    $broken=ConvertFrom-Json -InputObject $valid;$broken.phase='completed';$broken.completedNode=$null
    [IO.File]::WriteAllText($scope.LeasePath,($broken|ConvertTo-Json -Depth 8))
    Assert-Throws {Read-StackLaunchLease $scope} 'Completed state without a Node pin must fail closed.'
    [IO.File]::WriteAllText($scope.LeasePath,$valid)
    $broken=ConvertFrom-Json -InputObject $valid;$broken.activeNode=$node
    [IO.File]::WriteAllText($scope.LeasePath,($broken|ConvertTo-Json -Depth 8))
    Assert-Throws {Read-StackLaunchLease $scope} 'Another artifact root must not supply an active Node pin.'
    [IO.File]::WriteAllText($scope.LeasePath,$valid)
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $reboot -InheritedGeneration 'bad & text' -LockHandle $handle} 'Untrusted inherited generation must not become BAT code.'

    # Monitored recycler fixtures use the second root, so the live first-root
    # Node also proves that shutdown classification respects the exact root.
    $script:Processes[120]=$nodeProcess
    $monitorProcess=New-FakeProcess 150 'powershell.exe' ((Get-Process -Id $PID).Path) 'fixture-monitor'
    $monitorIdentity=Get-StackLaunchProcessIdentity -ProcessId 150 -Process $monitorProcess
    $helperProcess=New-FakeProcess 140 'powershell.exe' ((Get-Process -Id $PID).Path) 'fixture-monitored-recycler'
    $helperIdentity=Get-StackLaunchProcessIdentity -ProcessId 140 -Process $helperProcess
    $planned=[Guid]::NewGuid().ToString('D');$dispatch=[Guid]::NewGuid().ToString('D')
    $monitorArgs=@{Scope=$scope2;RecycleId='monitor-operation';RecyclerIdentity=$helperIdentity;MonitorIdentity=$monitorIdentity;HelperLaunchId=$dispatch;LockHandle=$handle}
    $beforeMonitor=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    Assert-Throws {Begin-StackLaunchRecycle @monitorArgs -PlannedGenerationId $boot.GenerationId} 'Monitor planned generation must revoke the previous attempt.'
    Assert-Throws {Begin-StackLaunchRecycle -Scope $scope2 -RecycleId 'monitor-operation' -RecyclerIdentity $helperIdentity -MonitorIdentity $monitorIdentity -LockHandle $handle} 'A partial monitor tuple must fail before revocation.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $beforeMonitor) 'Rejected monitor arming must not mutate the current lease.'
    $monitored=Begin-StackLaunchRecycle @monitorArgs -PlannedGenerationId $planned
    $ownershipArgs=@{Scope=$scope2;GenerationId=$planned;RecycleId='monitor-operation';HelperLaunchId=$dispatch;MonitorIdentity=$monitorIdentity;RecyclerIdentity=$helperIdentity;LockHandle=$handle}
    Assert-True ($monitored.Grant -ceq $planned) 'Replacement must use the monitor prearmed generation.'
    Assert-True ((Get-StackLaunchMonitorOwnership @ownershipArgs).Disposition -ceq 'Current') 'A complete exact monitor tuple with no current Node must own recovery.'
    $armedLease=Read-StackLaunchLease $scope2;$armedJson=[IO.File]::ReadAllText($scope2.LeasePath)
    $legacy=ConvertFrom-Json -InputObject $armedJson;$legacy.PSObject.Properties.Remove('monitor')
    [IO.File]::WriteAllText($scope2.LeasePath,($legacy|ConvertTo-Json -Depth 8))
    Assert-True ($null -eq (Get-StackLaunchLeaseMonitor (Read-StackLaunchLease $scope2))) 'A legacy lease without optional monitor remains readable.'
    [IO.File]::WriteAllText($scope2.LeasePath,$armedJson)
    foreach($kind in @('missingField','wrongGeneration','wrongHelper','missingStoppingMonitor')){
        $invalid=ConvertFrom-Json -InputObject $armedJson
        switch($kind){
            'missingField' {$invalid.monitor.PSObject.Properties.Remove('helperLaunchId')}
            'wrongGeneration' {$invalid.monitor.generationId=[Guid]::NewGuid().ToString('D')}
            'wrongHelper' {$invalid.monitor.recyclerIdentity.creationUtc=[DateTime]::UtcNow.ToString('o')}
            'missingStoppingMonitor' {$invalid.phase='stopping';$invalid.monitor=$null}
        }
        [IO.File]::WriteAllText($scope2.LeasePath,($invalid|ConvertTo-Json -Depth 8))
        Assert-Throws {Read-StackLaunchLease $scope2} ('Malformed monitor must fail closed: '+$kind)
    }
    [IO.File]::WriteAllText($scope2.LeasePath,$armedJson)
    $wrongMonitor=$monitorIdentity|Select-Object *;$wrongMonitor.creationUtc=[DateTime]::UtcNow.ToString('o')
    $wrongArgs=$ownershipArgs.Clone();$wrongArgs.MonitorIdentity=$wrongMonitor
    Assert-True ((Set-StackLaunchStopping @wrongArgs).Disposition -ceq 'Superseded') 'Wrong monitor birth must not stop the attempt.'
    $wrongArgs=$ownershipArgs.Clone();$wrongArgs.HelperLaunchId=[Guid]::NewGuid().ToString('D')
    Assert-True ((Set-StackLaunchStopping @wrongArgs).Disposition -ceq 'Superseded') 'Another dispatch must not stop the attempt.'
    Assert-True ([IO.File]::ReadAllText($scope2.LeasePath) -ceq $armedJson) 'Rejected monitor stop must leave the lease unchanged.'
    $monitorBirth=$monitorProcess.CreationDate;$monitorProcess.CreationDate=$monitorBirth.AddSeconds(1)
    Assert-True ((Get-StackLaunchMonitorOwnership @ownershipArgs).Disposition -ceq 'Superseded') 'Reused monitor PID must not retain ownership.'
    $monitorProcess.CreationDate=$monitorBirth
    $script:Processes.Remove(140)
    $ungrantedOwner=New-TestOwner $scope2 160
    Assert-True ((Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $ungrantedOwner -LockHandle $handle).Decision -ceq 'Skip') 'Live monitor must exclude ungranted entry after helper death.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root2 -InstallBase $scratch} 'An empty generation must not bypass a live monitor.'
    Assert-True ((Get-StackLaunchMonitorOwnership @ownershipArgs).Disposition -ceq 'Current') 'Exact dead helper pin remains owned by its live monitor.'
    $script:Processes[140]=$helperProcess
    $monitoredOwner=New-TestOwner $scope2 161
    [void](Set-StackLaunchReplacementEntry -Scope $scope2 -Grant $planned -EntryIdentity $monitoredOwner -LockHandle $handle)
    $claimed=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $monitoredOwner -Mode recovery -Grant $planned -LockHandle $handle
    Assert-True (Test-StackLaunchIdentityEqual $claimed.Lease.monitor.identity $monitorIdentity) 'Replacement claim must carry its independent monitor pin.'
    Assert-True ($claimed.Lease.monitor.helperLaunchId -ceq $dispatch) 'Replacement claim must preserve the exact monitor dispatch.'
    $gate=Enter-StackLaunchGate -RepoRoot $root2 -InstallBase $scratch -GenerationId $planned
    Exit-StackLaunchGate $gate
    Assert-True ((Get-StackLaunchMonitorOwnership @ownershipArgs).Disposition -ceq 'Current') 'Prearmed replacement generation remains allowed while monitor owns recovery.'
    $strayProcess=New-FakeProcess 170 'node.exe' $scope2.NodePath ('"'+$scope2.NodePath+'" unknown-script.js') 161
    $preStopHash=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    Assert-True ((Get-StackLaunchMonitorOwnership @ownershipArgs).Disposition -ceq 'NodeUnclassified') 'Unregistered portable Node must conservatively deny shutdown regardless of argv.'
    Assert-True ((Set-StackLaunchStopping @ownershipArgs).Disposition -ceq 'NodeUnclassified') 'Final stop must repeat portable Node classification under the lock.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $preStopHash) 'An unclassified Node must not change the lease to stopping.'
    $strayProcess.ExecutablePath=$null
    Assert-Throws {Set-StackLaunchStopping @ownershipArgs} 'Unknown live Node executable must fail closed.'
    $strayProcess.ExecutablePath=$scope2.NodePath;$script:Processes.Remove(170)
    $script:CimFailure=$true
    Assert-Throws {Set-StackLaunchStopping @ownershipArgs} 'Process discovery failure must deny terminal stop.'
    $script:CimFailure=$false
    Assert-True ((Get-StackLaunchMonitorOwnership @ownershipArgs).Disposition -ceq 'Current') 'First no-Node observation must not itself stop recovery.'
    $currentNodeProcess=New-FakeProcess 171 'node.exe' $scope2.NodePath ('"'+$scope2.NodePath+'" .\dist\index.js') 161
    $currentNode=Get-StackLaunchProcessIdentity -ProcessId 171 -Process $currentNodeProcess
    [void](Register-StackLaunchNode -Scope $scope2 -GenerationId $planned -NodeIdentity $currentNode -LockHandle $handle)
    Assert-True ((Set-StackLaunchStopping @ownershipArgs).Disposition -ceq 'NodeAlive') 'Node born after first no-Node observation must prevent final stop.'
    [void](Complete-StackLaunchAttempt -Scope $scope2 -GenerationId $planned -OwnerIdentity $monitoredOwner -NodeIdentity $currentNode -LockHandle $handle)
    $completedMonitorHash=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    Assert-True ((Set-StackLaunchStopping @ownershipArgs).Disposition -ceq 'NodeAlive') 'Exact live completed replacement Node must hand back existing agent authority.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $completedMonitorHash) 'NodeAlive must never mutate recovery/admission state.'
    $script:Processes.Remove(171)
    Write-StackLaunchLease -Scope $scope2 -Lease $armedLease -LockHandle $handle
    [void](Set-StackLaunchReplacementEntry -Scope $scope2 -Grant $planned -EntryIdentity $monitoredOwner -LockHandle $handle)
    $stopping=Set-StackLaunchStopping @ownershipArgs
    Assert-True ($stopping.Disposition -ceq 'Stopping' -and (Read-StackLaunchLease $scope2).phase -ceq 'stopping') 'An exactly owned attempt with no portable Node must durably fence all new spawn.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root2 -InstallBase $scratch -GenerationId $planned} 'Stopping must reject generation-bound native/Node spawn.'
    Assert-Throws {Enter-StackLaunchGate -RepoRoot $root2 -InstallBase $scratch} 'Stopping must reject standalone spawn.'
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $monitoredOwner -Mode recovery -Grant $planned -LockHandle $handle} 'Stopping must prevent a reserved replacement from redeeming its grant.'
    Assert-True ((Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $ungrantedOwner -LockHandle $handle).Decision -ceq 'Skip') 'Stopping with a live monitor must suppress ungranted entry.'
    $stoppingLease=Read-StackLaunchLease $scope2
    $newer=New-StackLaunchLease $scope2 $ungrantedOwner ([Guid]::NewGuid().ToString('D'))
    Write-StackLaunchLease -Scope $scope2 -Lease $newer -LockHandle $handle
    $newerHash=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    Assert-True ((Set-StackLaunchStopping @ownershipArgs).Disposition -ceq 'Superseded') 'An older monitor must not stop a newer lease generation.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $newerHash) 'Superseded stop must leave the newer attempt untouched.'
    Write-StackLaunchLease -Scope $scope2 -Lease $stoppingLease -LockHandle $handle
    foreach($deadId in @(140,150,161)){$script:Processes.Remove($deadId)}
    $sameBootHash=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    $terminalHelperProcess=New-FakeProcess 180 'powershell.exe' ((Get-Process -Id $PID).Path) 'fixture-terminal-recycle'
    $terminalHelper=Get-StackLaunchProcessIdentity -ProcessId 180 -Process $terminalHelperProcess
    Assert-Throws {Begin-StackLaunchRecycle -Scope $scope2 -RecycleId 'later-operation' -RecyclerIdentity $terminalHelper -LockHandle $handle} 'Direct recycle API must not overwrite a terminal stopping fence after monitor death.'
    $script:Processes.Remove(180)
    Assert-True ((Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $ungrantedOwner -LockHandle $handle).Decision -ceq 'Skip') 'Dead terminal monitor in the same OS boot must not reopen entry.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $sameBootHash) 'Same-boot terminal fence must remain durable and unchanged.'
    $script:OsBootUtc=''
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $ungrantedOwner -LockHandle $handle} 'Missing OS boot proof must not release a terminal fence.'
    $script:OsBootUtc=$monitorBirth.AddSeconds(5).ToUniversalTime().ToString('o')
    Assert-True ((Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $ungrantedOwner -Mode recovery -LockHandle $handle).Decision -ceq 'Skip') 'Only normal boot entry may release a prior terminal fence.'
    $afterBoot=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $ungrantedOwner -LockHandle $handle
    Assert-True ($afterBoot.Decision -ceq 'Enter' -and $afterBoot.GenerationId -cne $planned) 'Dead monitor/helper identities after reboot must permit a new fenced attempt.'
    Assert-True ($null -eq (Get-StackLaunchLeaseMonitor $afterBoot.Lease)) 'A repaired boot attempt must not inherit a dead terminal monitor.'

    # An orphan born before wrapper registration may survive monitor retirement.
    # Neither a scheduler retry nor a reserved grant may trust-migrate it.
    $script:Processes.Remove(160)
    Write-StackLaunchLease -Scope $scope2 -Lease $armedLease -LockHandle $handle
    $orphanProcess=New-FakeProcess 172 'node.exe' $scope2.NodePath ('"'+$scope2.NodePath+'" .\dist\index.js')
    $orphan=Get-StackLaunchProcessIdentity -ProcessId 172 -Process $orphanProcess
    $lateOwner=New-TestOwner $scope2 190
    $fixtureState=Join-Path $root2 'state';[void](New-Item -ItemType Directory -Path $fixtureState -Force)
    $fixtureHealth=Join-Path $fixtureState 'streamer-health.json';$fixtureConfig=Join-Path $fixtureState 'instance-config-snapshot.json'
    [IO.File]::WriteAllText($fixtureHealth,'healthy-node-sentinel');[IO.File]::WriteAllText($fixtureConfig,'config-sentinel')
    $orphanLeaseHash=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    $healthHash=(Get-FileHash -LiteralPath $fixtureHealth).Hash;$configHash=(Get-FileHash -LiteralPath $fixtureConfig).Hash
    $orphanRetry=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $lateOwner -LockHandle $handle
    Assert-True ($orphanRetry.Decision -ceq 'Skip' -and $orphanRetry.Reason -ceq 'NodeUnclassified') 'Dead owner/helper/monitor must not allow a retry over its live unregistered Node.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $orphanLeaseHash) 'Unregistered Node retry must leave the lease byte-for-byte unchanged.'
    Assert-True ((Get-FileHash -LiteralPath $fixtureHealth).Hash -ceq $healthHash -and (Get-FileHash -LiteralPath $fixtureConfig).Hash -ceq $configHash) 'Denied entry must preserve existing health and config.'
    Assert-True (Test-StackLaunchProcessIdentity $orphan) 'Denied entry must preserve the live Node.'
    $savedOrphanLease=[IO.File]::ReadAllText($scope2.LeasePath);Remove-Item -LiteralPath $scope2.LeasePath -Force
    $unleased=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $lateOwner -LockHandle $handle
    Assert-True ($unleased.Decision -ceq 'Skip' -and $unleased.Reason -ceq 'NodeUnclassified' -and $null -eq $unleased.Lease) 'No lease must not permit trust-migration of a live scoped Node.'
    Assert-True (-not(Test-Path -LiteralPath $scope2.LeasePath)) 'No-lease refusal must not manufacture a generation or registry.'
    [IO.File]::WriteAllText($scope2.LeasePath,$savedOrphanLease)
    $orphanProcess.ExecutablePath=$null
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $lateOwner -LockHandle $handle} 'Unknown Node executable at entry must fail closed.'
    $orphanProcess.ExecutablePath=$scope2.NodePath
    $script:CimFailure=$true
    Assert-Throws {Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $lateOwner -LockHandle $handle} 'Process discovery failure at entry must not mutate the registry.'
    $script:CimFailure=$false
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $orphanLeaseHash) 'Ambiguous entry must preserve the lease.'
    $script:Processes[140]=$helperProcess
    $reservedLateOwner=New-TestOwner $scope2 191
    [void](Set-StackLaunchReplacementEntry -Scope $scope2 -Grant $planned -EntryIdentity $reservedLateOwner -LockHandle $handle)
    $reservedHash=(Get-FileHash -LiteralPath $scope2.LeasePath).Hash
    $reservedOrphan=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $reservedLateOwner -Mode recovery -Grant $planned -LockHandle $handle
    Assert-True ($reservedOrphan.Decision -ceq 'Skip' -and $reservedOrphan.Reason -ceq 'NodeUnclassified') 'An exact reserved replacement must also refuse an unregistered scoped Node.'
    Assert-True ((Get-FileHash -LiteralPath $scope2.LeasePath).Hash -ceq $reservedHash) 'Reserved refusal must preserve its grant and lease without claiming ownership.'
    $script:Processes.Remove(172)
    $claimedAfterAbsence=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $reservedLateOwner -Mode recovery -Grant $planned -LockHandle $handle
    Assert-True ($claimedAfterAbsence.Decision -ceq 'Enter') 'Exact reservation may enter after scoped Node absence is established.'
    $script:Processes.Remove(140);$script:Processes.Remove(191)
    $unrelated=Enter-StackLaunchAttempt -Scope $scope2 -OwnerIdentity $lateOwner -LockHandle $handle
    Assert-True ($unrelated.Decision -ceq 'Enter') 'A live portable Node from an unrelated exact root must not deny entry.'
    Write-Output ("Stack launch lease: {0} assertions passed (mocked process discovery; real filesystem/mutex)." -f $script:Assertions)
}finally{
    if($null -ne $handle){Exit-StackLaunchLeaseLock $handle}
    $resolved=[IO.Path]::GetFullPath($scratch)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($tempRoot),[StringComparison]::OrdinalIgnoreCase)-or [IO.Path]::GetFileName($resolved) -notlike 'scaleworld-stack-lease-test-*'){throw 'Fixture cleanup escaped its temporary root.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
