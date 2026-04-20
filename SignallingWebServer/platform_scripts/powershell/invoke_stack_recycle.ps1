[CmdletBinding()]
param(
    [string]$RepoRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$RecycleMarkerPath = '',
    [int]$WaitBeforeTerminateMilliseconds = 2000,
    [int]$WaitForWilburTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CurrentProcessId = $PID
$script:RecycleLogPath = Join-Path $RepoRoot 'SignallingWebServer\state\stack-recycle.log'

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

function Stop-RecycleProcessMatches {
    param(
        [string]$Label,
        [string]$NamePattern,
        [string]$CommandLinePattern,
        [System.Collections.Generic.List[string]]$StoppedProcesses
    )

    $matches = Get-CimInstance Win32_Process | Where-Object {
        (($NamePattern.Length -gt 0) -and $_.Name -like $NamePattern) -or
        (($CommandLinePattern.Length -gt 0) -and ([string]$_.CommandLine) -like $CommandLinePattern)
    }

    foreach ($match in @($matches)) {
        if ($match.ProcessId -eq $script:CurrentProcessId) {
            continue
        }

        Write-RecycleLog "Stopping $Label process $($match.Name) (PID=$($match.ProcessId))."
        Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
        $StoppedProcesses.Add(($Label + ':' + $match.ProcessId + ':' + $match.Name)) | Out-Null
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

$stackLauncher = Join-Path $RepoRoot 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
$unrealProcessPattern = if ([string]::IsNullOrWhiteSpace($env:SCALEWORLD_EXECUTABLE_NAME)) {
    'ScaleWorld*'
} else {
    [System.IO.Path]::GetFileNameWithoutExtension($env:SCALEWORLD_EXECUTABLE_NAME) + '*'
}

try {
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

    $stoppedProcesses = [System.Collections.Generic.List[string]]::new()
    Stop-RecycleProcessMatches -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePattern '*index.js*' -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'wilbur-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_dev_turn.bat*' -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'unreal' -NamePattern $unrealProcessPattern -CommandLinePattern '*start_scaleworld.ps1*' -StoppedProcesses $stoppedProcesses
    Stop-RecycleProcessMatches -Label 'unreal-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_unreal.bat*' -StoppedProcesses $stoppedProcesses

    Start-Sleep -Seconds 1

    Write-RecycleLog 'Restarting streamer stack directly via start_streamer_stack.bat --recovery.'
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}" --recovery' -f $stackLauncher) -WorkingDirectory (Split-Path -Parent $stackLauncher) -WindowStyle Hidden | Out-Null

    $stackDetected =
        (Wait-ForWilbur -TimeoutSeconds $WaitForWilburTimeoutSeconds) -and
        (Wait-ForWilburReadiness -TimeoutSeconds $WaitForWilburTimeoutSeconds)

    if (-not $stackDetected) {
        throw "Stack recycle did not reach Wilbur readiness within $WaitForWilburTimeoutSeconds seconds."
    }

    $stoppedSummary = if ($stoppedProcesses.Count -gt 0) { $stoppedProcesses -join ', ' } else { '(none)' }
    Write-RecycleLog "Stack recycle completed. Stopped processes: $stoppedSummary"
} catch {
    $message = $_.Exception.Message
    Write-RecycleLog "Stack recycle failed: $message" 'ERROR'
    throw
}
