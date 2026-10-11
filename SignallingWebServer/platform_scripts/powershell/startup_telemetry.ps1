# Best-effort startup diagnostics. Never use this journal as lifecycle authority.
# Dot-source once inside an existing PowerShell startup process; no network work,
# retry, lock wait, durable flush or raw command line belongs in this helper.

function Test-ScaleWorldStartupTelemetryEnabled {
    return $env:SCALEWORLD_STARTUP_TELEMETRY_ENABLED -match '^(?i:true|1)$'
}

function Test-StartupTelemetryLabel {
    param([string]$Value)
    return $Value -cmatch '^[a-z][a-z0-9_.-]{0,63}$'
}

function Resolve-StartupTelemetryLocalPath {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^\s*(\\\\|//|[a-z]+://)' -or
            $Path.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) { return $null }
        return [IO.Path]::GetFullPath($Path)
    } catch { return $null }
}

function Add-StartupTelemetryLine {
    param([string]$Path, [string]$Line)
    $stream = $null
    try {
        # Every context owns a distinct file. Sharing reads allows live observation;
        # concurrent writers never share this append offset or wait for one another.
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Line + "`n")
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        if ($stream.Length + $bytes.Length -gt 65536) { return $false }
        $stream.Write($bytes, 0, $bytes.Length)
        return $true
    } catch { return $false }
    finally { if ($stream) { try { $stream.Dispose() } catch { } } }
}

function Get-StartupTelemetryRecoveryObservation {
    param([string]$StatePath)
    try {
        $path = Resolve-StartupTelemetryLocalPath $StatePath
        if (!$path) { return @{ status = 'unknown'; required = $null } }
        if (![IO.File]::Exists($path)) { return @{ status = 'missing'; required = $null } }
        if ((New-Object IO.FileInfo($path)).Length -gt 65536) { return @{ status = 'unreadable'; required = $null } }
        $snapshot = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        $required = $snapshot.commercialRecoveryRequired
        if ($null -ne $required -and $required -isnot [bool]) { return @{ status = 'unreadable'; required = $null } }
        return @{ status = 'readable'; required = ($required -eq $true) }
    } catch { return @{ status = 'unreadable'; required = $null } }
}

function New-ScaleWorldStartupTelemetryContext {
    param(
        [string]$Role,
        [string]$Mode = 'normal',
        [string]$JournalDirectory,
        [string]$LaunchId = $env:SCALEWORLD_STARTUP_TELEMETRY_LAUNCH_ID,
        [string]$ParentLaunchId,
        [string]$RecoveryStatePath,
        [int]$LauncherPid = 0,
        [bool]$Enabled = (Test-ScaleWorldStartupTelemetryEnabled),
        [switch]$CmdJournal
    )
    try {
        if (!$Enabled -or $Role -notin @('stack','wilbur','instance-config','metadata','service-class') -or
            $Mode -notin @('normal','recovery','validation')) { return $null }
        if (!$JournalDirectory) {
            $installBase = $env:SCALEWORLD_INSTALL_BASE
            if (!$installBase) { $installBase = 'C:\PixelStreaming' }
            $JournalDirectory = Join-Path $installBase 'diagnostics\startup'
        }
        $directory = Resolve-StartupTelemetryLocalPath $JournalDirectory
        if (!$directory) { return $null }
        $parsedId = [guid]::Empty
        if ($LaunchId) {
            if (![guid]::TryParse($LaunchId, [ref]$parsedId)) { return $null }
        } else { $parsedId = [guid]::NewGuid() }
        $parentId = [guid]::Empty
        $parent = if ([guid]::TryParse($ParentLaunchId, [ref]$parentId)) { $parentId.ToString('D') } else { $null }
        $contextId = [guid]::NewGuid().ToString('N')
        $timestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $utc = [DateTime]::UtcNow
        $local = [DateTime]::Now
        $recovery = Get-StartupTelemetryRecoveryObservation $RecoveryStatePath
        $extension = if ($CmdJournal) { '.cmd.log' } else { '.jsonl' }
        $path = Join-Path $directory ($parsedId.ToString('N') + '.' + $Role + '.' + $contextId + $extension)
        $header = [ordered]@{
            schemaVersion = 1; kind = 'begin'; launchId = $parsedId.ToString('D'); parentLaunchId = $parent
            contextId = $contextId; role = $Role; mode = $Mode; writerPid = $PID; launcherPid = $LauncherPid
            utcBase = $utc.ToString('o'); localTimeBase = $local.ToString('HH:mm:ss.ff', [Globalization.CultureInfo]::InvariantCulture)
            localUtcOffsetMinutes = [int][TimeZoneInfo]::Local.GetUtcOffset($local).TotalMinutes
            clockBasis = $(if ($CmdJournal) { 'cmd-local-wall-clock' } else { 'stopwatch' })
            stopwatchTimestamp = $timestamp; stopwatchFrequency = [Diagnostics.Stopwatch]::Frequency
            recoveryStateStatus = $recovery.status; commercialRecoveryRequired = $recovery.required
        }
        [void][IO.Directory]::CreateDirectory($directory)
        if (!(Add-StartupTelemetryLine $path ($header | ConvertTo-Json -Compress))) { return $null }
        return [pscustomobject]@{ Path = $path; Header = $header; StartedTimestamp = $timestamp; Disabled = $false; PhaseCount = 0 }
    } catch { return $null }
}

