# Dot-source only. This monitor is a bounded orphan fail-stop, not readiness,
# admission, command completion, or a general replacement health supervisor.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
. (Join-Path $PSScriptRoot 'recycle_intent_guard.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_processes.ps1')

function Read-StackRecycleMonitorJson {
    param([string]$Path, [int]$MaximumBytes = 32768)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -gt $MaximumBytes) { throw 'Recycle monitor JSON exceeds its bounded size.' }
        $bytes = New-Object byte[] ($MaximumBytes + 1)
        $count = 0
        while ($count -le $MaximumBytes) {
            $read = $stream.Read($bytes, $count, $bytes.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt $MaximumBytes) { throw 'Recycle monitor JSON grew beyond its bounded size.' }
        $content = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 0, $count)
        if (-not $content.TrimStart().StartsWith('{', [StringComparison]::Ordinal) -or
            ($content.Length -gt 0 -and $content[0] -eq [char]0xfeff)) { throw 'Recycle monitor JSON must be a BOM-free UTF-8 object.' }
        $options = @{InputObject = $content; ErrorAction = 'Stop'}
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
        $value = ConvertFrom-Json @options
        if ($value -isnot [pscustomobject]) { throw 'Recycle monitor JSON must be one object.' }
        return $value
    } finally { $stream.Dispose() }
}

