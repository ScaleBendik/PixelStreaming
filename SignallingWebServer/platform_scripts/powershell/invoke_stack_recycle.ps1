[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$RecycleMarkerPath = '',
    [int]$SourcePid = 0,
    [int]$WaitBeforeTerminateMilliseconds = 250,
    [int]$WaitForWilburTimeoutSeconds = 120,
    [int]$WaitForStreamerHealthTimeoutSeconds = 120,
    [int]$StreamerHealthMaxStaleSeconds = 30,
    [string]$StreamerHealthPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CurrentProcessId = $PID

function Resolve-StackRecycleScriptRoot {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $PSScriptRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        return Split-Path -Parent $PSCommandPath
    }

    if ($MyInvocation.MyCommand.Path) {
        return Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    throw 'Unable to resolve stack recycle script root.'
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path (Resolve-StackRecycleScriptRoot) '..\..')).Path
}

$script:RecycleLogPath = Join-Path $RepoRoot 'state\stack-recycle.log'
$script:ScaleWorldProcessHelperPath = Join-Path (Resolve-StackRecycleScriptRoot) 'scaleworld_process_helpers.ps1'
if (-not (Test-Path -LiteralPath $script:ScaleWorldProcessHelperPath)) {
    throw "ScaleWorld process helper '$script:ScaleWorldProcessHelperPath' was not found."
}
. $script:ScaleWorldProcessHelperPath
if ([string]::IsNullOrWhiteSpace($StreamerHealthPath)) {
    $resolvedStreamerHealthPath = Join-Path $RepoRoot 'state\streamer-health.json'
} elseif ([System.IO.Path]::IsPathRooted($StreamerHealthPath)) {
    $resolvedStreamerHealthPath = $StreamerHealthPath
} else {
    $resolvedStreamerHealthPath = Join-Path $RepoRoot $StreamerHealthPath
}

function Write-RecycleLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "[$timestamp] [$Level] [stack-recycle] $Message"
    Write-Host $line

    try {
        $directory = Split-Path -Parent $script:RecycleLogPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        Add-Content -LiteralPath $script:RecycleLogPath -Value $line -Encoding UTF8
    } catch {
        # best effort only
    }
}

function Get-RecycleProcessMatches {
    param(
        [string]$NamePattern,
        [string[]]$CommandLinePatterns
    )

    $resolvedCommandLinePatterns = @(
        $CommandLinePatterns | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    return @(
        Get-CimInstance Win32_Process | Where-Object {
            if ($_.ProcessId -eq $script:CurrentProcessId) {
                return $false
            }

            $hasNamePattern = -not [string]::IsNullOrWhiteSpace($NamePattern)
            if ($hasNamePattern -and -not ([string]$_.Name -like $NamePattern)) {
                return $false
            }

            if ($resolvedCommandLinePatterns.Count -eq 0) {
                return $hasNamePattern
            }

            $commandLine = [string]$_.CommandLine
            foreach ($pattern in $resolvedCommandLinePatterns) {
                if ($commandLine -like $pattern) {
                    return $true
                }
            }

            return $false
        }
    )
}

function Stop-RecycleProcessMatches {
    param(
        [string]$Label,
        [string]$NamePattern,
        [string[]]$CommandLinePatterns,
        [System.Collections.Generic.List[string]]$StoppedProcesses
    )

    $matches = @(Get-RecycleProcessMatches -NamePattern $NamePattern -CommandLinePatterns $CommandLinePatterns)
    Stop-RecycleProcessObjects -Label $Label -Matches $matches -StoppedProcesses $StoppedProcesses
}

function Format-RecycleProcessSummary {
    param([object]$Process)

    $path = [string]$Process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($path)) {
        return ("{0} (PID={1})" -f $Process.Name, $Process.ProcessId)
    }

    return ("{0} (PID={1}, Path={2})" -f $Process.Name, $Process.ProcessId, $path)
}

