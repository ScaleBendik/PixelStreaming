# Process cancellation for a lease-owned launch attempt. Never terminate a tree:
# the detached recycle helper can be descended from the producer being cancelled.
. (Join-Path $PSScriptRoot 'scaleworld_process_helpers.ps1')

function Get-StackLaunchCancellationIdentity {
    param([Parameter(Mandatory = $true)][object]$Process)
    $birth = Get-ScaleWorldProcessCreationUtcDateTime -Process $Process
    if ($null -eq $birth -or [string]::IsNullOrWhiteSpace([string]$Process.ExecutablePath)) {
        throw "Process $($Process.ProcessId) has no verifiable creation/executable identity."
    }
    [pscustomobject]@{ pid = [int]$Process.ProcessId; creationUtc = $birth.ToString('o'); executablePath = (Get-StackLaunchCanonicalPath ([string]$Process.ExecutablePath)) }
}

function Stop-StackLaunchProcessIdentity {
    param([Parameter(Mandatory = $true)][object]$Identity, [int]$TimeoutMilliseconds = 5000)
    $process = $null
    try {
        try { $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid) }
        catch [ArgumentException] { return }
        # Open and retain the process handle before comparing birth. Kill uses
        # that same handle on .NET Framework, rather than reopening a reused PID.
        $null = $process.Handle
        if ($process.HasExited) { return }
        $expected = [DateTimeOffset]::Parse([string]$Identity.creationUtc).UtcDateTime
        # Win32_Process CreationDate has microsecond precision; native FILETIME
        # may have a remaining fraction of a microsecond.
        if ([Math]::Floor([decimal]$process.StartTime.ToUniversalTime().Ticks / 10) -ne [Math]::Floor([decimal]$expected.Ticks / 10) -or
            -not [string]::Equals((Get-StackLaunchCanonicalPath $process.MainModule.FileName), (Get-StackLaunchCanonicalPath ([string]$Identity.executablePath)), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to terminate PID $($Identity.pid): its process identity changed."
        }
        $process.Kill()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw "Producer PID $($Identity.pid) did not terminate." }
    } catch {
        if ($null -ne $process -and $process.HasExited) { return }
        throw
    } finally { if ($null -ne $process) { $process.Dispose() } }
}

function Test-StackLaunchScriptInvocation {
    param([object]$Process, [string]$ScriptPath)
    $line = [string]$Process.CommandLine
    if ($Process.Name -ieq 'powershell.exe') {
        # Only the executed -File argument counts. A mention inside -Command
        # or another script's arguments is not authority to terminate a process.
        $pattern = '(?i)^\s*(?:"[^"]+"|\S+)\s+(?:(?:-NoProfile|-NonInteractive|-NoLogo)\s+|-ExecutionPolicy\s+\S+\s+|-WindowStyle\s+\S+\s+)*-File\s+(?:"(?<script>[^"]+)"|(?<script>[^\s"]+))(?:\s|$)'
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) { return $false }
        try { return (Get-StackLaunchCanonicalPath $match.Groups['script'].Value) -ieq (Get-StackLaunchCanonicalPath $ScriptPath) }
        catch { return $false }
    }
    if ($Process.Name -ieq 'cmd.exe') {
        # Script must be the invoked command, not a quoted mention in echo or
        # another program's arguments. CALL and CMD's extra quote are supported.
        return Test-StackLaunchCmdInvocation -CommandLine $line -EntryPath $ScriptPath
    }
    return $false
}

