# Start a single reserved CMD while the caller still owns the lifecycle mutex.
# Pass the grant through the child environment, never a CMD SET/shell chain.
function Start-StackLaunchReservedEntry {
    param($Scope, [string]$Grant, [ValidateSet('recovery','handoff')][string]$Kind, $LockHandle, [hashtable]$EnvironmentOverrides = @{}, [string]$TargetRepoRoot = '', [ValidateSet('normal','validation')][string]$LaunchMode='normal')
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    $Kind=$Kind.ToLowerInvariant();$LaunchMode=$LaunchMode.ToLowerInvariant()
    $grantId = ConvertTo-StackLaunchUuid $Grant
    if($Kind -ceq 'recovery' -and $LaunchMode -cne 'normal'){throw 'Recovery entry cannot use a maintenance launch mode.'}
    if($Kind -ceq 'handoff'){
        $lease=Read-StackLaunchLease $Scope
        if($null -eq $lease -or $lease.phase -cne 'handoff' -or $lease.handoffGrant -cne $grantId -or (Get-StackLaunchHandoffMode $lease) -cne $LaunchMode){throw 'Reserved handoff launch mode does not match the lease.'}
    }
    $root = if ($TargetRepoRoot) { Get-StackLaunchCanonicalPath $TargetRepoRoot } else { $Scope.RepoRoot }
    $launcher = Join-Path $root 'platform_scripts\cmd\start_streamer_stack.bat'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Reserved full-stack launcher is missing.' }
    $suffix = if ($Kind -ceq 'recovery') { ' --recovery' } elseif($LaunchMode -ceq 'validation') { ' --validation' } else { '' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c ""{0}"{1}"' -f $launcher, $suffix
    $info.WorkingDirectory = Split-Path -Parent $launcher
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['SCALEWORLD_STACK_LAUNCH_GRANT'] = $grantId
    foreach ($key in $EnvironmentOverrides.Keys) { $info.EnvironmentVariables[[string]$key] = [string]$EnvironmentOverrides[$key] }
    $child = $null
    try {
        $child = [Diagnostics.Process]::Start($info)
        $null = $child.Handle
        $identity = Get-StackLaunchProcessIdentity -ProcessId $child.Id
        if ($null -eq $identity) { throw 'Reserved launcher exited before its identity could be pinned.' }
        $observedBirth = [DateTimeOffset]::Parse([string]$identity.creationUtc).UtcDateTime
        if ($child.HasExited -or
            [Math]::Floor([decimal]$child.StartTime.ToUniversalTime().Ticks / 10) -ne [Math]::Floor([decimal]$observedBirth.Ticks / 10) -or
            (Get-StackLaunchCanonicalPath $child.MainModule.FileName) -ine $identity.executablePath) {
            throw 'Reserved launcher observation does not match the retained child process handle.'
        }
        $identity | Add-Member -NotePropertyName entryPath -NotePropertyValue $launcher
        $identity | Add-Member -NotePropertyName invocationPath -NotePropertyValue $launcher
        if ($Kind -ceq 'recovery') {
            [void](Set-StackLaunchReplacementEntry -Scope $Scope -Grant $grantId -EntryIdentity $identity -LockHandle $LockHandle)
        } else {
            [void](Set-StackLaunchHandoffEntry -Scope $Scope -Grant $grantId -EntryIdentity $identity -LockHandle $LockHandle)
        }
        return $identity
    } catch {
        if ($null -ne $child -and -not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
        throw
    } finally { if ($null -ne $child) { $child.Dispose() } }
}
