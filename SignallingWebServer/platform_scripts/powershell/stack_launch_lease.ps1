# Dot-source only. This registry fences launch attempts; it is not admission or
# reset-completion authority. All mutations require the short lifecycle lock.
Set-StrictMode -Version Latest

function ConvertTo-StackLaunchUuid {
    param([string]$Value, [switch]$AllowEmpty)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) { return '' }
        throw 'A launch UUID is required.'
    }
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParseExact($Value, 'D', [ref]$parsed) -and -not [Guid]::TryParseExact($Value, 'N', [ref]$parsed)) {
        throw 'Invalid launch UUID.'
    }
    if ($parsed -eq [Guid]::Empty) { throw 'An empty launch UUID is invalid.' }
    return $parsed.ToString('D')
}

function Get-StackLaunchCanonicalPath {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$AllowMissing)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOfAny([char[]]"`r`n") -ge 0) { throw 'A local absolute launch path is required.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if($full -match '^[A-Za-z]:$'){throw 'A launch path must be below the drive root.'}
    if (-not (Test-Path -LiteralPath $full)) {
        if ($AllowMissing) { return $full }
        throw 'A required launch path does not exist.'
    }
    $visited=@{}
    for($hop=0;$hop -lt 32;$hop++){
        $key=$full.ToLowerInvariant()
        if($visited.ContainsKey($key)){throw 'Launch path contains a reparse cycle.'}
        $visited[$key]=$true
        $drive=[IO.Path]::GetPathRoot($full);$parts=@($full.Substring($drive.Length).Split('\')|Where-Object{$_});$cursor=$drive;$changed=$false
        for($index=0;$index -lt $parts.Count;$index++){
            $cursor=Join-Path $cursor $parts[$index]
            if(-not(Test-Path -LiteralPath $cursor)){
                if($AllowMissing){return $full}
                throw 'A required launch path does not exist.'
            }
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            $link=$item.PSObject.Properties['LinkType']
            if($null -ne $link -and [string]$link.Value -in @('Junction','SymbolicLink')){
                $targets=@($item.Target)
                if($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])){throw 'Launch reparse target is ambiguous.'}
                $target=[string]$targets[0]
                if($target.StartsWith('\??\')){$target=$target.Substring(4)}
                if($target.StartsWith('\\?\')){$target=$target.Substring(4)}
                if(-not[IO.Path]::IsPathRooted($target)){$target=Join-Path (Split-Path -Parent $cursor) $target}
                if($target -notmatch '^[A-Za-z]:\\'){throw 'Launch reparse target must be local.'}
                for($tail=$index+1;$tail -lt $parts.Count;$tail++){$target=Join-Path $target $parts[$tail]}
                $full=[IO.Path]::GetFullPath($target).TrimEnd('\');$changed=$true;break
            }
        }
        if(-not $changed){return $full}
    }
    throw 'Launch path exceeds the reparse hop limit.'
}

function Get-StackLaunchLeaseScope {
    param([Parameter(Mandatory=$true)][string]$RepoRoot, [string]$InstallBase='C:\PixelStreaming')
    $root = Get-StackLaunchCanonicalPath $RepoRoot
    $base = Get-StackLaunchCanonicalPath $InstallBase
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($base.ToLowerInvariant())))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
    return [pscustomobject]@{
        RepoRoot=$root; InstallBase=$base
        LeasePath=(Join-Path $base 'state\stack-launch-lease.json')
        MutexName=('Global\ScaleWorldStackLaunch-' + $key)
        EntryPath=(Join-Path $root 'platform_scripts\cmd\start_streamer_stack.bat')
        NodePath=(Join-Path $root 'platform_scripts\cmd\node\node.exe')
    }
}

function Enter-StackLaunchLeaseLock {
    param([Parameter(Mandatory=$true)]$Scope, [ValidateRange(0,120)][int]$TimeoutSeconds=15)
    $mutex = [Threading.Mutex]::new($false, $Scope.MutexName)
    $acquired=$false; $abandoned=$false
    try {
        try { $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired=$true; $abandoned=$true }
        if (-not $acquired) { throw 'Timed out acquiring the stack launch lifecycle lock.' }
        return [pscustomobject]@{Mutex=$mutex; MutexName=$Scope.MutexName; Acquired=$true; Abandoned=$abandoned; OwnerPid=$PID; OwnerThread=[Threading.Thread]::CurrentThread.ManagedThreadId}
    } catch { $mutex.Dispose(); throw }
}

function Assert-StackLaunchLeaseLock {
    param($Scope, $LockHandle)
    if ($null -eq $LockHandle -or -not $LockHandle.Acquired -or $LockHandle.MutexName -cne $Scope.MutexName -or $LockHandle.OwnerPid -ne $PID -or $LockHandle.OwnerThread -ne [Threading.Thread]::CurrentThread.ManagedThreadId) {
        throw 'The caller must hold the matching stack launch lifecycle lock.'
    }
}

function Exit-StackLaunchLeaseLock {
    param([Parameter(Mandatory=$true)]$Handle)
    if ($Handle.Acquired) {
        try { $Handle.Mutex.ReleaseMutex() } finally { $Handle.Acquired=$false; $Handle.Mutex.Dispose() }
    }
}

function Get-StackLaunchCreationUtc {
    param($Process)
    if ($null -eq $Process.CreationDate) { throw 'A process creation time is required.' }
    $value=$Process.CreationDate
    if ($value -is [DateTime]) { return $value.ToUniversalTime().ToString('o') }
    return [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('o')
}

function Get-StackLaunchOsBootUtc {
    $systems=@(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop)
    if($systems.Count -ne 1 -or $null -eq $systems[0].LastBootUpTime){throw 'A positive OS boot time is required to release a terminal launch fence.'}
    $value=$systems[0].LastBootUpTime
    if($value -is [DateTime]){return $value.ToUniversalTime().ToString('o')}
    return [DateTimeOffset]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('o')
}

function Get-StackLaunchProcessIdentity {
    param([Parameter(Mandatory=$true)][int]$ProcessId, $Process)
    if ($ProcessId -le 0) { throw 'A positive process ID is required.' }
    if ($null -eq $Process) { $Process=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction Stop | Select-Object -First 1 }
    if ($null -eq $Process) { return $null }
    if ([int]$Process.ProcessId -ne $ProcessId -or [string]::IsNullOrWhiteSpace([string]$Process.ExecutablePath)) { throw 'Process identity is incomplete.' }
    return [pscustomobject]@{pid=$ProcessId; creationUtc=(Get-StackLaunchCreationUtc $Process); executablePath=(Get-StackLaunchCanonicalPath ([string]$Process.ExecutablePath)); name=[string]$Process.Name}
}

function Get-StackLaunchInvocationPath {
    param([string]$Path)
    # Keep the original lexical absolute token: retargeting a junction must not
    # turn an unchanged, live CMD into a different/dead owner.
    if($Path.Length -gt 4096 -or $Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOfAny([char[]]"`r`n") -ge 0){throw 'An absolute invocation path is required.'}
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-StackLaunchCmdInvocation {
    param([string]$CommandLine)
    # Recognize the executed /c command, never a mere path mention or shell chain.
    if ($CommandLine -notmatch '^\s*(?:"[^"]+"|\S+)\s+(?<tail>.+)$') { return $null }
    $tail=$Matches.tail
    if ($tail -notmatch '^(?:(?:/[dDsS])\s+)*(/[cC])\s+(?<command>.+)$') { return $null }
    $command=$Matches.command.Trim()
    if ($command.StartsWith('""') -and $command.EndsWith('"')) { $command=$command.Substring(1,$command.Length-2).Trim() }
    if ($command -match '^(?i:call)\s+(.+)$') { $command=$Matches[1].Trim() }
    if ($command -match '^"(?<path>[^"]+)"(?<args>.*)$') { $path=$Matches.path; $arguments=$Matches.args }
    elseif ($command -match '^(?<path>\S+)(?<args>.*)$') { $path=$Matches.path; $arguments=$Matches.args }
    else { return $null }
    if ($arguments -match '[&|<>^\r\n]') { return $null }
    try { return [pscustomobject]@{Path=(Get-StackLaunchInvocationPath $path);Arguments=$arguments.Trim()} }
    catch { return $null }
}

function Test-StackLaunchCmdInvocation {
    param([string]$CommandLine, [string]$EntryPath)
    $invocation=Get-StackLaunchCmdInvocation $CommandLine
    if($null -eq $invocation){return $false}
    try { return (Get-StackLaunchCanonicalPath $invocation.Path) -ieq (Get-StackLaunchCanonicalPath $EntryPath) }
    catch { return $false }
}

function Test-StackLaunchProcessIdentity {
    param($Identity, $Process)
    if ($null -eq $Identity) { return $false }
    if ($null -eq $Process) { $Process=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$Identity.pid) -ErrorAction Stop | Select-Object -First 1 }
    if ($null -eq $Process) { return $false }
    $actual=Get-StackLaunchProcessIdentity -ProcessId ([int]$Identity.pid) -Process $Process
    if ($actual.creationUtc -cne [string]$Identity.creationUtc -or $actual.executablePath -ine [string]$Identity.executablePath -or $actual.name -ine [string]$Identity.name) { return $false }
    $entry=$Identity.PSObject.Properties['entryPath']
    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        $lexical=$Identity.PSObject.Properties['invocationPath']
        if($null -ne $lexical){
            $invocation=Get-StackLaunchCmdInvocation ([string]$Process.CommandLine)
            return $actual.name -ieq 'cmd.exe' -and $null -ne $invocation -and $invocation.Path -ieq (Get-StackLaunchInvocationPath ([string]$lexical.Value))
        }
        return $actual.name -ieq 'cmd.exe' -and (Test-StackLaunchCmdInvocation -CommandLine ([string]$Process.CommandLine) -EntryPath ([string]$entry.Value))
    }
    return $true
}

function Test-StackLaunchCmdExecutable {
    param([string]$Path)
    $windows=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    foreach($relative in @('System32\cmd.exe','SysWOW64\cmd.exe')){
        $candidate=Join-Path $windows $relative
        if((Test-Path -LiteralPath $candidate) -and (Get-StackLaunchCanonicalPath $candidate) -ieq $Path){return $true}
    }
    return $false
}

function Get-StackLaunchOwnerIdentity {
    param([Parameter(Mandatory=$true)]$Scope)
    $self=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $self) { throw 'The entry process identity is unavailable.' }
    $parent=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$self.ParentProcessId) -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $parent -or $parent.Name -ine 'cmd.exe' -or -not (Test-StackLaunchCmdInvocation -CommandLine ([string]$parent.CommandLine) -EntryPath $Scope.EntryPath)) {
        throw 'Lease entry must be called directly by the exact full-stack CMD.'
    }
    if([DateTimeOffset]::Parse((Get-StackLaunchCreationUtc $parent)) -gt [DateTimeOffset]::Parse((Get-StackLaunchCreationUtc $self))){
        throw 'Lease entry parent PID was reused after this entry process began.'
    }
    $identity=Get-StackLaunchProcessIdentity -ProcessId ([int]$parent.ProcessId) -Process $parent
    if(-not(Test-StackLaunchCmdExecutable $identity.executablePath)){throw 'Full-stack owner must use the Windows CMD executable.'}
    $identity | Add-Member -NotePropertyName entryPath -NotePropertyValue $Scope.EntryPath
    $identity | Add-Member -NotePropertyName invocationPath -NotePropertyValue (Get-StackLaunchCmdInvocation ([string]$parent.CommandLine)).Path
    return $identity
}