function Stop-RecycleProcessObjects {
    param(
        [string]$Label,
        [object[]]$Matches,
        [System.Collections.Generic.List[string]]$StoppedProcesses
    )

    foreach ($match in @($Matches)) {
        Write-RecycleLog "Stopping $Label process $(Format-RecycleProcessSummary -Process $match)."
        try {
            Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
            $StoppedProcesses.Add(($Label + ':' + $match.ProcessId + ':' + $match.Name)) | Out-Null
        } catch {
            $remaining = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $match.ProcessId) -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($remaining) {
                throw
            }

            Write-RecycleLog "$Label process $($match.Name) (PID=$($match.ProcessId)) exited before it could be stopped." 'WARN'
        }
    }
}

function Get-RecycleUnrealProcessMatches {
    param([object]$Matcher)

    return @(Get-ScaleWorldRuntimeProcesses -ExcludeProcessIds @($script:CurrentProcessId) -Matcher $Matcher)
}

function Stop-RecycleUnrealProcesses {
    param(
        [object]$Matcher,
        [System.Collections.Generic.List[string]]$StoppedProcesses
    )

    $matches = @(Get-RecycleUnrealProcessMatches -Matcher $Matcher)
    Stop-RecycleProcessObjects -Label 'unreal' -Matches $matches -StoppedProcesses $StoppedProcesses
}

function Resolve-RecycleSourcePid {
    param(
        [int]$ExplicitSourcePid,
        [string]$MarkerPath
    )

    if ($ExplicitSourcePid -gt 0) {
        Write-RecycleLog "Using explicit recycle source PID $ExplicitSourcePid."
        return $ExplicitSourcePid
    }

    if ([string]::IsNullOrWhiteSpace($MarkerPath) -or -not (Test-Path -LiteralPath $MarkerPath)) {
        return 0
    }

    try {
        $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
        $markerSourcePid = 0
        if ($null -ne $marker -and $null -ne $marker.sourcePid) {
            $markerSourcePid = [int]$marker.sourcePid
        }

        if ($markerSourcePid -gt 0) {
            Write-RecycleLog "Resolved recycle source PID $markerSourcePid from marker '$MarkerPath'."
            return $markerSourcePid
        }
    } catch {
        Write-RecycleLog "Failed to resolve recycle source PID from marker '$MarkerPath': $($_.Exception.Message)" 'WARN'
    }

    return 0
}

function Stop-RecycleSourceProcess {
    param(
        [int]$ProcessId,
        [System.Collections.Generic.List[string]]$StoppedProcesses
    )

    if ($ProcessId -le 0 -or $ProcessId -eq $script:CurrentProcessId) {
        return
    }

    $match = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) | Select-Object -First 1
    if (-not $match) {
        Write-RecycleLog "Recycle source PID $ProcessId was not found."
        return
    }

    Write-RecycleLog "Stopping recycle source process $($match.Name) (PID=$ProcessId)."
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        $StoppedProcesses.Add(('source:' + $ProcessId + ':' + $match.Name)) | Out-Null
    } catch {
        $remaining = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($remaining) {
            throw
        }

        Write-RecycleLog "Recycle source process $($match.Name) (PID=$ProcessId) exited before it could be stopped." 'WARN'
    }
}

