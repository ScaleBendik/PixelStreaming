[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack_recycle_monitor.ps1')
$parent = $null
try {
    $encoded = [string]$env:SCALEWORLD_RECYCLE_MONITOR_CONTEXT_BASE64
    if (-not $encoded -or $encoded.Length -gt 32768) { throw 'A bounded private recycle monitor context is required.' }
    $content = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($encoded))
    if (-not $content.StartsWith('{', [StringComparison]::Ordinal)) { throw 'Recycle monitor context must be one JSON object.' }
    $context = $content | ConvertFrom-Json -ErrorAction Stop
    if ($context -isnot [pscustomobject] -or [int]$context.schemaVersion -ne 1) { throw 'Recycle monitor context schema is invalid.' }
    $monitorId = ConvertTo-StackLaunchUuid ([string]$context.monitorId)
    $generation = ConvertTo-StackLaunchUuid ([string]$context.plannedGenerationId)
    $scope = Get-StackLaunchLeaseScope -RepoRoot $context.repoRoot -InstallBase $context.installBase
    $moduleRoot = Get-StackLaunchCanonicalPath ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')))
    if ($moduleRoot -ine $scope.RepoRoot) { throw 'Recycle monitor context does not belong to this exact runtime root.' }
    $expectedReadyPath = Join-Path $scope.InstallBase ('state\recycle-monitor-ready\' + $monitorId + '.json')
    if ([IO.Path]::GetFullPath([string]$context.readyPath) -cne $expectedReadyPath) { throw 'Recycle monitor readiness path is outside its exact operation.' }
    $deadline = [DateTimeOffset]::Parse([string]$context.deadlineUtc, [Globalization.CultureInfo]::InvariantCulture)
    $remainingSeconds = ($deadline - [DateTimeOffset]::UtcNow).TotalSeconds
    if ($remainingSeconds -le 0 -or $remainingSeconds -gt 86400) { throw 'Recycle monitor deadline is outside its bounded arm window.' }
    $parent = Open-StackRecycleMonitorProcessHandle -Identity $context.recyclerIdentity
    if ($context.recyclerIdentity.name -ine 'powershell.exe') { throw 'Recycle monitor parent is not the exact PowerShell helper.' }
    $intent = $context.intent
    $null = Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent
    $null = Test-StackRecycleMonitorValueEqual $intent.Marker $intent.Marker
    if ($generation -ceq $intent.ExpectedLaunchGenerationId) { throw 'Recycle monitor replacement generation is not fresh.' }
    $identity = Get-StackLaunchProcessIdentity -ProcessId $PID
    $receipt = [pscustomobject]@{
        schemaVersion = 1; monitorId = $monitorId; generationId = $generation
        recycleId = $intent.ExpectedRecycleId; helperLaunchId = $intent.ExpectedHelperLaunchId; intentSha256 = $intent.ContentSha256
        recyclerIdentity = $context.recyclerIdentity; monitorIdentity = $identity
    }
    # No launch mutex is acquired before readiness: the arming parent holds it.
    Write-StackRecycleMonitorCreateNewJson -Path $expectedReadyPath -Value $receipt
    $wasArmed = $false
    while ($true) {
        $lock = $null
        try {
            try { $lock = Enter-StackLaunchLeaseLock -Scope $scope -TimeoutSeconds 1 }
            catch {
                if ([DateTimeOffset]::UtcNow -ge $deadline) {
                    if (-not (Test-StackRecycleMonitorCurrentWithoutLock -Scope $scope -Intent $intent `
                        -MonitorIdentity $identity -RecyclerIdentity $context.recyclerIdentity -GenerationId $generation)) { exit 0 }
                    # Only the retained exact helper can be cancelled, and only
                    # after a trusted read-only current-tuple/marker peek. An
                    # identity or I/O ambiguity never authorizes this cancellation.
                    if (-not $parent.HasExited) { $parent.Kill(); [void]$parent.WaitForExit(5000) }
                    $lock = Enter-StackLaunchLeaseLock -Scope $scope -TimeoutSeconds 15
                }
            }
            if ($null -eq $lock) { throw 'Recycle monitor launch mutex is not available yet.' }
            $disposition = Get-StackRecycleMonitorDisposition -Scope $scope -Intent $intent -MonitorIdentity $identity `
                -RecyclerIdentity $context.recyclerIdentity -GenerationId $generation -LockHandle $lock
            if (Test-StackRecycleMonitorCompletedHandoff -Scope $scope -GenerationId $generation -Disposition $disposition -LockHandle $lock) { exit 0 }
            if ($disposition -cin @('Current', 'NodeAlive', 'NodeUnclassified', 'Stopping')) { $wasArmed = $true }
            if ($disposition -ceq 'Superseded') {
                if ($wasArmed -or [DateTimeOffset]::UtcNow -ge $deadline) { exit 0 }
                # Before Begin, the old G1 lease is expected. No action is allowed.
            } elseif ([DateTimeOffset]::UtcNow -ge $deadline) {
                $result = Invoke-StackRecycleMonitorDeadline -Scope $scope -Intent $intent -MonitorIdentity $identity `
                    -RecyclerIdentity $context.recyclerIdentity -GenerationId $generation -MonitorId $monitorId -LockHandle $lock
                if ($result -cne 'ShutdownRequested') { exit 0 }
            }
        } catch {
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                # Keep the pin alive and retry a failed shutdown/diagnostic or an
                # ambiguous locked read. No generic catch may kill the helper.
                Write-Warning 'Recycle orphan monitor could not finish its deadline check; no additional authority was inferred.'
            }
        } finally { if ($null -ne $lock) { Exit-StackLaunchLeaseLock -Handle $lock } }
        # Remain a live lease pin while OS shutdown is pending. A failed guest
        # shutdown is retried under the same stopping fence after thirty seconds.
        if ([DateTimeOffset]::UtcNow -ge $deadline) { Start-Sleep -Seconds 30 }
        else { Start-Sleep -Milliseconds 1000 }
    }
} catch {
    Write-Error ('Recycle orphan monitor failed: ' + $_.Exception.Message)
    exit 1
} finally { if ($null -ne $parent) { $parent.Dispose() } }