function Assert-StackLaunchStoredIdentity {
    param($Identity, [switch]$AllowNull)
    if ($null -eq $Identity) { if ($AllowNull) { return }; throw 'Lease process identity is missing.' }
    foreach ($key in @('pid','creationUtc','executablePath','name')) { if ($null -eq $Identity.PSObject.Properties[$key]) { throw 'Lease process identity is invalid.' } }
    if ([int]$Identity.pid -le 0 -or [string]::IsNullOrWhiteSpace([string]$Identity.name)) { throw 'Lease process identity is invalid.' }
    $stamp=[DateTimeOffset]::Parse([string]$Identity.creationUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($stamp.Offset -ne [TimeSpan]::Zero) { throw 'Lease process creation time must use UTC.' }
    [void](Get-StackLaunchCanonicalPath ([string]$Identity.executablePath) -AllowMissing)
    if($null -ne $Identity.PSObject.Properties['invocationPath']){[void](Get-StackLaunchInvocationPath ([string]$Identity.invocationPath))}
}

function Get-StackLaunchHandoffMode {
    param($Lease)
    if($null -eq $Lease.PSObject.Properties['handoffMode']){return 'normal'}
    if([string]$Lease.handoffMode -cnotin @('normal','validation')){throw 'Invalid handoff launch mode.'}
    return [string]$Lease.handoffMode
}

function ConvertTo-StackLaunchRecycleId {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 512 -or $Value.IndexOfAny([char[]]"`r`n") -ge 0){throw 'A bounded recycle operation identity is required.'}
    return $Value
}