function Wait-ForWilbur {
    param([int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $wilbur = Get-CimInstance Win32_Process | Where-Object {
            ($_.Name -ieq 'node.exe' -and ([string]$_.CommandLine) -like '*index.js*') -or
            ($_.Name -ieq 'cmd.exe' -and ([string]$_.CommandLine) -like '*start_dev_turn.bat*')
        } | Select-Object -First 1

        if ($wilbur) {
            Write-RecycleLog "Detected Wilbur process $($wilbur.Name) (PID=$($wilbur.ProcessId))."
            return $true
        }

        Start-Sleep -Seconds 3
    }

    return $false
}

function Wait-ForWilburReadiness {
    param(
        [int]$TimeoutSeconds,
        [string]$HostName = '127.0.0.1',
        [int]$Port = 8888
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000)) {
                $client.EndConnect($async)
                $client.Close()
                Write-RecycleLog "Confirmed Wilbur readiness on ${HostName}:${Port}."
                return $true
            }
        } catch {
            # keep waiting
        } finally {
            if ($client) {
                $client.Close()
            }
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Wait-ForProcessAbsence {
    param(
        [string]$Label,
        [string]$NamePattern,
        [string[]]$CommandLinePatterns,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $matches = @(Get-RecycleProcessMatches -NamePattern $NamePattern -CommandLinePatterns $CommandLinePatterns)
        if ($matches.Count -eq 0) {
            Write-RecycleLog "Confirmed $Label shutdown before restart."
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    $remaining = @(Get-RecycleProcessMatches -NamePattern $NamePattern -CommandLinePatterns $CommandLinePatterns)
    if ($remaining.Count -gt 0) {
        $summary = ($remaining | ForEach-Object { Format-RecycleProcessSummary -Process $_ }) -join ', '
        Write-RecycleLog "$Label processes still running after shutdown wait: $summary" 'WARN'
    }

    return $remaining.Count -eq 0
}

function Wait-ForUnrealAbsence {
    param(
        [object]$Matcher,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $matches = @(Get-RecycleUnrealProcessMatches -Matcher $Matcher)
        if ($matches.Count -eq 0) {
            Write-RecycleLog 'Confirmed unreal shutdown before restart.'
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    $remaining = @(Get-RecycleUnrealProcessMatches -Matcher $Matcher)
    if ($remaining.Count -gt 0) {
        $summary = ($remaining | ForEach-Object { Format-RecycleProcessSummary -Process $_ }) -join ', '
        Write-RecycleLog "unreal processes still running after shutdown wait: $summary" 'WARN'
    }

    return $remaining.Count -eq 0
}

function Wait-ForUnrealPresence {
    param(
        [object]$Matcher,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $matches = @(Get-RecycleUnrealProcessMatches -Matcher $Matcher)
        if ($matches.Count -gt 0) {
            $summary = ($matches | ForEach-Object { Format-RecycleProcessSummary -Process $_ }) -join ', '
            Write-RecycleLog "Detected Unreal runtime after restart: $summary."
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    Write-RecycleLog "Unreal runtime did not appear within $TimeoutSeconds seconds after restart." 'WARN'
    return $false
}

function Get-RecycleSnapshotPropertyValue {
    param(
        [object]$Snapshot,
        [string]$Name
    )

    if ($null -eq $Snapshot) {
        return $null
    }

    $property = $Snapshot.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Read-RecycleStreamerHealthSnapshot {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            State = 'missing'
            Snapshot = $null
            Error = $null
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{
                State = 'missing'
                Snapshot = $null
                Error = $null
            }
        }

        return [pscustomobject]@{
            State = 'ok'
            Snapshot = ($raw | ConvertFrom-Json -ErrorAction Stop)
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            State = 'invalid'
            Snapshot = $null
            Error = $_.Exception.Message
        }
    }
}

function Wait-ForStreamerHealthReadiness {
    param(
        [string]$Path,
        [int]$TimeoutSeconds,
        [int]$MaxStaleSeconds,
        [DateTimeOffset]$NotBeforeUtc
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSummary = $null
    while ((Get-Date) -lt $deadline) {
        $result = Read-RecycleStreamerHealthSnapshot -Path $Path
        $summary = $null

        if ($result.State -eq 'ok') {
            $snapshot = $result.Snapshot
            $status = [string](Get-RecycleSnapshotPropertyValue -Snapshot $snapshot -Name 'status')
            $reason = [string](Get-RecycleSnapshotPropertyValue -Snapshot $snapshot -Name 'reason')
            $healthy = $false
            $healthyValue = Get-RecycleSnapshotPropertyValue -Snapshot $snapshot -Name 'healthy'
            if ($null -ne $healthyValue) {
                try {
                    $healthy = [bool]$healthyValue
                } catch {
                    $healthy = $false
                }
            }

            $updatedAtUtc = $null
            $updatedAtText = [string](Get-RecycleSnapshotPropertyValue -Snapshot $snapshot -Name 'updatedAtUtc')
            if (-not [string]::IsNullOrWhiteSpace($updatedAtText)) {
                try {
                    $updatedAtUtc = [DateTimeOffset]::Parse(
                        $updatedAtText,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    )
                } catch {
                    $updatedAtUtc = $null
                }
            }

            $isFresh = $false
            $healthAgeSeconds = $null
            if ($updatedAtUtc) {
                $healthAgeSeconds = ([DateTimeOffset]::UtcNow - $updatedAtUtc).TotalSeconds
                $isFresh = $updatedAtUtc -ge $NotBeforeUtc -and $healthAgeSeconds -le $MaxStaleSeconds
            }

            if ($isFresh -and $healthy -and $status.Equals('ready', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-RecycleLog "Confirmed streamer runtime readiness from health snapshot status=$status reason=$reason updatedAtUtc=$updatedAtText."
                return $true
            }

            $ageText = if ($null -eq $healthAgeSeconds) { 'unknown' } else { '{0:N0}s' -f $healthAgeSeconds }
            $summary = "streamer health not ready (state=ok status=$status reason=$reason healthy=$healthy age=$ageText updatedAtUtc=$updatedAtText)"
            if ($updatedAtUtc -and $updatedAtUtc -lt $NotBeforeUtc) {
                $summary = "$summary; snapshot predates recycle restart"
            }
        } elseif ($result.State -eq 'missing') {
            $summary = "streamer health file missing ($Path)"
        } else {
            $summary = "streamer health file invalid ($($result.Error))"
        }

        if ($summary -ne $lastSummary) {
            Write-RecycleLog $summary
            $lastSummary = $summary
        }

        Start-Sleep -Seconds 1
    }

    $timeoutSummary = if ([string]::IsNullOrWhiteSpace($lastSummary)) { 'no streamer health snapshot observed' } else { $lastSummary }
    Write-RecycleLog "Streamer health did not reach ready within $TimeoutSeconds seconds: $timeoutSummary" 'WARN'
    return $false
}
$stackLauncher = Join-Path $RepoRoot 'platform_scripts\cmd\start_streamer_stack.bat'
$unrealExecutableName = if (-not [string]::IsNullOrWhiteSpace($env:SCALEWORLD_EXECUTABLE_NAME)) {
    [System.IO.Path]::GetFileName($env:SCALEWORLD_EXECUTABLE_NAME)
} else {
    'ScaleWorld.exe'
}
$unrealInstallRoot = if (-not [string]::IsNullOrWhiteSpace($env:SCALEWORLD_INSTALL_ROOT)) {
    $env:SCALEWORLD_INSTALL_ROOT
} else {
    'C:\PixelStreaming\WindowsNoEditor'
}
$unrealRuntimeProcessPattern = if (-not [string]::IsNullOrWhiteSpace($env:SCALEWORLD_RUNTIME_PROCESS_PATTERN)) {
    $env:SCALEWORLD_RUNTIME_PROCESS_PATTERN
} else {
    ''
}
$scaleWorldRuntimeMatcher = Get-ScaleWorldRuntimeProcessMatcher -InstallRoot $unrealInstallRoot -ExecutableName $unrealExecutableName -RuntimeProcessPattern $unrealRuntimeProcessPattern -IncludeLauncherExecutable $true
$scaleWorldStartupMatcher = Get-ScaleWorldRuntimeProcessMatcher -InstallRoot $unrealInstallRoot -ExecutableName $unrealExecutableName -RuntimeProcessPattern $unrealRuntimeProcessPattern -IncludeLauncherExecutable $false

try {
    $recycleLogDirectory = Split-Path -Parent $script:RecycleLogPath
    if (-not (Test-Path -LiteralPath $recycleLogDirectory)) {
        New-Item -ItemType Directory -Path $recycleLogDirectory -Force | Out-Null
    }

    Set-Content -LiteralPath $script:RecycleLogPath -Value '' -NoNewline -Encoding UTF8
} catch {
    # best effort only; Write-RecycleLog will still append if reset fails
}
try {
    Write-RecycleLog "Resolved recycle repo root to '$RepoRoot'."
    Write-RecycleLog "Recycle log path is '$script:RecycleLogPath'."
    Write-RecycleLog "Resolved stack launcher to '$stackLauncher'."
    Write-RecycleLog "Resolved streamer health path to '$resolvedStreamerHealthPath'."
    Write-RecycleLog "Resolved Unreal matcher installRoot='$($scaleWorldRuntimeMatcher.InstallRoot)' namePatterns='$($scaleWorldRuntimeMatcher.NamePatterns -join ';')' commandLinePatterns='$($scaleWorldRuntimeMatcher.CommandLinePatterns -join ';')'."
    Write-RecycleLog "Resolved Unreal startup matcher installRoot='$($scaleWorldStartupMatcher.InstallRoot)' namePatterns='$($scaleWorldStartupMatcher.NamePatterns -join ';')' commandLinePatterns='$($scaleWorldStartupMatcher.CommandLinePatterns -join ';')'."

    if (-not (Test-Path -LiteralPath $stackLauncher)) {
        throw "Stack launcher '$stackLauncher' was not found."
    }

    if (-not [string]::IsNullOrWhiteSpace($RecycleMarkerPath)) {
        Write-RecycleLog "Using recycle marker '$RecycleMarkerPath'."
    }

    if ($WaitBeforeTerminateMilliseconds -gt 0) {
        Write-RecycleLog "Waiting ${WaitBeforeTerminateMilliseconds}ms before terminating the current stack."
        Start-Sleep -Milliseconds $WaitBeforeTerminateMilliseconds
    }

    $sourcePidToStop = Resolve-RecycleSourcePid -ExplicitSourcePid $SourcePid -MarkerPath $RecycleMarkerPath
    $stoppedProcesses = [System.Collections.Generic.List[string]]::new()
    Stop-RecycleProcessMatches -Label 'watchdog' -NamePattern 'powershell.exe' -CommandLinePatterns @('*watchdog.ps1*') -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'watchdog-launcher' -NamePattern 'cmd.exe' -CommandLinePatterns @('*start_watchdog.bat*') -StoppedProcesses $stoppedProcesses
    Stop-RecycleSourceProcess -ProcessId $sourcePidToStop -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePatterns @('*index.js*') -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'wilbur-launcher' -NamePattern 'cmd.exe' -CommandLinePatterns @('*start_dev_turn.bat*') -StoppedProcesses $stoppedProcesses
    Stop-RecycleUnrealProcesses -Matcher $scaleWorldRuntimeMatcher -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'unreal-wrapper' -NamePattern 'powershell.exe' -CommandLinePatterns @('*start_scaleworld.ps1*') -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'unreal-launcher' -NamePattern 'cmd.exe' -CommandLinePatterns @('*start_unreal.bat*') -StoppedProcesses $stoppedProcesses

    if (-not (Wait-ForProcessAbsence -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePatterns @('*index.js*') -TimeoutSeconds 15)) {
        throw 'Wilbur did not fully stop before stack recycle restart.'
    }

    if (-not (Wait-ForUnrealAbsence -Matcher $scaleWorldRuntimeMatcher -TimeoutSeconds 20)) {
        throw 'Unreal did not fully stop before stack recycle restart.'
    }

    Write-RecycleLog 'Restarting streamer stack directly via start_streamer_stack.bat --recovery.'
    $stackRestartStartedAtUtc = [DateTimeOffset]::UtcNow
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}" --recovery' -f $stackLauncher) -WorkingDirectory (Split-Path -Parent $stackLauncher) -WindowStyle Hidden | Out-Null

    $stackDetected =
        (Wait-ForWilbur -TimeoutSeconds $WaitForWilburTimeoutSeconds) -and
        (Wait-ForWilburReadiness -TimeoutSeconds $WaitForWilburTimeoutSeconds) -and
        (Wait-ForUnrealPresence -Matcher $scaleWorldStartupMatcher -TimeoutSeconds $WaitForWilburTimeoutSeconds)

    if (-not $stackDetected) {
        throw "Stack recycle did not reach Wilbur readiness and Unreal runtime presence within $WaitForWilburTimeoutSeconds seconds."
    }

    if (-not (Wait-ForStreamerHealthReadiness -Path $resolvedStreamerHealthPath -TimeoutSeconds $WaitForStreamerHealthTimeoutSeconds -MaxStaleSeconds $StreamerHealthMaxStaleSeconds -NotBeforeUtc $stackRestartStartedAtUtc)) {
        throw "Stack recycle did not reach streamer runtime readiness within $WaitForStreamerHealthTimeoutSeconds seconds."
    }

    $stoppedSummary = if ($stoppedProcesses.Count -gt 0) { $stoppedProcesses -join ', ' } else { '(none)' }
    Write-RecycleLog "Stack recycle completed. Stopped processes: $stoppedSummary"
} catch {
    $message = $_.Exception.Message
    Write-RecycleLog "Stack recycle failed: $message" 'ERROR'
    throw
}
