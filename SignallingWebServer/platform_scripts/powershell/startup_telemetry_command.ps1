[CmdletBinding()]
param([string]$Action, [string]$Role = 'stack', [string]$Mode = 'normal', [int]$ResultCode = 0, [switch]$ObserveParentProcess)
# CMD launchers call Begin once and optionally End once. Their phase appends use
# only built-in echo. Caller must save/restore its operation's ERRORLEVEL.
try {
    . (Join-Path $PSScriptRoot 'startup_telemetry.ps1')
    if (!(Test-ScaleWorldStartupTelemetryEnabled)) { exit 0 }
    if ($Action -eq 'Begin') {
        $launcherPid = 0
        # CIM provider startup was measured to add material latency. Parent lookup
        # is optional; zero means unknown, not the current launcher. The writer PID
        # and launch/parent-launch IDs always remain available for correlation.
        if ($ObserveParentProcess) {
            try {
                $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $PID) -OperationTimeoutSec 1 -ErrorAction Stop
                $launcherPid = [int]$process.ParentProcessId
            } catch { }
        }
        $installBase = $env:SCALEWORLD_INSTALL_BASE
        if (!$installBase) { $installBase = 'C:\PixelStreaming' }
        $context = New-ScaleWorldStartupTelemetryContext -Role $Role -Mode $Mode -LaunchId '' `
            -ParentLaunchId $env:SCALEWORLD_STARTUP_TELEMETRY_LAUNCH_ID -LauncherPid $launcherPid -CmdJournal `
            -RecoveryStatePath (Join-Path $installBase 'state\connect-ticket-runtime-state.json')
        # These values are subsequently assigned by CMD. Reject shell metacharacters
        # rather than letting an environment-selected diagnostic path become code.
        if (!$context -or $context.Path -match '["%!&|<>^]') { exit 0 }
        Write-Output ('SCALEWORLD_STARTUP_TELEMETRY_LAUNCH_ID=' + $context.Header.launchId)
        Write-Output ('SCALEWORLD_STARTUP_TELEMETRY_CONTEXT_ID=' + $context.Header.contextId)
        Write-Output ('SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE=' + $context.Path)
        Write-Output ('SCALEWORLD_STARTUP_TELEMETRY_LAUNCHER_PID=' + $launcherPid)
    } elseif ($Action -eq 'End') {
        $path = Resolve-StartupTelemetryLocalPath $env:SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE
        if (!$path -or ![IO.File]::Exists($path) -or (New-Object IO.FileInfo($path)).Length -gt 65536) { exit 0 }
        # ReadLines + Select-Object -First 1 can leave its enumerator holding this
        # file open on Windows PowerShell, preventing the best-effort append.
        # The length cap above bounds this diagnostic-only read to 64 KiB.
        $lines = [IO.File]::ReadAllLines($path)
        if ($lines.Count -eq 0) { exit 0 }
        $header = $lines[0] | ConvertFrom-Json -ErrorAction Stop
        if ($header.kind -ne 'begin' -or $header.contextId -ne $env:SCALEWORLD_STARTUP_TELEMETRY_CONTEXT_ID) { exit 0 }
        $record = [ordered]@{ schemaVersion = 1; kind = 'end'; contextId = $header.contextId
            launchId = $header.launchId; utc = [DateTime]::UtcNow.ToString('o'); writerPid = $PID; exitCode = $ResultCode }
        [void](Add-StartupTelemetryLine $path ($record | ConvertTo-Json -Compress))
    }
} catch { }
exit 0