function ConvertTo-StackLaunchHelperId {
    param([string]$Value)
    $id=ConvertTo-StackLaunchUuid $Value
    if($id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'){throw 'A UUIDv4 helper dispatch identity is required.'}
    return $id
}

function Get-StackLaunchLeaseMonitor {
    param($Lease)
    # Optional for reading a prior lease written before monitoring was added.
    # Current production recyclers must arm and pass a monitor before Begin.
    if($null -eq $Lease -or $null -eq $Lease.PSObject.Properties['monitor']){return $null}
    return $Lease.monitor
}

function Assert-StackLaunchMonitor {
    param($Monitor,$Lease)
    if($null -eq $Monitor){return}
    foreach($key in @('identity','recyclerIdentity','recycleId','helperLaunchId','generationId')){
        if($null -eq $Monitor.PSObject.Properties[$key]){throw 'Recovery monitor schema is invalid.'}
    }
    Assert-StackLaunchStoredIdentity $Monitor.identity
    Assert-StackLaunchStoredIdentity $Monitor.recyclerIdentity
    [void](ConvertTo-StackLaunchRecycleId $Monitor.recycleId)
    [void](ConvertTo-StackLaunchHelperId $Monitor.helperLaunchId)
    [void](ConvertTo-StackLaunchUuid $Monitor.generationId)
    if($Lease.phase -cnotin @('recycling','starting','completed','stopping') -or $Monitor.generationId -cne $Lease.generationId -or -not(Test-StackLaunchIdentityEqual $Monitor.recyclerIdentity $Lease.recycler) -or $Monitor.recycleId -cne $Lease.recycler.recycleId){throw 'Recovery monitor does not match the stored launch operation.'}
    if(Test-StackLaunchIdentityEqual $Monitor.identity $Monitor.recyclerIdentity){throw 'Recovery monitor must be independent of the recycler.'}
}

function Read-StackLaunchLease {
    param([Parameter(Mandatory=$true)]$Scope)
    if (-not (Test-Path -LiteralPath $Scope.LeasePath)) { return $null }
    $stream=$null
    try{
        $stream=[IO.FileStream]::new($Scope.LeasePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $bytes=New-Object byte[] 32769;$count=0
        while($count -lt $bytes.Length){$read=$stream.Read($bytes,$count,$bytes.Length-$count);if($read -eq 0){break};$count+=$read}
        if($count -gt 32768){throw 'Stack launch lease is oversized.'}
        $jsonText=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$count)
    }finally{if($null -ne $stream){$stream.Dispose()}}
    $jsonOptions=@{InputObject=$jsonText;ErrorAction='Stop'}
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$jsonOptions.DateKind='String'}
    $lease=ConvertFrom-Json @jsonOptions
    foreach ($key in @('schemaVersion','generationId','repoRoot','phase','owner','activeNode','completedNode','recycler','replacementGrant','replacementEntry','handoffGrant','handoffTargetRoot','handoffEntry')) {
        if ($null -eq $lease -or $null -eq $lease.PSObject.Properties[$key]) { throw 'Stack launch lease schema is invalid.' }
    }
    if ([int]$lease.schemaVersion -ne 1 -or $lease.phase -cnotin @('starting','completed','recycling','handoff','stopping')) { throw 'Stack launch lease schema is invalid.' }
    [void](ConvertTo-StackLaunchUuid $lease.generationId)
    [void](Get-StackLaunchCanonicalPath $lease.repoRoot -AllowMissing)
    foreach ($identity in @($lease.owner,$lease.activeNode,$lease.completedNode,$lease.recycler,$lease.replacementEntry,$lease.handoffEntry)) { Assert-StackLaunchStoredIdentity $identity -AllowNull }
    foreach ($grant in @($lease.replacementGrant,$lease.handoffGrant)) { [void](ConvertTo-StackLaunchUuid $grant -AllowEmpty) }
    if ($null -ne $lease.recycler) { [void](ConvertTo-StackLaunchRecycleId ([string]$lease.recycler.recycleId)) }
    if($lease.phase -cin @('starting','completed','handoff')){
        if($null -eq $lease.owner -or $lease.owner.name -ine 'cmd.exe' -or -not(Test-StackLaunchCmdExecutable $lease.owner.executablePath) -or $null -eq $lease.owner.PSObject.Properties['entryPath'] -or $lease.owner.entryPath -ine (Join-Path $lease.repoRoot 'platform_scripts\cmd\start_streamer_stack.bat')){throw 'Launch owner does not match the stored exact root.'}
    }
    if($lease.phase -ceq 'completed' -and $null -eq $lease.completedNode){throw 'Completed launch requires a pinned Node.'}
    foreach($nodePin in @($lease.activeNode,$lease.completedNode)){
        if($null -ne $nodePin -and ($nodePin.name -ine 'node.exe' -or $nodePin.executablePath -ine (Join-Path $lease.repoRoot 'platform_scripts\cmd\node\node.exe'))){throw 'Pinned Node does not match the stored exact root.'}
    }
    if($lease.phase -ceq 'completed' -and ($null -eq $lease.activeNode -or -not(Test-StackLaunchIdentityEqual $lease.activeNode $lease.completedNode))){throw 'Completed Node must match the observed active Node pin.'}
    if($lease.phase -ceq 'recycling' -and $null -eq $lease.recycler){throw 'Recycling launch requires an exact helper identity.'}
    if($lease.phase -ceq 'handoff' -and ($lease.handoffGrant -cne $lease.generationId -or [string]::IsNullOrWhiteSpace($lease.handoffTargetRoot))){throw 'Handoff requires an exact target grant.'}
    [void](Get-StackLaunchHandoffMode $lease)
    $monitor=Get-StackLaunchLeaseMonitor $lease
    Assert-StackLaunchMonitor $monitor $lease
    if($lease.phase -ceq 'stopping' -and $null -eq $monitor){throw 'Stopping launch requires an exact monitor ownership record.'}
    return $lease
}