function Get-StackLaunchProducerSnapshot {
    param([string]$RepoRoot, [object]$OwnerIdentity, [int]$RecyclerPid)
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $byPid = @{}
    foreach ($process in $all) { $byPid[[int]$process.ProcessId] = $process }
    $seeds = [Collections.Generic.List[object]]::new()
    if ($null -ne $OwnerIdentity) {
        $owner = $byPid[[int]$OwnerIdentity.pid]
        if ($null -ne $owner) {
            $actual = Get-StackLaunchCancellationIdentity $owner
            if ([DateTimeOffset]::Parse($actual.creationUtc) -ne [DateTimeOffset]::Parse([string]$OwnerIdentity.creationUtc) -or
                $actual.executablePath -ine [string]$OwnerIdentity.executablePath) {
                throw 'Launch owner identity changed before cancellation.'
            }
            if ($owner.Name -ine 'cmd.exe') { throw 'Launch owner is not the registered CMD producer.' }
            $seeds.Add($owner)
        }
    }
    foreach ($process in $all) {
        foreach ($relative in @(
            'platform_scripts\cmd\start_dev_turn.bat',
            'platform_scripts\cmd\start_wilbur_native.bat',
            'platform_scripts\cmd\start_unreal.bat',
            'platform_scripts\cmd\start_watchdog.bat',
            'platform_scripts\powershell\start_wilbur_leased.ps1',
            'platform_scripts\powershell\initialize_instance_config.ps1',
            'platform_scripts\powershell\runtime-status-heartbeat.ps1',
            'platform_scripts\powershell\publish_runtime_status_tags.ps1',
            'platform_scripts\powershell\ensure_repo_current.ps1',
            'platform_scripts\powershell\start_scaleworld.ps1',
            'platform_scripts\powershell\start_stack_watchdog.ps1',
            'platform_scripts\powershell\watchdog.ps1'
        )) {
            if (Test-StackLaunchScriptInvocation $process (Join-Path $RepoRoot $relative)) { $seeds.Add($process); break }
        }
    }
    $members = @{}
    foreach ($seed in $seeds) { $members[[int]$seed.ProcessId] = $seed }
    # Record ancestry while parents are alive. Reject parent PID reuse by birth.
    do {
        $added = $false
        foreach ($process in $all) {
            if ($members.ContainsKey([int]$process.ProcessId)) { continue }
            $parent = $members[[int]$process.ParentProcessId]
            if ($null -eq $parent) { continue }
            $parentBirth = Get-ScaleWorldProcessCreationUtcDateTime $parent
            $childBirth = Get-ScaleWorldProcessCreationUtcDateTime $process
            if ($null -eq $parentBirth -or $null -eq $childBirth) { throw 'Producer ancestry has no verifiable creation time.' }
            if ($childBirth -lt $parentBirth) { continue }
            $members[[int]$process.ProcessId] = $process
            $added = $true
        }
    } while ($added)
    # Exclude precisely the live recycler branch, including its child queries.
    $recycler = $byPid[$RecyclerPid]
    if ($null -eq $recycler -or $null -eq (Get-ScaleWorldProcessCreationUtcDateTime $recycler)) {
        throw 'The current recycler ancestry cannot be verified.'
    }
    $protected = @{ $RecyclerPid = $recycler }
    do {
        $added = $false
        foreach ($process in $all) {
            if ($protected.ContainsKey([int]$process.ProcessId)) { continue }
            $parent = $protected[[int]$process.ParentProcessId]
            if ($null -eq $parent) { continue }
            $parentBirth = Get-ScaleWorldProcessCreationUtcDateTime $parent
            $childBirth = Get-ScaleWorldProcessCreationUtcDateTime $process
            if ($null -eq $parentBirth -or $null -eq $childBirth) { throw 'Protected recycler ancestry has no verifiable creation time.' }
            if ($childBirth -lt $parentBirth) { continue }
            $protected[[int]$process.ProcessId] = $process
            $added = $true
        }
    } while ($added)
    @($members.Values | Where-Object {
        -not $protected.ContainsKey([int]$_.ProcessId) -and
        ($_.Name -ieq 'cmd.exe' -or $_.Name -ieq 'powershell.exe') -and
        -not (Test-StackLaunchScriptInvocation $_ (Join-Path $RepoRoot 'platform_scripts\powershell\invoke_stack_recycle.ps1')) -and
        -not (Test-StackLaunchScriptInvocation $_ (Join-Path $RepoRoot 'platform_scripts\cmd\start_stack_recycle.bat'))
    } | ForEach-Object { Get-StackLaunchCancellationIdentity $_ })
}

function Stop-StackLaunchProducers {
    param([string]$RepoRoot, [object]$OwnerIdentity, [int]$RecyclerPid, [int]$TimeoutSeconds = 15)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $snapshot = @(Get-StackLaunchProducerSnapshot -RepoRoot $RepoRoot -OwnerIdentity $OwnerIdentity -RecyclerPid $RecyclerPid)
    # Freeze the full-stack producer first. The generation gate is already
    # revoked and locked; remaining gated children cannot produce replacements.
    if ($null -ne $OwnerIdentity) { Stop-StackLaunchProcessIdentity $OwnerIdentity }
    foreach ($identity in $snapshot) { Stop-StackLaunchProcessIdentity $identity }
    do {
        $remaining = @(Get-StackLaunchProducerSnapshot -RepoRoot $RepoRoot -OwnerIdentity $null -RecyclerPid $RecyclerPid)
        if ($remaining.Count -eq 0) { return }
        foreach ($identity in $remaining) { Stop-StackLaunchProcessIdentity $identity }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Old launch producers did not become quiescent before replacement.'
}
