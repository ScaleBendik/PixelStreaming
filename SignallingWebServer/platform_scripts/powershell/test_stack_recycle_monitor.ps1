[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack_recycle_monitor.ps1')

function Assert-Monitor { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-MonitorRejects { param([scriptblock]$Action, [string]$Message)
    $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Assert-Monitor $rejected $Message
}
function Write-MonitorMarker { param($Marker)
    [IO.File]::WriteAllText($script:markerPath, ($Marker | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
function New-MonitorMarker {
    [pscustomobject]@{
        schemaVersion = 2; phase = 'intent'; recycleId = ('opaque-&|<>^%!-"-unicode-' + [char]0x03bb); reason = 'post_session_cleanup'
        requestedAtUtc = '2026-10-12T10:00:00.000Z'; sourcePid = 1234
        helperLaunchId = '11111111-1111-4111-8111-111111111111'
        sourceLaunchGenerationId = '22222222-2222-4222-8222-222222222222'; sourceCreationUtc = '2026-10-12T09:59:00.1234560Z'
        recycleRequestedToken = 'original-token'; sessionRequestId = 'original-request'; userSessionId = 'original-user'; sessionId = 'original-session'
        future = [pscustomobject]@{ nested = @(1, 'exact', [pscustomobject]@{ keep = $true }) }
    }
}
function Reset-MonitorFixture {
    $script:marker = New-MonitorMarker
    Write-MonitorMarker $script:marker
    $script:intent = Read-ScaleWorldRecycleIntent -MarkerPath $script:markerPath -ExpectedRecycleId $script:marker.recycleId `
        -ExpectedSourcePid 1234 -ExpectedHelperLaunchId $script:marker.helperLaunchId `
        -ExpectedLaunchGenerationId $script:marker.sourceLaunchGenerationId -ExpectedSourceCreationUtc $script:marker.sourceCreationUtc
    $lease = New-StackLaunchLease -Scope $script:scope -OwnerIdentity $null -GenerationId $script:generation
    $lease.phase = 'recycling'; $lease.recycler = $script:helper | Select-Object *
    $lease.recycler | Add-Member -NotePropertyName recycleId -NotePropertyValue $script:marker.recycleId
    $lease | Add-Member -NotePropertyName monitor -NotePropertyValue ([pscustomobject]@{
        identity = $script:monitor; recyclerIdentity = $script:helper; recycleId = $script:marker.recycleId
        helperLaunchId = $script:marker.helperLaunchId; generationId = $script:generation
    }) -Force
    Write-StackLaunchLease -Scope $script:scope -Lease $lease -LockHandle $script:lock
    $script:live = @{ 4321 = $true }; $script:nodes = @(); $script:scanFails = $false; $script:shutdownCalls = 0; $script:lateNode = $null
    $script:nativeLaunchers = @(); $script:cancelledLaunchers = @(); $script:nodeOnCancellation = $null; $script:cmdScans = 0
    $script:markerOnCancellation = $null; $script:markerAfterStopping = $null; $script:markerOnDiagnostic = $null; $script:diagnosticCalls = 0
    $script:monitorId = [Guid]::NewGuid().ToString('D')
    $script:monitorDeadlineArgs = @{Scope = $script:scope; Intent = $script:intent; MonitorIdentity = $script:monitor; RecyclerIdentity = $script:helper
        GenerationId = $script:generation; MonitorId = $script:monitorId; LockHandle = $script:lock}
}

# Verify retained native handle birth/executable checks using only this test's
# own process, before replacing process discovery with bounded fixture callbacks.
$own = Get-StackLaunchProcessIdentity -ProcessId $PID
$retained = Open-StackRecycleMonitorProcessHandle -Identity $own
Assert-Monitor ($retained.Id -eq $PID) 'Monitor must open its exact process handle.'
$retained.Dispose()
$wrong = $own | Select-Object *; $wrong.creationUtc = [DateTimeOffset]::Parse($wrong.creationUtc).AddSeconds(1).UtcDateTime.ToString('o')
Assert-MonitorRejects { Open-StackRecycleMonitorProcessHandle -Identity $wrong } 'PID reuse/wrong birth must refuse a native handle.'

function Test-StackLaunchProcessIdentity { param($Identity, $Process)
    return $null -ne $Identity -and $script:live.ContainsKey([int]$Identity.pid) -and $script:live[[int]$Identity.pid]
}
function Get-CimInstance { [CmdletBinding()]param($ClassName, $Filter)
    if ($script:scanFails) { throw 'Synthetic bounded process read failure.' }
    if ($ClassName -cne 'Win32_Process') { throw 'Unexpected process discovery query.' }
    if ($Filter -ceq "Name = 'node.exe'") { return $script:nodes }
    if ($Filter -ceq "Name = 'cmd.exe'") { $script:cmdScans++; return $script:nativeLaunchers }
    throw 'Unexpected process discovery query.'
}
function Stop-StackLaunchProcessIdentity {
    param($Identity, $TimeoutMilliseconds)
    $matches = @($script:nativeLaunchers | Where-Object { [int]$_.ProcessId -eq [int]$Identity.pid })
    Assert-Monitor ($matches.Count -eq 1) 'Cancellation callback may receive only the captured native shell.'
    $expected = Get-StackLaunchCancellationIdentity -Process $matches[0]
    Assert-Monitor ($Identity.creationUtc -ceq $expected.creationUtc -and $Identity.executablePath -ieq $expected.executablePath) 'Exact shell birth and executable must reach retained-handle cancellation.'
    Assert-Monitor ($TimeoutMilliseconds -gt 0 -and $TimeoutMilliseconds -le 5000) 'Native shell cancellation must use a bounded wait.'
    $script:cancelledLaunchers += $Identity
    $script:nativeLaunchers = @($script:nativeLaunchers | Where-Object { [int]$_.ProcessId -ne [int]$Identity.pid })
    if ($null -ne $script:nodeOnCancellation) { $script:nodes = @($script:nodeOnCancellation) }
    if ($null -ne $script:markerOnCancellation) { Write-MonitorMarker $script:markerOnCancellation }
}
$script:originalStopping = (Get-Item Function:\Set-StackLaunchStopping).ScriptBlock
function Set-StackLaunchStopping {
    param($Scope, $GenerationId, $RecycleId, $HelperLaunchId, $MonitorIdentity, $RecyclerIdentity, $LockHandle)
    if ($null -ne $script:lateNode) { $script:nodes = @($script:lateNode) }
    $result = & $script:originalStopping @PSBoundParameters
    if ($null -ne $script:markerAfterStopping) { Write-MonitorMarker $script:markerAfterStopping }
    return $result
}
$script:originalDiagnostic = (Get-Item Function:\Write-StackRecycleMonitorDiagnostic).ScriptBlock
function Write-StackRecycleMonitorDiagnostic {
    param($Scope, $MonitorIdentity, $RecyclerIdentity, $GenerationId, $MonitorId,
        $Reason = 'recycle_replacement_node_absent_at_deadline')
    $result = & $script:originalDiagnostic @PSBoundParameters
    $script:diagnosticCalls++
    if ($null -ne $script:markerOnDiagnostic) { Write-MonitorMarker $script:markerOnDiagnostic }
    return $result
}
function Invoke-StackRecycleMonitorLocalShutdown {
    # This unconditional unit callback is never part of the deployed entry.
    $lease = Read-StackLaunchLease -Scope $script:scope
    Assert-Monitor ($lease.phase -ceq 'stopping') 'Durable stopping fence must precede the fake local shutdown callback.'
    $diagnostic = Join-Path $script:scope.InstallBase ('state\stack-recycle-monitor-fault-' + $script:monitorId + '.json')
    Assert-Monitor (Test-Path -LiteralPath $diagnostic) 'Durable diagnostic must precede the fake shutdown callback.'
    $script:shutdownCalls++
}

$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $parent ('ScaleWorldRecycleMonitorTest-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'runtime\platform_scripts\cmd\node'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'base\state'))
[IO.File]::WriteAllText((Join-Path $testRoot 'runtime\platform_scripts\cmd\node\node.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $testRoot 'runtime\platform_scripts\cmd\start_wilbur_native.bat'), '@echo off')
$script:scope = Get-StackLaunchLeaseScope -RepoRoot (Join-Path $testRoot 'runtime') -InstallBase (Join-Path $testRoot 'base')
$script:markerPath = Join-Path $testRoot 'marker.json'
$script:generation = '33333333-3333-4333-8333-333333333333'
$script:helper = [pscustomobject]@{pid = 2345; creationUtc = '2026-10-12T10:00:00.1234560Z'; executablePath = $own.executablePath; name = 'powershell.exe'}
$script:monitor = [pscustomobject]@{pid = 4321; creationUtc = '2026-10-12T10:00:01.1234560Z'; executablePath = $own.executablePath; name = 'powershell.exe'}
$script:lock = Enter-StackLaunchLeaseLock -Scope $script:scope
try {
    Reset-MonitorFixture
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:markerPath))
    Assert-Monitor ((Get-StackRecycleMonitorDisposition -Scope $scope -Intent $intent -MonitorIdentity $monitor -RecyclerIdentity $helper -GenerationId $generation -LockHandle $lock) -ceq 'Current') 'Current pending operation must wait.'
    Assert-Monitor ($shutdownCalls -eq 0) 'Observation before the deadline must never stop.'
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'ShutdownRequested') 'Exact orphan must reach bounded fake shutdown.'
    Assert-Monitor ($shutdownCalls -eq 1) 'Exact orphan must call fake stop once.'
    Assert-Monitor ($before -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:markerPath))) 'Fail-stop must preserve all marker/admission provenance.'
    Write-Host 'Passed: exact orphan reaches stopping and diagnostic before fake shutdown without marker mutation.'

    Reset-MonitorFixture
    $nativeEntry = Join-Path $scope.RepoRoot 'platform_scripts\cmd\start_wilbur_native.bat'
    $cmdExe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'cmd.exe'
    $nativeShell = [pscustomobject]@{ProcessId = 6789; Name = 'cmd.exe'; ExecutablePath = $cmdExe
        CreationDate = [DateTimeOffset]::Parse('2026-10-12T10:00:03.1234560Z').UtcDateTime
        CommandLine = ('"' + $cmdExe + '" /d /s /c ""' + $nativeEntry + '""')}
    $unrelatedShell = [pscustomobject]@{ProcessId = 6790; Name = 'cmd.exe'; ExecutablePath = $cmdExe
        CreationDate = [DateTimeOffset]::Parse('2026-10-12T10:00:04.1234560Z').UtcDateTime
        CommandLine = ('"' + $cmdExe + '" /c echo unrelated')}
    $script:nativeLaunchers = @($nativeShell, $unrelatedShell)
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'ShutdownRequested' -and $shutdownCalls -eq 1) 'Latent exact native shell must be cancelled before fake shutdown.'
    Assert-Monitor ($cancelledLaunchers.Count -eq 1 -and $cancelledLaunchers[0].pid -eq 6789) 'Only the exact native launcher may be cancelled.'
    Assert-Monitor ($nativeLaunchers.Count -eq 1 -and $nativeLaunchers[0].ProcessId -eq 6790 -and $cmdScans -ge 3) 'Unrelated shell must survive and repeated native absence must be proved.'

    Reset-MonitorFixture
    $script:nativeLaunchers = @($nativeShell)
    $script:nodeOnCancellation = [pscustomobject]@{ProcessId = 9876; Name = 'node.exe'; ExecutablePath = $scope.NodePath
        CreationDate = [DateTimeOffset]::Parse('2026-10-12T10:00:04.1234560Z').UtcDateTime}
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'NodeUnclassified' -and $shutdownCalls -eq 0) 'Node born while its exact parent shell is cancelled must exclude shutdown.'
    Assert-Monitor ($cancelledLaunchers.Count -eq 1 -and (Read-StackLaunchLease $scope).phase -ceq 'recycling') 'Final Node scan must preserve the lease instead of setting stopping.'
    $diagnostic = Read-StackRecycleMonitorJson (Join-Path $scope.InstallBase ('state\stack-recycle-monitor-fault-' + $monitorId + '.json'))
    Assert-Monitor ($diagnostic.action -ceq 'review_required_no_shutdown') 'A Node born during shell cancellation must receive the distinct no-shutdown diagnostic.'

    foreach ($ambiguous in @('argv', 'birth', 'executable', 'mention')) {
        Reset-MonitorFixture
        $unproven = $nativeShell | Select-Object *
        switch ($ambiguous) {
            argv { $unproven.CommandLine = $null }
            birth { $unproven.CreationDate = $null }
            executable { $unproven.ExecutablePath = $null }
            mention { $unproven.CommandLine = ('"' + $cmdExe + '" /c echo "' + $nativeEntry + '"') }
        }
        $script:nativeLaunchers = @($unproven)
        Assert-MonitorRejects { Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs } ('Ambiguous native ' + $ambiguous + ' must deny shutdown.')
        Assert-Monitor ($cancelledLaunchers.Count -eq 0 -and $shutdownCalls -eq 0 -and (Read-StackLaunchLease $scope).phase -ceq 'recycling') 'Unproved shell must never be cancelled or authorize stopping.'
    }
    Write-Host 'Passed: exact latent CMD cancellation, repeated absence, unrelated shell preservation and just-born Node shutdown exclusion.'

    foreach ($change in @('completed', 'superseded')) {
        Reset-MonitorFixture
        $replacementMarker = $marker | Select-Object *
        if ($change -ceq 'completed') {
            $replacementMarker | Add-Member -NotePropertyName resetCompletedAtUtc -NotePropertyValue '2026-10-12T10:00:05.000Z'
        } else { $replacementMarker.helperLaunchId = '44444444-4444-4444-8444-444444444444' }
        $script:nativeLaunchers = @($nativeShell)
        $script:markerOnCancellation = $replacementMarker
        Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded') ('Marker ' + $change + ' during cancellation must retire before stopping.')
        Assert-Monitor ($cancelledLaunchers.Count -eq 1 -and $shutdownCalls -eq 0 -and $diagnosticCalls -eq 0 -and (Read-StackLaunchLease $scope).phase -ceq 'recycling') 'Cancellation-time marker change must prevent stopping, diagnostic and shutdown.'
        Assert-Monitor (Test-StackRecycleMonitorValueEqual $replacementMarker (Read-StackRecycleMonitorJson $markerPath)) 'Monitor must preserve the independently changed marker.'
    }

    Reset-MonitorFixture
    $completedMarker = $marker | Select-Object *
    $completedMarker | Add-Member -NotePropertyName resetCompletedAtUtc -NotePropertyValue '2026-10-12T10:00:05.000Z'
    $script:markerAfterStopping = $completedMarker
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded' -and $shutdownCalls -eq 0 -and $diagnosticCalls -eq 0) 'Completion at the final stopping boundary must prevent diagnostic and shutdown.'
    Assert-Monitor ((Read-StackLaunchLease $scope).phase -ceq 'stopping') 'Late completion must not undo the durable generation fence.'

    Reset-MonitorFixture
    $newDispatchMarker = $marker | Select-Object *
    $newDispatchMarker.helperLaunchId = '44444444-4444-4444-8444-444444444444'
    $script:markerOnDiagnostic = $newDispatchMarker
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded' -and $shutdownCalls -eq 0 -and $diagnosticCalls -eq 1) 'Supersession during durable diagnostic I/O must prevent actual shutdown.'
    Assert-Monitor (Test-StackRecycleMonitorValueEqual $newDispatchMarker (Read-StackRecycleMonitorJson $markerPath)) 'Diagnostic-boundary supersession must remain untouched.'
    Write-Host 'Passed: full marker rechecks fence completion/supersession during cancellation, final stopping and diagnostic I/O.'

    Reset-MonitorFixture
    $marker.phase = 'replacement_started'; $marker | Add-Member -NotePropertyName replacementStartedAtUtc -NotePropertyValue '2026-10-12T10:00:02.1234560Z'
    Write-MonitorMarker $marker
    Assert-Monitor (Test-StackRecycleMonitorMarker $intent) 'Only valid replacement phase/timestamp addition is permitted.'
    $marker.future.nested[2].keep = $false; Write-MonitorMarker $marker
    Assert-Monitor (-not (Test-StackRecycleMonitorMarker $intent)) 'Unknown nested immutable fields must fence a monitor.'
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded' -and $shutdownCalls -eq 0) 'Changed marker must never stop.'
    Write-Host 'Passed: replacement progress is allowed while all original and future fields stay immutable.'

    foreach ($field in @('recycleRequestedToken', 'sessionRequestId', 'sourcePid', 'helperLaunchId', 'recycleId', 'requestedAtUtc', 'sourceCreationUtc')) {
        Reset-MonitorFixture
        if ($field -ceq 'sourcePid') { $marker.sourcePid++ } else { $marker.$field = 'changed' }
        Write-MonitorMarker $marker
        Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded' -and $shutdownCalls -eq 0) ('Changed ' + $field + ' must fence stop.')
    }
    foreach ($terminal in @('missing', 'completed', 'unknown-phase', 'same-operation-new-dispatch')) {
        Reset-MonitorFixture
        switch ($terminal) {
            missing { Remove-Item -LiteralPath $markerPath }
            completed { $marker | Add-Member -NotePropertyName resetCompletedAtUtc -NotePropertyValue '2026-10-12T10:00:03.000Z'; Write-MonitorMarker $marker }
            unknown-phase { $marker.phase = 'invalid'; Write-MonitorMarker $marker }
            same-operation-new-dispatch { $marker.helperLaunchId = '44444444-4444-4444-8444-444444444444'; Write-MonitorMarker $marker }
        }
        Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded' -and $shutdownCalls -eq 0) ($terminal + ' must never stop.')
    }
    Write-Host 'Passed: token/request/source/dispatch rewrites, completion and marker removal cause no action.'

    Reset-MonitorFixture
    $lease = Read-StackLaunchLease $scope
    $node = [pscustomobject]@{pid = 9876; creationUtc = '2026-10-12T10:00:03.1234560Z'; executablePath = $scope.NodePath; name = 'node.exe'}
    $lease.activeNode = $node; $script:live[9876] = $true; Write-StackLaunchLease $scope $lease $lock
    Assert-Monitor (-not (Test-StackRecycleMonitorCompletedHandoff -Scope $scope -GenerationId $generation -Disposition 'NodeAlive' -LockHandle $lock)) 'Early starting Node pin must remain monitored.'
    $lease.phase = 'completed'; $lease.completedNode = $node
    $lease.owner = [pscustomobject]@{pid = 3456; creationUtc = '2026-10-12T10:00:02.1234560Z'
        executablePath = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'cmd.exe'); name = 'cmd.exe'; entryPath = $scope.EntryPath}
    Write-StackLaunchLease $scope $lease $lock
    Assert-Monitor (Test-StackRecycleMonitorCompletedHandoff -Scope $scope -GenerationId $generation -Disposition 'NodeAlive' -LockHandle $lock) 'Completed live stack may hand back to its existing agent/watchdog without a Ready claim.'
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'NodeAlive' -and $shutdownCalls -eq 0) 'Live exact replacement Node must never be stopped.'
    $script:live.Remove(9876)
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'ShutdownRequested' -and $shutdownCalls -eq 1) 'Node that dies after early registration must still be caught before completion.'

    Reset-MonitorFixture
    $script:nodes = @([pscustomobject]@{ProcessId = 9876; Name = 'node.exe'; ExecutablePath = $scope.NodePath; CreationDate = [DateTime]::Parse('2026-10-12T10:00:03Z')})
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'NodeUnclassified' -and $shutdownCalls -eq 0) 'Unregistered scoped Node must exclude shutdown.'
    $diagnostic = Read-StackRecycleMonitorJson (Join-Path $scope.InstallBase ('state\stack-recycle-monitor-fault-' + $monitorId + '.json'))
    Assert-Monitor ($diagnostic.action -ceq 'review_required_no_shutdown') 'Unclassified Node requires distinct diagnostic without a Ready claim.'
    Reset-MonitorFixture
    $script:lateNode = [pscustomobject]@{ProcessId = 9876; Name = 'node.exe'; ExecutablePath = $scope.NodePath; CreationDate = [DateTime]::Parse('2026-10-12T10:00:03Z')}
    Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'NodeUnclassified' -and $shutdownCalls -eq 0) 'Final stopping recheck must deny a newly observed unregistered Node.'
    $diagnostic = Read-StackRecycleMonitorJson (Join-Path $scope.InstallBase ('state\stack-recycle-monitor-fault-' + $monitorId + '.json'))
    Assert-Monitor ($diagnostic.action -ceq 'review_required_no_shutdown') 'Final-recheck unclassified Node needs the same diagnostic.'
    Write-Host 'Passed: live/late-dead pins and unregistered scoped Node preserve shutdown exclusion.'

    foreach ($change in @('generation', 'monitor-birth', 'helper-birth', 'dispatch', 'operation')) {
        Reset-MonitorFixture; $lease = Read-StackLaunchLease $scope
        switch ($change) {
            generation { $lease.generationId = '55555555-5555-4555-8555-555555555555'; $lease.monitor.generationId = $lease.generationId }
            monitor-birth { $lease.monitor.identity.creationUtc = '2026-10-12T10:00:02.1234560Z' }
            helper-birth { $lease.monitor.recyclerIdentity.creationUtc = '2026-10-12T10:00:02.1234560Z'; $lease.recycler.creationUtc = $lease.monitor.recyclerIdentity.creationUtc }
            dispatch { $lease.monitor.helperLaunchId = '44444444-4444-4444-8444-444444444444' }
            operation { $lease.monitor.recycleId = 'new-operation'; $lease.recycler.recycleId = $lease.monitor.recycleId }
        }
        Write-StackLaunchLease $scope $lease $lock
        Assert-Monitor (-not (Test-StackRecycleMonitorCurrentWithoutLock -Scope $scope -Intent $intent -MonitorIdentity $monitor -RecyclerIdentity $helper -GenerationId $generation)) 'Readonly hung-lock peek must deny superseded helper cancellation.'
        Assert-Monitor ((Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs) -ceq 'Superseded' -and $shutdownCalls -eq 0) ('Stale ' + $change + ' must never stop.')
    }
    Reset-MonitorFixture
    Assert-Monitor (Test-StackRecycleMonitorCurrentWithoutLock -Scope $scope -Intent $intent -MonitorIdentity $monitor -RecyclerIdentity $helper -GenerationId $generation) 'Exact tuple permits only retained-helper cancellation peek.'
    $script:scanFails = $true
    Assert-Monitor (-not (Test-StackRecycleMonitorCurrentWithoutLock -Scope $scope -Intent $intent -MonitorIdentity $monitor -RecyclerIdentity $helper -GenerationId $generation)) 'Identity read failure denies unlocked cancellation.'
    Assert-MonitorRejects { Invoke-StackRecycleMonitorDeadline @script:monitorDeadlineArgs } 'Identity read failure must deny shutdown.'
    Assert-Monitor ($shutdownCalls -eq 0) 'Failed discovery must never reach fake shutdown.'
    Write-Host 'Passed: exact stale tuple/birth/generation fences and identity read failures deny stop/cancellation.'

    $ready = Join-Path $testRoot 'ready.json'
    Write-StackRecycleMonitorCreateNewJson $ready ([pscustomobject]@{proof = 'durable'})
    Assert-Monitor ((Read-StackRecycleMonitorJson $ready).proof -ceq 'durable') 'Atomic receipt must be fully readable.'
    Assert-MonitorRejects { Write-StackRecycleMonitorCreateNewJson $ready ([pscustomobject]@{proof = 'changed'}) } 'Receipt publication must never replace an existing ready proof.'
    Assert-Monitor ((Read-StackRecycleMonitorJson $ready).proof -ceq 'durable') 'Existing receipt must be preserved.'
    Write-Host 'Passed: atomic durable receipt publication preserves CreateNew uniqueness.'
    Write-Host 'All recycle monitor tests passed (local shutdown was replaced by the isolated test callback).'
} finally {
    Exit-StackLaunchLeaseLock -Handle $script:lock
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith(($parent.TrimEnd('\') + '\ScaleWorldRecycleMonitorTest-'), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}