function Write-StackLaunchLease {
    param([Parameter(Mandatory=$true)]$Scope, [Parameter(Mandatory=$true)]$Lease, [Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $directory=Split-Path -Parent $Scope.LeasePath
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop) }
    $temp=$Scope.LeasePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'; $backup=$temp+'.bak'; $stream=$null
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes(($Lease|ConvertTo-Json -Depth 8 -Compress))
        if ($bytes.Length -gt 32768) { throw 'Stack launch lease is oversized.' }
        $stream=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream=$null
        if (Test-Path -LiteralPath $Scope.LeasePath) { [IO.File]::Replace($temp,$Scope.LeasePath,$backup) }
        else { [IO.File]::Move($temp,$Scope.LeasePath) }
        $check=Read-StackLaunchLease $Scope
        if (($check|ConvertTo-Json -Depth 8 -Compress) -cne ($Lease|ConvertTo-Json -Depth 8 -Compress)) { throw 'Stack launch lease durable read-back failed.' }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function New-StackLaunchLease {
    param($Scope, $OwnerIdentity, [string]$GenerationId)
    return [pscustomobject]@{schemaVersion=1; generationId=$GenerationId; repoRoot=$Scope.RepoRoot; phase='starting'; owner=$OwnerIdentity; activeNode=$null; completedNode=$null; recycler=$null; replacementGrant=''; replacementEntry=$null; handoffGrant=''; handoffTargetRoot=''; handoffEntry=$null; handoffMode='normal'; monitor=$null}
}

function Test-StackLaunchEntryNodeOwnership {
    param([Parameter(Mandatory=$true)]$Scope,[object[]]$AllowedNodePins=@())
    # Run under the entry caller's lifecycle lock before any durable write or
    # BAT side effect. Do not trust-migrate an unregistered portable Node.
    foreach($node in @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop)){
        if($node.Name -ine 'node.exe'){continue}
        if([string]::IsNullOrWhiteSpace([string]$node.ExecutablePath)){throw 'Cannot safely classify a live Node at stack entry.'}
        if((Get-StackLaunchCanonicalPath ([string]$node.ExecutablePath)) -ine $Scope.NodePath){continue}
        [void](Get-StackLaunchProcessIdentity -ProcessId ([int]$node.ProcessId) -Process $node)
        $matched=$false
        foreach($pin in $AllowedNodePins){
            if($null -ne $pin -and $pin.executablePath -ieq $Scope.NodePath -and (Test-StackLaunchProcessIdentity -Identity $pin -Process $node)){$matched=$true;break}
        }
        if(-not $matched){return $false}
    }
    return $true
}