function Write-ScaleWorldStartupTelemetryPhase {
    param($Context, [string]$Phase, [string]$Result = 'ok', [long]$StartedTimestamp = 0, [Nullable[int]]$ExitCode)
    try {
        if (!$Context -or $Context.Disabled -or !(Test-StartupTelemetryLabel $Phase) -or
            $Result -notin @('ok','failed','skipped','started','unknown')) { return }
        if ($Context.PhaseCount -ge 511) { $Context.Disabled = $true; return }
        $now = [Diagnostics.Stopwatch]::GetTimestamp()
        $duration = $null
        if ($StartedTimestamp -gt 0 -and $StartedTimestamp -le $now) {
            $duration = [Math]::Round(($now - $StartedTimestamp) * 1000.0 / [Diagnostics.Stopwatch]::Frequency, 3)
        }
        $record = [ordered]@{
            schemaVersion = 1; kind = 'phase'; launchId = $Context.Header.launchId; contextId = $Context.Header.contextId
            role = $Context.Header.role; writerPid = $PID; utc = [DateTime]::UtcNow.ToString('o'); phase = $Phase
            result = $Result; exitCode = $ExitCode; clockBasis = 'stopwatch'
            elapsedMs = [Math]::Round(($now - $Context.StartedTimestamp) * 1000.0 / [Diagnostics.Stopwatch]::Frequency, 3)
            durationMs = $duration
        }
        if (!(Add-StartupTelemetryLine $Context.Path ($record | ConvertTo-Json -Compress))) { $Context.Disabled = $true }
        else { $Context.PhaseCount++ }
    } catch { }
}

function ConvertFrom-StartupTelemetryClock {
    param([string]$Value)
    if ($Value.Trim() -notmatch '^(\d{1,2}):(\d{2}):(\d{2})[.,](\d{2})$') { return $null }
    $hour = [int]$Matches[1]; $minute = [int]$Matches[2]; $second = [int]$Matches[3]; $centisecond = [int]$Matches[4]
    if ($hour -gt 23 -or $minute -gt 59 -or $second -gt 59) { return $null }
    return ($hour * 3600 + $minute * 60 + $second + $centisecond / 100.0)
}

function Read-ScaleWorldStartupCmdJournal {
    param([string]$Path)
    # A killed launcher still leaves a self-contained header + raw phase journal.
    # UTC and durations reconstructed from CMD time are explicitly wall-clock
    # estimates, not monotonic measurements. Never silently turn regressions into a day.
    try {
        $localPath = Resolve-StartupTelemetryLocalPath $Path
        if (!$localPath -or ![IO.File]::Exists($localPath)) { return [pscustomobject]@{ Status = 'missing'; Records = @() } }
        if ((New-Object IO.FileInfo($localPath)).Length -gt 65536) { return [pscustomobject]@{ Status = 'oversize'; Records = @() } }
        $lines = [IO.File]::ReadAllLines($localPath)
        if ($lines.Count -eq 0 -or $lines.Count -gt 512) { return [pscustomobject]@{ Status = 'invalid'; Records = @() } }
        $header = $lines[0] | ConvertFrom-Json -ErrorAction Stop
        $id = [guid]::Empty
        $baseClock = ConvertFrom-StartupTelemetryClock ([string]$header.localTimeBase)
        $baseUtc = [DateTimeOffset]::MinValue
        if ($header.schemaVersion -ne 1 -or $header.kind -ne 'begin' -or $header.clockBasis -ne 'cmd-local-wall-clock' -or
            !(Test-StartupTelemetryLabel ([string]$header.role)) -or
            ![guid]::TryParse([string]$header.launchId, [ref]$id) -or $null -eq $baseClock -or
            ![DateTimeOffset]::TryParse([string]$header.utcBase, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$baseUtc)) {
            return [pscustomobject]@{ Status = 'invalid'; Records = @() }
        }
        $records = New-Object 'Collections.Generic.List[object]'
        $day = 0; $previousClock = $baseClock; $previousElapsed = 0.0; $uncertain = $false; $ended = $false
        foreach ($line in ($lines | Select-Object -Skip 1)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith('{')) {
                $end = $line | ConvertFrom-Json -ErrorAction Stop
                if ($end.kind -eq 'end' -and $end.contextId -eq $header.contextId) { $ended = $true }
                continue
            }
            $fields = $line.Split('|')
            if ($fields.Count -ne 3 -or !(Test-StartupTelemetryLabel $fields[0]) -or
                $fields[2] -notmatch '^-?\d{1,10}$') {
                return [pscustomobject]@{ Status = 'invalid'; Records = @() }
            }
            $clock = ConvertFrom-StartupTelemetryClock $fields[1]
            $exitCode = 0
            if ($null -eq $clock -or ![int]::TryParse($fields[2], [ref]$exitCode)) {
                return [pscustomobject]@{ Status = 'invalid'; Records = @() }
            }
            if ($clock -lt $previousClock) {
                if (($previousClock - $clock) -gt 43200) { $day += 86400 } else { $uncertain = $true }
            }
            $elapsed = $day + $clock - $baseClock
            $records.Add([pscustomobject]@{
                kind = 'phase'; launchId = $id.ToString('D'); contextId = [string]$header.contextId; role = [string]$header.role
                phase = $fields[0]; exitCode = $exitCode; clockBasis = 'cmd-local-wall-clock'; timingUncertain = $uncertain
                utc = $(if (!$uncertain) { $baseUtc.AddSeconds($elapsed).UtcDateTime.ToString('o') } else { $null })
                elapsedMs = $(if (!$uncertain) { [Math]::Round($elapsed * 1000, 3) } else { $null })
                durationSincePreviousPhaseMs = $(if (!$uncertain) { [Math]::Round(($elapsed - $previousElapsed) * 1000, 3) } else { $null })
            })
            $previousClock = $clock; $previousElapsed = $elapsed
        }
        return [pscustomobject]@{ Status = $(if ($uncertain) { 'clock-regression' } else { 'readable' }); Ended = $ended; Records = $records.ToArray() }
    } catch { return [pscustomobject]@{ Status = 'invalid'; Records = @() } }
}
