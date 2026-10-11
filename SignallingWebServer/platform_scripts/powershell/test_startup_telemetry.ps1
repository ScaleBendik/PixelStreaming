[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'startup_telemetry.ps1')

function Assert-Telemetry {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

$scratchBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $scratchBase ('sw-startup-telemetry-' + [guid]::NewGuid().ToString('N'))))
if (!$scratch.StartsWith($scratchBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test scratch path.' }
[void][IO.Directory]::CreateDirectory($scratch)
$jobs = @()
try {
    $launchId = [guid]::NewGuid().ToString('D')
    $statePath = Join-Path $scratch 'auth.json'
    [IO.File]::WriteAllText($statePath, '{"commercialRecoveryRequired":true,"bootstrapSecret":"DO_NOT_EMIT_SECRET","ownerEmail":"hidden@example.test"}')
    $context = New-ScaleWorldStartupTelemetryContext -Enabled $true -Role 'instance-config' -LaunchId $launchId `
        -JournalDirectory $scratch -RecoveryStatePath $statePath
    Assert-Telemetry ($null -ne $context) 'Valid telemetry must initialize.'
    $before = [IO.File]::ReadAllText($context.Path)
    $phaseTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
    Start-Sleep -Milliseconds 5
    Write-ScaleWorldStartupTelemetryPhase $context 'config.pointer_fetch' -StartedTimestamp $phaseTimestamp -ExitCode 0
    $records = @([IO.File]::ReadAllLines($context.Path) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Telemetry ($records.Count -eq 2 -and $records[0].commercialRecoveryRequired -eq $true) 'Recovery observation or phase append missing.'
    Assert-Telemetry ($records[1].durationMs -gt 0 -and $records[1].elapsedMs -ge $records[1].durationMs) 'PowerShell phase durations must use Stopwatch.'
    Assert-Telemetry ($records[1].clockBasis -eq 'stopwatch' -and $records[1].launchId -eq $launchId) 'Phase identity/clock basis changed.'
    Assert-Telemetry ([IO.File]::ReadAllText($context.Path).StartsWith($before)) 'Phase writes must preserve earlier bytes.'
    Assert-Telemetry ([IO.File]::ReadAllText($context.Path) -notmatch 'DO_NOT_EMIT_SECRET|hidden@example') 'Recovery diagnostics leaked unallowlisted fields.'

    $length = (Get-Item -LiteralPath $context.Path).Length
    Write-ScaleWorldStartupTelemetryPhase $context 'secret@example.test' -Result 'ok'
    Write-ScaleWorldStartupTelemetryPhase $context 'valid_label' -Result 'raw secret value'
    Assert-Telemetry ((Get-Item -LiteralPath $context.Path).Length -eq $length) 'Invalid labels/results must not be written.'
    Assert-Telemetry ($null -eq (New-ScaleWorldStartupTelemetryContext -Enabled $true -Role 'stack' -LaunchId 'invalid-id' -JournalDirectory $scratch)) 'Invalid launch IDs must not be accepted.'
    Assert-Telemetry ($null -eq (Resolve-StartupTelemetryLocalPath '\\server\share\startup.log')) 'Telemetry cannot use network paths.'

    $blockedPath = Join-Path $scratch 'not-a-directory'
    [IO.File]::WriteAllText($blockedPath, 'unchanged')
    Assert-Telemetry ($null -eq (New-ScaleWorldStartupTelemetryContext -Enabled $true -Role 'stack' -JournalDirectory $blockedPath)) 'An unwritable directory must disable telemetry without throwing.'
    Assert-Telemetry ([IO.File]::ReadAllText($blockedPath) -eq 'unchanged') 'Telemetry changed its blocking target.'
    $lock = New-Object IO.FileStream($context.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { Write-ScaleWorldStartupTelemetryPhase $context 'config.locked' } finally { $lock.Dispose() }
    Assert-Telemetry ($context.Disabled) 'Locked journal must disable further writes without retries or startup failure.'
    Assert-Telemetry ((Get-Item -LiteralPath $context.Path).Length -eq $length) 'Locked journal was modified.'

    $capped = New-ScaleWorldStartupTelemetryContext -Enabled $true -Role 'metadata' -LaunchId $launchId -JournalDirectory $scratch
    [IO.File]::AppendAllText($capped.Path, ('x' * 65000))
    $cappedLength = (Get-Item -LiteralPath $capped.Path).Length
    Write-ScaleWorldStartupTelemetryPhase $capped 'would_exceed_cap'
    Assert-Telemetry ($capped.Disabled -and (Get-Item -LiteralPath $capped.Path).Length -eq $cappedLength) 'The write cap must disable telemetry without truncating earlier evidence.'

    $fixture = Join-Path $scratch 'midnight.cmd.log'
    $header = [ordered]@{schemaVersion=1;kind='begin';launchId=$launchId;contextId='fixture';role='stack';clockBasis='cmd-local-wall-clock';utcBase='2026-10-11T22:59:59.9500000Z';localTimeBase='23:59:59.95'}
    [IO.File]::WriteAllText($fixture, ($header | ConvertTo-Json -Compress) + "`nconfig_ready|23:59:59.99|0`nunreal_dispatch| 0:00:00,03|0`n")
    $normalized = Read-ScaleWorldStartupCmdJournal $fixture
    Assert-Telemetry ($normalized.Status -eq 'readable' -and !$normalized.Ended -and $normalized.Records.Count -eq 2) 'An interrupted CMD journal must normalize without End.'
    Assert-Telemetry ($normalized.Records[1].elapsedMs -eq 80 -and $normalized.Records[1].durationSincePreviousPhaseMs -eq 40) 'Midnight/centisecond rollover was measured incorrectly.'
    Assert-Telemetry ($normalized.Records[1].utc -eq '2026-10-11T23:00:00.0300000Z') 'CMD phase UTC was not reconstructed from its own header.'
    $header.utcBase = '2026-10-11T12:00:00.0000000Z'; $header.localTimeBase = '12:00:00.00'
    [IO.File]::WriteAllText($fixture, ($header | ConvertTo-Json -Compress) + "`none|12:00:01.00|0`ntwo|12:00:00.50|1`n")
    $regressed = Read-ScaleWorldStartupCmdJournal $fixture
    Assert-Telemetry ($regressed.Status -eq 'clock-regression' -and $regressed.Records[1].timingUncertain -and $null -eq $regressed.Records[1].utc) 'A clock regression must not masquerade as a 24-hour phase.'
    [IO.File]::AppendAllText($fixture, "bad@example.test|12:00:01.00|0`n")
    Assert-Telemetry ((Read-ScaleWorldStartupCmdJournal $fixture).Status -eq 'invalid') 'Invalid raw labels must fail diagnostic parsing.'

    $helper = Join-Path $PSScriptRoot 'startup_telemetry.ps1'
    for ($worker = 0; $worker -lt 2; $worker++) {
        $jobs += Start-Job -ScriptBlock {
            param($Helper, $Directory, $LaunchId)
            . $Helper
            $c = New-ScaleWorldStartupTelemetryContext -Enabled $true -Role 'metadata' -JournalDirectory $Directory -LaunchId $LaunchId
            for ($phase = 0; $phase -lt 10; $phase++) { Write-ScaleWorldStartupTelemetryPhase $c ('step_' + $phase) }
            $c.Path
        } -ArgumentList $helper, $scratch, $launchId
    }
    $paths = @($jobs | Wait-Job | Receive-Job)
    Assert-Telemetry ($paths.Count -eq 2 -and $paths[0] -ne $paths[1]) 'Concurrent contexts cannot share a writer file.'
    foreach ($path in $paths) {
        $workerRecords = @([IO.File]::ReadAllLines($path) | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Telemetry ($workerRecords.Count -eq 11 -and $workerRecords[0].launchId -eq $launchId) 'Concurrent journal lost or mixed records.'
    }
    $originalEnabled = $env:SCALEWORLD_STARTUP_TELEMETRY_ENABLED
    $originalInstallBase = $env:SCALEWORLD_INSTALL_BASE
    try {
        $env:SCALEWORLD_STARTUP_TELEMETRY_ENABLED = 'true'
        $env:SCALEWORLD_INSTALL_BASE = $scratch
        $commandHelper = Join-Path $PSScriptRoot 'startup_telemetry_command.ps1'
        $beginDurations = @()
        for ($trial = 0; $trial -lt 3; $trial++) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $exports = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $commandHelper -Action Begin -Role stack -Mode normal)
            $timer.Stop(); $beginDurations += $timer.Elapsed.TotalMilliseconds
            Assert-Telemetry ($LASTEXITCODE -eq 0 -and $exports.Count -eq 4) 'Begin CLI must only emit its four typed assignments.'
            $phasePath = ($exports | Where-Object { $_ -like 'SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE=*' }).Substring('SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE='.Length)
            Assert-Telemetry ([IO.File]::Exists($phasePath)) 'Begin must persist metadata before exporting a writer path.'
            Assert-Telemetry ((Read-ScaleWorldStartupCmdJournal $phasePath).Status -eq 'readable') 'The Begin header is independently parsable.'
        }
        $mean = [Math]::Round(($beginDurations | Measure-Object -Average).Average, 3)
        $maximum = [Math]::Round(($beginDurations | Measure-Object -Maximum).Maximum, 3)
        $phaseContext = New-ScaleWorldStartupTelemetryContext -Enabled $true -Role 'metadata' -LaunchId $launchId -JournalDirectory $scratch
        $timer = [Diagnostics.Stopwatch]::StartNew()
        for ($trial = 0; $trial -lt 50; $trial++) { Write-ScaleWorldStartupTelemetryPhase $phaseContext 'measured_phase' }
        $timer.Stop()
        Write-Output ('Measured local diagnostics overhead: Begin PowerShell process mean={0}ms max={1}ms (3 runs); phase append mean={2}ms (50 calls).' -f $mean,$maximum,[Math]::Round($timer.Elapsed.TotalMilliseconds/50,3))
    } finally {
        $env:SCALEWORLD_STARTUP_TELEMETRY_ENABLED = $originalEnabled
        $env:SCALEWORLD_INSTALL_BASE = $originalInstallBase
    }
    Write-Output 'Startup telemetry tests passed: append preservation, monotonic duration, redaction, invalid input, nonfatal I/O, concurrency, interrupted journal and midnight/clock regression.'
} finally {
    if ($jobs.Count -gt 0) { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if ($resolvedScratch.StartsWith($scratchBase, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedScratch)) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