function Enter-StackLaunchAttempt {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)]$OwnerIdentity,[ValidateSet('normal','recovery','validation')][string]$Mode='normal',[string]$InheritedGeneration='', [string]$Grant='',[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $Mode=$Mode.ToLowerInvariant()
    if (-not (Test-StackLaunchProcessIdentity $OwnerIdentity) -or $OwnerIdentity.name -ine 'cmd.exe' -or -not(Test-StackLaunchCmdExecutable $OwnerIdentity.executablePath) -or $OwnerIdentity.entryPath -ine $Scope.EntryPath) { throw 'Full-stack owner identity is invalid.' }
    $inherited=ConvertTo-StackLaunchUuid $InheritedGeneration -AllowEmpty; $grantId=ConvertTo-StackLaunchUuid $Grant -AllowEmpty
    $lease=Read-StackLaunchLease $Scope
    if ($grantId) {
        if ($null -eq $lease) { throw 'No reserved launch grant exists.' }
        $replacement=$lease.phase -ceq 'recycling' -and $grantId -ceq $lease.replacementGrant -and $Mode -ceq 'recovery' -and $lease.repoRoot -ieq $Scope.RepoRoot
        $handoff=$lease.phase -ceq 'handoff' -and $grantId -ceq $lease.handoffGrant -and $lease.handoffTargetRoot -ieq $Scope.RepoRoot -and $Mode -ceq (Get-StackLaunchHandoffMode $lease)
        $reserved=if($replacement){$lease.replacementEntry}elseif($handoff){$lease.handoffEntry}else{$null}
        if ($null -eq $reserved -or $reserved.pid -ne $OwnerIdentity.pid -or $reserved.creationUtc -cne $OwnerIdentity.creationUtc -or -not (Test-StackLaunchProcessIdentity $reserved)) { throw 'Reserved launch grant does not match this exact CMD.' }
        if(-not(Test-StackLaunchEntryNodeOwnership -Scope $Scope)){return [pscustomobject]@{Decision='Skip';GenerationId=$lease.generationId;Reason='NodeUnclassified';Lease=$lease}}
        $next=New-StackLaunchLease $Scope $OwnerIdentity $grantId
        if ($replacement) {
            $next.recycler=$lease.recycler;$next.monitor=Get-StackLaunchLeaseMonitor $lease
            if ($null -ne $lease.PSObject.Properties['recoveryPreparation']) {
                $next | Add-Member -NotePropertyName recoveryPreparation -NotePropertyValue $lease.recoveryPreparation
            }
        }
        Write-StackLaunchLease $Scope $next $LockHandle
        return [pscustomobject]@{Decision='Enter';GenerationId=$next.generationId;Lease=$next}
    }
    if ($null -ne $lease) {
        if ($inherited -and $inherited -cne $lease.generationId) { return [pscustomobject]@{Decision='Skip';GenerationId=$inherited;Lease=$lease} }
        $monitor=Get-StackLaunchLeaseMonitor $lease
        $busy=(Test-StackLaunchProcessIdentity $lease.owner) -or (Test-StackLaunchProcessIdentity $lease.recycler) -or (Test-StackLaunchProcessIdentity $lease.replacementEntry) -or (Test-StackLaunchProcessIdentity $lease.handoffEntry) -or ($null -ne $monitor -and (Test-StackLaunchProcessIdentity $monitor.identity))
        $completed=$Mode -ceq 'normal' -and $lease.phase -ceq 'completed' -and (Test-StackLaunchProcessIdentity $lease.completedNode)
        if ($busy -or $completed) { return [pscustomobject]@{Decision='Skip';GenerationId=$lease.generationId;Lease=$lease} }
        if($lease.phase -ceq 'stopping'){
            # Shutdown acceptance is asynchronous. A dead monitor must not
            # reopen this boot after a failed/partially executed OS stop.
            if($Mode -cne 'normal' -or (Test-StackLaunchProcessIdentity $lease.activeNode) -or (Test-StackLaunchProcessIdentity $lease.completedNode)){return [pscustomobject]@{Decision='Skip';GenerationId=$lease.generationId;Lease=$lease}}
            $boot=[DateTimeOffset]::Parse((Get-StackLaunchOsBootUtc),[Globalization.CultureInfo]::InvariantCulture)
            $monitorBirth=[DateTimeOffset]::Parse([string]$monitor.identity.creationUtc,[Globalization.CultureInfo]::InvariantCulture)
            if($boot -le $monitorBirth){return [pscustomobject]@{Decision='Skip';GenerationId=$lease.generationId;Lease=$lease}}
        }
    } elseif ($inherited) { throw 'Inherited launch generation has no registry.' }
    $next=New-StackLaunchLease $Scope $OwnerIdentity ([Guid]::NewGuid().ToString('D'))
    if($null -ne $lease -and $lease.repoRoot -ieq $Scope.RepoRoot){
        if(Test-StackLaunchProcessIdentity $lease.activeNode){$next.activeNode=$lease.activeNode}
        if(Test-StackLaunchProcessIdentity $lease.completedNode){$next.completedNode=$lease.completedNode;$next.activeNode=$lease.completedNode}
        # The retained Node's environment is immutable. Ownership transfer for
        # a component repair remains in that same attempt so its dispatch-time
        # generation and process birth still match the lease.
        if($null -ne $next.activeNode){$next.generationId=$lease.generationId}
    }
    $allowedPins=if($null -ne $lease -and $lease.repoRoot -ieq $Scope.RepoRoot -and $next.generationId -ceq $lease.generationId){@($next.activeNode,$next.completedNode)}else{@()}
    if(-not(Test-StackLaunchEntryNodeOwnership -Scope $Scope -AllowedNodePins $allowedPins)){
        $currentGeneration=if($null -ne $lease){$lease.generationId}else{''}
        return [pscustomobject]@{Decision='Skip';GenerationId=$currentGeneration;Reason='NodeUnclassified';Lease=$lease}
    }
    Write-StackLaunchLease $Scope $next $LockHandle
    return [pscustomobject]@{Decision='Enter';GenerationId=$next.generationId;Lease=$next}
}

function Get-StackLaunchNodeIdentity {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)]$OwnerIdentity)
    $lease=Read-StackLaunchLease $Scope
    $snapshot=@(Get-CimInstance Win32_Process -ErrorAction Stop); $byPid=@{}
    foreach($item in $snapshot){$byPid[[int]$item.ProcessId]=$item}
    $matches=@(foreach($item in $snapshot){
        if($item.Name -ine 'node.exe' -or [string]::IsNullOrWhiteSpace([string]$item.ExecutablePath)){continue}
        $identity=Get-StackLaunchProcessIdentity -ProcessId ([int]$item.ProcessId) -Process $item
        if($identity.executablePath -ine $Scope.NodePath){continue}
        if(-not(Test-StackLaunchNodeInvocation -CommandLine ([string]$item.CommandLine) -RepoRoot $Scope.RepoRoot)){continue}
        $cursor=$item; $seen=@{}; $owned=$false
        if($null -ne $lease -and $lease.repoRoot -ieq $Scope.RepoRoot){
            foreach($pin in @($lease.activeNode,$lease.completedNode)){
                if($null -ne $pin -and $pin.pid -eq $identity.pid -and (Test-StackLaunchProcessIdentity -Identity $pin -Process $item)){$owned=$true;break}
            }
        }
        for($depth=0;$depth -lt 16;$depth++){
            if($owned){break}
            $parentId=[int]$cursor.ParentProcessId
            if($seen.ContainsKey($parentId) -or -not $byPid.ContainsKey($parentId)){break}
            $seen[$parentId]=$true; $parent=$byPid[$parentId]
            if([DateTimeOffset]::Parse((Get-StackLaunchCreationUtc $parent)) -gt [DateTimeOffset]::Parse((Get-StackLaunchCreationUtc $cursor))){break}
            if($parentId -eq $OwnerIdentity.pid){$owned=Test-StackLaunchProcessIdentity -Identity $OwnerIdentity -Process $parent;break}
            if($parent.Name -ieq 'cmd.exe' -and (Test-StackLaunchCmdInvocation -CommandLine ([string]$parent.CommandLine) -EntryPath (Join-Path $Scope.RepoRoot 'platform_scripts\cmd\start_dev_turn.bat'))){$owned=$true;break}
            $cursor=$parent
        }
        if($owned){$identity|Add-Member -NotePropertyName repoRoot -NotePropertyValue $Scope.RepoRoot;$identity}
    })
    if($matches.Count -ne 1){throw 'Successful launch requires one exact owned Node identity.'}
    return $matches[0]
}