function Test-StackRecycleMonitorValueEqual {
    param($Original, $Current, [int]$Depth = 0)
    if ($Depth -gt 24) { throw 'Recycle marker nesting exceeds the monitor comparison bound.' }
    if ($null -eq $Original -or $null -eq $Current) { return $null -eq $Original -and $null -eq $Current }
    if ($Original -is [pscustomobject]) {
        if ($Current -isnot [pscustomobject]) { return $false }
        $originalProperties = @($Original.PSObject.Properties)
        $currentProperties = @($Current.PSObject.Properties)
        if ($originalProperties.Count -ne $currentProperties.Count) { return $false }
        foreach ($property in $originalProperties) {
            $matches = @($currentProperties | Where-Object { $_.Name -ceq $property.Name })
            if ($matches.Count -ne 1 -or -not (Test-StackRecycleMonitorValueEqual $property.Value $matches[0].Value ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Original -is [Array]) {
        if ($Current -isnot [Array] -or $Original.Count -ne $Current.Count) { return $false }
        for ($index = 0; $index -lt $Original.Count; $index++) {
            if (-not (Test-StackRecycleMonitorValueEqual $Original[$index] $Current[$index] ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Original.GetType() -ne $Current.GetType()) { return $false }
    if ($Original -is [string]) { return $Original -ceq $Current }
    if ($Original -is [ValueType]) { return $Original.Equals($Current) }
    return $false
}

function Test-StackRecycleMonitorMarker {
    param([Parameter(Mandatory = $true)]$Intent)
    if (-not (Test-Path -LiteralPath $Intent.MarkerPath)) { return $false }
    $marker = Read-StackRecycleMonitorJson -Path $Intent.MarkerPath
    if ($null -ne $marker.PSObject.Properties['resetCompletedAtUtc']) { return $false }
    if ([string]$marker.phase -ceq 'intent') {
        # Even a whitespace rewrite of an intent is supersession. The complete
        # original guard snapshot, including future fields, remains immutable.
        try { $null = Assert-ScaleWorldRecycleIntentUnchanged -Intent $Intent; return $true }
        catch { return $false }
    }
    if ([string]$marker.phase -cne 'replacement_started') { return $false }
    $originalProperties = @($Intent.Marker.PSObject.Properties)
    $currentProperties = @($marker.PSObject.Properties)
    if ($currentProperties.Count -ne $originalProperties.Count + 1) { return $false }
    foreach ($property in $originalProperties) {
        if ($property.Name -ceq 'phase') { continue }
        $matches = @($currentProperties | Where-Object { $_.Name -ceq $property.Name })
        if ($matches.Count -ne 1 -or -not (Test-StackRecycleMonitorValueEqual $property.Value $matches[0].Value)) { return $false }
    }
    $added = @($currentProperties | Where-Object { $_.Name -ceq 'replacementStartedAtUtc' })
    if ($added.Count -ne 1 -or $added[0].Value -isnot [string] -or [string]::IsNullOrWhiteSpace($added[0].Value)) { return $false }
    $stamp = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse($added[0].Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$stamp) -and $stamp.Offset -eq [TimeSpan]::Zero
}

function Open-StackRecycleMonitorProcessHandle {
    param([Parameter(Mandatory = $true)]$Identity)
    Assert-StackLaunchStoredIdentity $Identity
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid)
        $null = $process.Handle
        if ($process.HasExited) { throw 'Recycle monitor process identity has already exited.' }
        $expected = [DateTimeOffset]::Parse([string]$Identity.creationUtc).UtcDateTime
        if ([Math]::Floor([decimal]$process.StartTime.ToUniversalTime().Ticks / 10) -ne [Math]::Floor([decimal]$expected.Ticks / 10) -or
            (Get-StackLaunchCanonicalPath $process.MainModule.FileName) -ine (Get-StackLaunchCanonicalPath ([string]$Identity.executablePath))) {
            throw 'Recycle monitor retained process identity does not match its exact birth and executable.'
        }
        return $process
    } catch { if ($null -ne $process) { $process.Dispose() }; throw }
}

function Write-StackRecycleMonitorCreateNewJson {
    param([string]$Path, [Parameter(Mandatory = $true)]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 32 -Compress))
    if ($bytes.Length -gt 32768) { throw 'Recycle monitor receipt/diagnostic exceeds its bounded size.' }
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream = $null
        # Move never overwrites an existing receipt. Publication is atomic and
        # readers cannot see the destination until its contents are durable.
        [IO.File]::Move($temporary, $Path)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Start-StackRecycleMonitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Scope,
        [Parameter(Mandatory = $true)]$Intent,
        [Parameter(Mandatory = $true)]$RecyclerIdentity,
        [Parameter(Mandatory = $true)][string]$PlannedGenerationId,
        [ValidateRange(1, 86400)][int]$DeadlineSeconds = 600
    )
    $generation = ConvertTo-StackLaunchUuid $PlannedGenerationId
    $moduleRoot = Get-StackLaunchCanonicalPath ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')))
    if ($moduleRoot -ine $Scope.RepoRoot) { throw 'Recycle monitor must launch from its exact runtime root.' }
    if ($generation -ceq $Intent.ExpectedLaunchGenerationId) { throw 'The monitor requires a fresh planned replacement generation.' }
    $null = Assert-ScaleWorldRecycleIntentUnchanged -Intent $Intent
    $null = Test-StackRecycleMonitorValueEqual $Intent.Marker $Intent.Marker
    $parent = Open-StackRecycleMonitorProcessHandle -Identity $RecyclerIdentity
    $child = $null
    $readyPath = ''
    try {
        if ($RecyclerIdentity.pid -ne $PID -or $RecyclerIdentity.name -ine 'powershell.exe') { throw 'Only the exact recycler process may arm its monitor.' }
        $monitorId = [Guid]::NewGuid().ToString('D')
        $directory = Join-Path $Scope.InstallBase 'state\recycle-monitor-ready'
        [void][IO.Directory]::CreateDirectory($directory)
        $readyPath = Join-Path $directory ($monitorId + '.json')
        $context = [pscustomobject]@{
            schemaVersion = 1; monitorId = $monitorId; repoRoot = $Scope.RepoRoot; installBase = $Scope.InstallBase
            intent = $Intent; recyclerIdentity = $RecyclerIdentity; plannedGenerationId = $generation
            readyPath = $readyPath; deadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds($DeadlineSeconds).ToString('o')
        }
        $contextBytes = [Text.UTF8Encoding]::new($false).GetBytes(($context | ConvertTo-Json -Depth 32 -Compress))
        $contextBase64 = [Convert]::ToBase64String($contextBytes)
        if ($contextBase64.Length -gt 32768) { throw 'Recycle monitor context exceeds its bounded environment size.' }
        $entry = Get-StackLaunchCanonicalPath (Join-Path $PSScriptRoot 'invoke_stack_recycle_monitor.ps1')
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Get-StackLaunchCanonicalPath ([string]$RecyclerIdentity.executablePath)
        $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $entry + '"'
        $start.WorkingDirectory = $Scope.RepoRoot
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.EnvironmentVariables['SCALEWORLD_RECYCLE_MONITOR_CONTEXT_BASE64'] = $contextBase64
        $child = [Diagnostics.Process]::Start($start)
        $null = $child.Handle
        $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        do {
            if ($child.HasExited) { throw 'Recycle monitor exited before its retained-handle readiness receipt.' }
            if (Test-Path -LiteralPath $readyPath) {
                try { $receipt = Read-StackRecycleMonitorJson -Path $readyPath -MaximumBytes 8192 }
                catch [IO.IOException] { Start-Sleep -Milliseconds 50; continue }
                $identity = Get-StackLaunchProcessIdentity -ProcessId $child.Id
                if ($null -eq $identity -or [int]$receipt.schemaVersion -ne 1 -or
                    [string]$receipt.monitorId -cne $monitorId -or [string]$receipt.generationId -cne $generation -or
                    [string]$receipt.recycleId -cne $Intent.ExpectedRecycleId -or
                    [string]$receipt.helperLaunchId -cne $Intent.ExpectedHelperLaunchId -or
                    [string]$receipt.intentSha256 -cne $Intent.ContentSha256 -or
                    -not (Test-StackLaunchIdentityEqual $receipt.recyclerIdentity $RecyclerIdentity) -or
                    -not (Test-StackLaunchIdentityEqual $receipt.monitorIdentity $identity)) { throw 'Recycle monitor readiness receipt did not match the armed exact operation.' }
                $verified = Open-StackRecycleMonitorProcessHandle -Identity $identity
                $verified.Dispose()
                # Keep the original child handle pinned for parent validation and
                # safe cancellation if durable monitor registration later fails.
                return [pscustomobject]@{MonitorIdentity = $identity; RetainedProcess = $child; MonitorId = $monitorId}
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTimeOffset]::UtcNow -lt $readyDeadline)
        throw 'Recycle monitor did not become ready within ten seconds.'
    } catch {
        if ($null -ne $child) { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }; $child.Dispose() }
        throw
    } finally {
        $parent.Dispose()
        if ($readyPath -and (Test-Path -LiteralPath $readyPath)) { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-StackRecycleMonitorDisposition {
    param($Scope, $Intent, $MonitorIdentity, $RecyclerIdentity, [string]$GenerationId, $LockHandle)
    Assert-StackLaunchLeaseLock -Scope $Scope -LockHandle $LockHandle
    if (-not (Test-StackRecycleMonitorMarker -Intent $Intent)) { return 'Superseded' }
    $ownership = Get-StackLaunchMonitorOwnership -Scope $Scope -GenerationId $GenerationId -RecycleId $Intent.ExpectedRecycleId `
        -HelperLaunchId $Intent.ExpectedHelperLaunchId -MonitorIdentity $MonitorIdentity -RecyclerIdentity $RecyclerIdentity -LockHandle $LockHandle
    return [string]$ownership.Disposition
}

function Test-StackRecycleMonitorCompletedHandoff {
    param($Scope, [string]$GenerationId, [string]$Disposition, $LockHandle)
    Assert-StackLaunchLeaseLock -Scope $Scope -LockHandle $LockHandle
    if ($Disposition -cne 'NodeAlive') { return $false }
    $lease = Read-StackLaunchLease -Scope $Scope
    # The full launcher has completed and scheduled its watchdog. This is only
    # a handoff to existing live-agent supervision, never a claim of media Ready.
    return $null -ne $lease -and $lease.repoRoot -ieq $Scope.RepoRoot -and
        $lease.generationId -ceq $GenerationId -and $lease.phase -ceq 'completed'
}

function Test-StackRecycleMonitorCurrentWithoutLock {
    param($Scope, $Intent, $MonitorIdentity, $RecyclerIdentity, [string]$GenerationId)
    # This read-only peek authorizes only cancelling the retained exact helper
    # when it stranded the mutex. Shutdown always requires a later locked check.
    try {
        if (-not (Test-StackRecycleMonitorMarker -Intent $Intent)) { return $false }
        $lease = Read-StackLaunchLease -Scope $Scope
        if ($null -eq $lease -or $lease.repoRoot -ine $Scope.RepoRoot -or $lease.generationId -cne $GenerationId -or
            $lease.phase -cnotin @('recycling', 'starting', 'completed', 'stopping') -or
            $null -eq $lease.PSObject.Properties['monitor'] -or $null -eq $lease.monitor) { return $false }
        $monitor = $lease.monitor
        if ([string]$monitor.generationId -cne $GenerationId -or [string]$monitor.recycleId -cne $Intent.ExpectedRecycleId -or
            [string]$monitor.helperLaunchId -cne $Intent.ExpectedHelperLaunchId -or
            -not (Test-StackLaunchIdentityEqual $monitor.identity $MonitorIdentity) -or
            -not (Test-StackLaunchIdentityEqual $monitor.recyclerIdentity $RecyclerIdentity)) { return $false }
        # A registered or unregistered scoped Node may already be serving. No
        # helper cancellation is needed in this conservative retirement case.
        foreach ($node in @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace([string]$node.ExecutablePath)) { throw 'Scoped Node executable identity is unavailable.' }
            if ((Get-StackLaunchCanonicalPath ([string]$node.ExecutablePath)) -ieq $Scope.NodePath) { return $false }
        }
        return $true
    } catch { return $false }
}

function Write-StackRecycleMonitorDiagnostic {
    param($Scope, $MonitorIdentity, $RecyclerIdentity, [string]$GenerationId, [string]$MonitorId,
        [ValidateSet('recycle_replacement_node_absent_at_deadline', 'recycle_monitor_unclassified_node_at_deadline')]
        [string]$Reason = 'recycle_replacement_node_absent_at_deadline')
    $path = Join-Path $Scope.InstallBase ('state\stack-recycle-monitor-fault-' + (ConvertTo-StackLaunchUuid $MonitorId) + '.json')
    $value = [pscustomobject]@{
        schemaVersion = 1; reason = $Reason; occurredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        generationId = $GenerationId; monitorPid = [int]$MonitorIdentity.pid; recyclerPid = [int]$RecyclerIdentity.pid
        action = $(if ($Reason -ceq 'recycle_monitor_unclassified_node_at_deadline') { 'review_required_no_shutdown' } else { 'local_os_shutdown_requested' })
    }
    if (Test-Path -LiteralPath $path) {
        $existing = Read-StackRecycleMonitorJson -Path $path
        if ([string]$existing.reason -cne $value.reason -or [string]$existing.generationId -cne $GenerationId -or
            [int]$existing.monitorPid -ne $MonitorIdentity.pid -or [int]$existing.recyclerPid -ne $RecyclerIdentity.pid) { throw 'Recycle monitor diagnostic identity changed.' }
    } else { Write-StackRecycleMonitorCreateNewJson -Path $path -Value $value }
    return $path
}

function Invoke-StackRecycleMonitorLocalShutdown {
    # Local EC2 guest shutdown uses its configured instance-initiated shutdown
    # behavior. Hosted acceptance must verify that behavior is stop, not terminate.
    $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $shutdown = Get-StackLaunchCanonicalPath (Join-Path $windows 'System32\shutdown.exe')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $shutdown; $start.Arguments = '/s /t 0 /f'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'Local recycle fail-stop shutdown was not accepted.' }
    } finally { $process.Dispose() }
}

function Stop-StackRecycleMonitorNativeLaunchers {
    param($Scope, $LockHandle)
    Assert-StackLaunchLeaseLock -Scope $Scope -LockHandle $LockHandle
    $entry = Get-StackLaunchCanonicalPath (Join-Path $Scope.RepoRoot 'platform_scripts\cmd\start_wilbur_native.bat')
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $emptyScans = 0
    do {
        $native = @()
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace([string]$process.CommandLine)) {
                throw 'Native launcher absence cannot be proved without CMD invocation identity.'
            }
            if (Test-StackLaunchScriptInvocation -Process $process -ScriptPath $entry) {
                $identity = Get-StackLaunchCancellationIdentity -Process $process
                if (-not (Test-StackLaunchCmdExecutable -Path $identity.executablePath)) {
                    throw 'Native launcher is not a verified Windows CMD executable.'
                }
                $native += $identity
            } elseif ([string]$process.CommandLine -match '(?i)start_wilbur_native\.bat') {
                # An unparsed/ambiguous invocation cannot prove this scoped
                # producer absent. A mere path mention never authorizes a kill.
                throw 'Native launcher invocation cannot be proved exactly.'
            }
        }
        if ($native.Count -eq 0) {
            $emptyScans++
            if ($emptyScans -ge 2) { return }
        } else {
            $emptyScans = 0
            foreach ($identity in $native) {
                $remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                if ($remaining -le 0) { throw 'Native launcher cancellation exceeded its bounded wait.' }
                # The existing helper opens a retained handle, verifies exact
                # birth/executable, then kills that shell only, never its Node.
                Stop-StackLaunchProcessIdentity -Identity $identity -TimeoutMilliseconds ([Math]::Min(5000, $remaining))
            }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native launcher absence was not proved within five seconds.'
}

function Invoke-StackRecycleMonitorDeadline {
    param($Scope, $Intent, $MonitorIdentity, $RecyclerIdentity, [string]$GenerationId, [string]$MonitorId, $LockHandle)
    $disposition = Get-StackRecycleMonitorDisposition -Scope $Scope -Intent $Intent -MonitorIdentity $MonitorIdentity `
        -RecyclerIdentity $RecyclerIdentity -GenerationId $GenerationId -LockHandle $LockHandle
    if ($disposition -cin @('Superseded', 'NodeAlive')) { return $disposition }
    if ($disposition -ceq 'NodeUnclassified') {
        $null = Write-StackRecycleMonitorDiagnostic -Scope $Scope -MonitorIdentity $MonitorIdentity -RecyclerIdentity $RecyclerIdentity `
            -GenerationId $GenerationId -MonitorId $MonitorId -Reason 'recycle_monitor_unclassified_node_at_deadline'
        return 'NodeUnclassified'
    }
    if ($disposition -cnotin @('Current', 'Stopping')) { throw 'Recycle monitor ownership disposition is invalid.' }
    # A wrapper killed before Node birth can leave its tiny native CMD alive.
    # Cancel only that exact producer under the held gate, before the final Node
    # scan; future wrapped launches are blocked by this mutex/stopping fence.
    Stop-StackRecycleMonitorNativeLaunchers -Scope $Scope -LockHandle $LockHandle
    # The gate serializes lease actors, but marker writers are independent.
    # Retire if completion/supersession arrived during producer cancellation.
    if (-not (Test-StackRecycleMonitorMarker -Intent $Intent)) { return 'Superseded' }
    # Set performs its own atomic Node recheck while the same gate is held. A
    # stopping lease rejects delayed spawn gates before shutdown is requested.
    $stopped = Set-StackLaunchStopping -Scope $Scope -GenerationId $GenerationId -RecycleId $Intent.ExpectedRecycleId `
        -HelperLaunchId $Intent.ExpectedHelperLaunchId -MonitorIdentity $MonitorIdentity -RecyclerIdentity $RecyclerIdentity -LockHandle $LockHandle
    if ([string]$stopped.Disposition -ceq 'NodeAlive') { return 'NodeAlive' }
    if ([string]$stopped.Disposition -ceq 'NodeUnclassified') {
        $null = Write-StackRecycleMonitorDiagnostic -Scope $Scope -MonitorIdentity $MonitorIdentity -RecyclerIdentity $RecyclerIdentity `
            -GenerationId $GenerationId -MonitorId $MonitorId -Reason 'recycle_monitor_unclassified_node_at_deadline'
        return 'NodeUnclassified'
    }
    if ([string]$stopped.Disposition -cne 'Stopping') { return 'Superseded' }
    if (-not (Test-StackRecycleMonitorMarker -Intent $Intent)) { return 'Superseded' }
    $null = Write-StackRecycleMonitorDiagnostic -Scope $Scope -MonitorIdentity $MonitorIdentity -RecyclerIdentity $RecyclerIdentity `
        -GenerationId $GenerationId -MonitorId $MonitorId
    # Durable diagnostic I/O is another interval where the marker may change.
    # It never substitutes for current immutable intent at the actual action.
    if (-not (Test-StackRecycleMonitorMarker -Intent $Intent)) { return 'Superseded' }
    Invoke-StackRecycleMonitorLocalShutdown
    return 'ShutdownRequested'
}