function Test-StackLaunchNodeInvocation {
    param([string]$CommandLine,[string]$RepoRoot)
    if($CommandLine -notmatch '^\s*(?:"[^"]+"|\S+)\s+(?:"(?<script>[^"]+)"|(?<script>\S+))(?:\s|$)'){return $false}
    $scriptArgument=$Matches.script.Replace('/','\')
    if($scriptArgument -cin @('.\dist\index.js','dist\index.js')){return $true}
    try{return (Get-StackLaunchCanonicalPath $scriptArgument) -ieq (Join-Path $RepoRoot 'dist\index.js')}
    catch{return $false}
}

function Test-StackLaunchIdentityEqual {
    param($Left,$Right)
    if($null -eq $Left -or $null -eq $Right){return $false}
    return [int]$Left.pid -eq [int]$Right.pid -and [string]$Left.creationUtc -ceq [string]$Right.creationUtc -and [string]$Left.executablePath -ieq [string]$Right.executablePath -and [string]$Left.name -ieq [string]$Right.name
}

function Register-StackLaunchNode {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$GenerationId,[Parameter(Mandatory=$true)]$NodeIdentity,[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $lease=Read-StackLaunchLease $Scope;$generation=ConvertTo-StackLaunchUuid $GenerationId
    if($null -eq $lease -or $lease.phase -cnotin @('starting','completed') -or $lease.repoRoot -ine $Scope.RepoRoot -or $lease.generationId -cne $generation){throw 'Cannot register Node for a revoked or inactive launch.'}
    Assert-StackLaunchStoredIdentity $NodeIdentity
    $process=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$NodeIdentity.pid) -ErrorAction Stop|Select-Object -First 1
    if($NodeIdentity.name -ine 'node.exe' -or $NodeIdentity.executablePath -ine $Scope.NodePath -or $null -eq $process -or -not(Test-StackLaunchProcessIdentity -Identity $NodeIdentity -Process $process) -or -not(Test-StackLaunchNodeInvocation -CommandLine ([string]$process.CommandLine) -RepoRoot $Scope.RepoRoot)){throw 'Observed Node is not the exact live Wilbur entry process.'}
    if($null -ne $lease.activeNode -and -not(Test-StackLaunchIdentityEqual $lease.activeNode $NodeIdentity) -and (Test-StackLaunchProcessIdentity $lease.activeNode)){throw 'A different live Node is already pinned to this launch.'}
    if($lease.phase -ceq 'completed' -and -not(Test-StackLaunchIdentityEqual $lease.completedNode $NodeIdentity)){
        if((Test-StackLaunchProcessIdentity $lease.activeNode) -or (Test-StackLaunchProcessIdentity $lease.completedNode)){throw 'A live completed Node pin cannot be replaced.'}
        # A Wilbur-only repair may keep the completed stack generation. Both
        # old pins must be dead; readiness is still established by runtime
        # health and the normal admission/recovery authorities.
        $lease.completedNode=$NodeIdentity
    }
    $lease.activeNode=$NodeIdentity
    Write-StackLaunchLease $Scope $lease $LockHandle
    return $lease
}

function Complete-StackLaunchAttempt {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$GenerationId,[Parameter(Mandatory=$true)]$OwnerIdentity,[Parameter(Mandatory=$true)]$NodeIdentity,[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $lease=Read-StackLaunchLease $Scope; $generation=ConvertTo-StackLaunchUuid $GenerationId
    if($null -eq $lease -or $lease.phase -cne 'starting' -or $lease.repoRoot -ine $Scope.RepoRoot -or $lease.generationId -cne $generation -or $lease.owner.pid -ne $OwnerIdentity.pid -or $lease.owner.creationUtc -cne $OwnerIdentity.creationUtc -or -not (Test-StackLaunchProcessIdentity $OwnerIdentity)){throw 'Cannot complete a revoked or unowned launch.'}
    if($NodeIdentity.name -ine 'node.exe' -or $NodeIdentity.executablePath -ine $Scope.NodePath -or -not (Test-StackLaunchProcessIdentity $NodeIdentity) -or -not(Test-StackLaunchIdentityEqual $lease.activeNode $NodeIdentity)){throw 'Completed Node must be the identical live process observed at launch.'}
    $lease.phase='completed';$lease.completedNode=$NodeIdentity
    Write-StackLaunchLease $Scope $lease $LockHandle
    return $lease
}

function Begin-StackLaunchRecycle {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$RecycleId,[Parameter(Mandatory=$true)]$RecyclerIdentity,[string]$PlannedGenerationId='', $MonitorIdentity=$null,[string]$HelperLaunchId='',[Parameter(Mandatory=$true)]$LockHandle,$PreparationReceipt=$null)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    if(-not(Test-StackLaunchProcessIdentity $RecyclerIdentity)){throw 'Recycler identity is not live.'}
    $operation=ConvertTo-StackLaunchRecycleId $RecycleId; $previous=Read-StackLaunchLease $Scope
    if($null -ne $previous -and $previous.phase -ceq 'stopping'){throw 'A terminal stopping fence cannot be recycled in this OS boot.'}
    if($null -ne $previous -and $null -ne $previous.recycler -and (Test-StackLaunchProcessIdentity $previous.recycler) -and ($previous.recycler.pid -ne $RecyclerIdentity.pid -or $previous.recycler.creationUtc -cne $RecyclerIdentity.creationUtc)){throw 'Another live recycler owns the launch lease.'}
    $previousMonitor=Get-StackLaunchLeaseMonitor $previous
    if($null -ne $previousMonitor -and (Test-StackLaunchProcessIdentity $previousMonitor.identity)){throw 'A live recovery monitor still owns the launch attempt.'}
    # The omitted tuple remains compatible with old local fixtures. The
    # production caller requires a successfully armed independent monitor.
    $monitored=$null -ne $MonitorIdentity -or -not[string]::IsNullOrWhiteSpace($PlannedGenerationId) -or -not[string]::IsNullOrWhiteSpace($HelperLaunchId)
    $grant=if($monitored){ConvertTo-StackLaunchUuid $PlannedGenerationId}else{[Guid]::NewGuid().ToString('D')}
    if($null -ne $previous -and $grant -ceq $previous.generationId){throw 'Recycle must revoke the previous launch generation.'}
    $dispatch=''
    if($monitored){
        $dispatch=ConvertTo-StackLaunchHelperId $HelperLaunchId
        Assert-StackLaunchStoredIdentity $MonitorIdentity
        if(-not(Test-StackLaunchProcessIdentity $MonitorIdentity) -or (Test-StackLaunchIdentityEqual $MonitorIdentity $RecyclerIdentity)){throw 'An exact live independent recovery monitor is required.'}
    }
    $next=New-StackLaunchLease $Scope $null $grant
    $next.phase='recycling';$next.recycler=$RecyclerIdentity | Select-Object *
    $next.recycler|Add-Member -NotePropertyName recycleId -NotePropertyValue $operation -Force
    if($monitored){$next.monitor=[pscustomobject]@{identity=($MonitorIdentity|Select-Object *);recyclerIdentity=($RecyclerIdentity|Select-Object *);recycleId=$operation;helperLaunchId=$dispatch;generationId=$grant}}
    if($monitored -and $null -ne $PreparationReceipt){
        $next | Add-Member -NotePropertyName recoveryPreparation -NotePropertyValue ([pscustomobject]@{
            generationId=$grant;recycleId=$operation;helperLaunchId=$dispatch;receipt=$PreparationReceipt
        })
    }
    Write-StackLaunchLease $Scope $next $LockHandle
    return [pscustomobject]@{PreviousLease=$previous;Grant=$grant;Lease=$next}
}

function Set-StackLaunchReplacementEntry {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$Grant,[Parameter(Mandatory=$true)]$EntryIdentity,[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $lease=Read-StackLaunchLease $Scope;$grantId=ConvertTo-StackLaunchUuid $Grant
    if($null -eq $lease -or $lease.phase -cne 'recycling' -or $lease.generationId -cne $grantId -or -not(Test-StackLaunchProcessIdentity $lease.recycler) -or -not(Test-StackLaunchProcessIdentity $EntryIdentity)){throw 'Replacement reservation is invalid.'}
    if($EntryIdentity.name -ine 'cmd.exe' -or -not(Test-StackLaunchCmdExecutable $EntryIdentity.executablePath) -or $EntryIdentity.entryPath -ine $Scope.EntryPath){throw 'Replacement CMD is outside the exact launch root.'}
    $lease.replacementGrant=$grantId;$lease.replacementEntry=$EntryIdentity
    Write-StackLaunchLease $Scope $lease $LockHandle
    return $lease
}

function Begin-StackLaunchHandoff {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$GenerationId,[Parameter(Mandatory=$true)]$OwnerIdentity,[Parameter(Mandatory=$true)][string]$TargetRepoRoot,[ValidateSet('normal','validation')][string]$LaunchMode='normal',[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $lease=Read-StackLaunchLease $Scope;$generation=ConvertTo-StackLaunchUuid $GenerationId
    if($null -eq $lease -or $lease.phase -cne 'starting' -or $lease.generationId -cne $generation -or $lease.owner.pid -ne $OwnerIdentity.pid -or $lease.owner.creationUtc -cne $OwnerIdentity.creationUtc -or -not(Test-StackLaunchProcessIdentity $OwnerIdentity) -or (Test-StackLaunchProcessIdentity $lease.recycler)){throw 'Launch handoff is not owned by this caller.'}
    $monitor=Get-StackLaunchLeaseMonitor $lease
    if($null -ne $monitor -and (Test-StackLaunchProcessIdentity $monitor.identity)){throw 'A live monitored recovery cannot transfer to a Git handoff.'}
    if($null -ne $lease.PSObject.Properties['monitor']){$lease.monitor=$null}
    $grant=[Guid]::NewGuid().ToString('D');$lease.phase='handoff';$lease.generationId=$grant;$lease.activeNode=$null;$lease.completedNode=$null;$lease.handoffGrant=$grant;$lease.handoffTargetRoot=Get-StackLaunchCanonicalPath $TargetRepoRoot
    if($null -eq $lease.PSObject.Properties['handoffMode']){$lease|Add-Member -NotePropertyName handoffMode -NotePropertyValue $LaunchMode.ToLowerInvariant()}else{$lease.handoffMode=$LaunchMode.ToLowerInvariant()}
    Write-StackLaunchLease $Scope $lease $LockHandle
    return [pscustomobject]@{Grant=$grant;Lease=$lease}
}

function Set-StackLaunchHandoffEntry {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$Grant,[Parameter(Mandatory=$true)]$EntryIdentity,[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $lease=Read-StackLaunchLease $Scope;$grantId=ConvertTo-StackLaunchUuid $Grant
    if($null -eq $lease){throw 'Handoff entry reservation is missing.'}
    $targetEntry=Join-Path $lease.handoffTargetRoot 'platform_scripts\cmd\start_streamer_stack.bat'
    if($lease.phase -cne 'handoff' -or $lease.handoffGrant -cne $grantId -or -not(Test-StackLaunchProcessIdentity $EntryIdentity) -or $EntryIdentity.name -ine 'cmd.exe' -or -not(Test-StackLaunchCmdExecutable $EntryIdentity.executablePath) -or $EntryIdentity.entryPath -ine $targetEntry){throw 'Handoff entry reservation is invalid.'}
    $lease.handoffEntry=$EntryIdentity
    Write-StackLaunchLease $Scope $lease $LockHandle
    return $lease
}

function Get-StackLaunchMonitorOwnership {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$GenerationId,[Parameter(Mandatory=$true)][string]$RecycleId,[Parameter(Mandatory=$true)][string]$HelperLaunchId,[Parameter(Mandatory=$true)]$MonitorIdentity,[Parameter(Mandatory=$true)]$RecyclerIdentity,[Parameter(Mandatory=$true)]$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $generation=ConvertTo-StackLaunchUuid $GenerationId
    $operation=ConvertTo-StackLaunchRecycleId $RecycleId
    $dispatch=ConvertTo-StackLaunchHelperId $HelperLaunchId
    Assert-StackLaunchStoredIdentity $MonitorIdentity
    Assert-StackLaunchStoredIdentity $RecyclerIdentity
    $lease=Read-StackLaunchLease $Scope;$monitor=Get-StackLaunchLeaseMonitor $lease
    if($null -eq $lease -or $null -eq $monitor -or $lease.repoRoot -ine $Scope.RepoRoot -or $lease.generationId -cne $generation -or $monitor.generationId -cne $generation -or $monitor.recycleId -cne $operation -or $monitor.helperLaunchId -cne $dispatch -or -not(Test-StackLaunchIdentityEqual $monitor.identity $MonitorIdentity) -or -not(Test-StackLaunchIdentityEqual $monitor.recyclerIdentity $RecyclerIdentity) -or -not(Test-StackLaunchIdentityEqual $lease.recycler $RecyclerIdentity) -or -not(Test-StackLaunchProcessIdentity $MonitorIdentity)){
        return [pscustomobject]@{Disposition='Superseded';Lease=$lease}
    }
    # Current Node existence is a narrow handoff to the existing agent. It is
    # never evidence of Ready, completed reset, admission or usable media.
    foreach($pin in @($lease.activeNode,$lease.completedNode)){
        if(Test-StackLaunchProcessIdentity $pin){return [pscustomobject]@{Disposition='NodeAlive';Lease=$lease}}
    }
    # A wrapper killed between native birth and registration can leave an
    # unpinned Node. Any same portable executable conservatively denies stop,
    # even when argv cannot prove Wilbur. Discovery failures also deny stop.
    $nodes=@(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop)
    foreach($node in $nodes){
        if($node.Name -ine 'node.exe'){continue}
        if([string]::IsNullOrWhiteSpace([string]$node.ExecutablePath)){throw 'Cannot safely classify a live Node executable.'}
        $path=Get-StackLaunchCanonicalPath ([string]$node.ExecutablePath)
        if($path -ieq $Scope.NodePath){
            [void](Get-StackLaunchProcessIdentity -ProcessId ([int]$node.ProcessId) -Process $node)
            return [pscustomobject]@{Disposition='NodeUnclassified';Lease=$lease}
        }
    }
    $disposition=if($lease.phase -ceq 'stopping'){'Stopping'}else{'Current'}
    return [pscustomobject]@{Disposition=$disposition;Lease=$lease}
}

function Set-StackLaunchStopping {
    param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)][string]$GenerationId,[Parameter(Mandatory=$true)][string]$RecycleId,[Parameter(Mandatory=$true)][string]$HelperLaunchId,[Parameter(Mandatory=$true)]$MonitorIdentity,[Parameter(Mandatory=$true)]$RecyclerIdentity,[Parameter(Mandatory=$true)]$LockHandle)
    # The monitor must revalidate its immutable marker immediately before this
    # call. This second lease/Node check occurs under the same spawn mutex.
    $status=Get-StackLaunchMonitorOwnership @PSBoundParameters
    if($status.Disposition -cne 'Current'){return $status}
    $status.Lease.phase='stopping'
    Write-StackLaunchLease -Scope $Scope -Lease $status.Lease -LockHandle $LockHandle
    return [pscustomobject]@{Disposition='Stopping';Lease=$status.Lease}
}

function Enter-StackLaunchGate {
    param([Parameter(Mandatory=$true)][string]$RepoRoot,[string]$InstallBase='C:\PixelStreaming',[string]$GenerationId='', [ValidateRange(0,120)][int]$TimeoutSeconds=15)
    $scope=Get-StackLaunchLeaseScope $RepoRoot $InstallBase;$handle=Enter-StackLaunchLeaseLock $scope $TimeoutSeconds
    try{
        $lease=Read-StackLaunchLease $scope;$generation=ConvertTo-StackLaunchUuid $GenerationId -AllowEmpty
        if($generation){
            if($null -eq $lease -or $lease.generationId -cne $generation -or $lease.repoRoot -ine $scope.RepoRoot -or $lease.phase -cnotin @('starting','completed')){throw 'Launch generation was revoked or is not active.'}
        }elseif($null -ne $lease -and ($lease.phase -ceq 'stopping' -or (Test-StackLaunchProcessIdentity $lease.owner) -or (Test-StackLaunchProcessIdentity $lease.recycler) -or (($null -ne (Get-StackLaunchLeaseMonitor $lease)) -and (Test-StackLaunchProcessIdentity (Get-StackLaunchLeaseMonitor $lease).identity)) -or (($lease.phase -cin @('recycling','handoff')) -and ((Test-StackLaunchProcessIdentity $lease.replacementEntry) -or (Test-StackLaunchProcessIdentity $lease.handoffEntry))))){
            throw 'Standalone component launch is blocked by live lifecycle work.'
        }
        $handle|Add-Member -NotePropertyName Scope -NotePropertyValue $scope
        return $handle
    }catch{Exit-StackLaunchLeaseLock $handle;throw}
}

function Exit-StackLaunchGate { param([Parameter(Mandatory=$true)]$Handle) Exit-StackLaunchLeaseLock $Handle }
