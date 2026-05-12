[CmdletBinding()]
param(
    [string]$RepoRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [int]$WaitForWilburTimeoutSeconds = 120,
    [string]$GitTargetRef = $(if ($env:SCALEWORLD_GIT_TARGET_REF) { $env:SCALEWORLD_GIT_TARGET_REF } else { '' }),
    [string]$GitTargetRefParam = $(if ($env:SCALEWORLD_GIT_TARGET_REF_PARAM) { $env:SCALEWORLD_GIT_TARGET_REF_PARAM } else { '' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CurrentProcessId = $PID
$script:CurrentParentProcessId = $null
$script:GoldRefreshLogPath = Join-Path $RepoRoot 'SignallingWebServer\state\gold-refresh.log'

try {
    $currentProcess = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop
    $script:CurrentParentProcessId = [int]$currentProcess.ParentProcessId
} catch {
    $script:CurrentParentProcessId = $null
}

function Write-GoldRefreshLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "[$timestamp] [$Level] [gold-refresh] $Message"
    Write-Host $line

    try {
        $directory = Split-Path -Parent $script:GoldRefreshLogPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        Add-Content -LiteralPath $script:GoldRefreshLogPath -Value $line -Encoding UTF8
    } catch {
        # best-effort only
    }
}

function Stop-GoldProcessMatches {
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
            Write-GoldRefreshLog "Skipping $Label match for current process PID=$($match.ProcessId)." 'WARN'
            continue
        }

        if ($script:CurrentParentProcessId -and $match.ProcessId -eq $script:CurrentParentProcessId) {
            Write-GoldRefreshLog "Skipping $Label match for parent process PID=$($match.ProcessId)." 'WARN'
            continue
        }

        Write-GoldRefreshLog "Stopping $Label process $($match.Name) (PID=$($match.ProcessId))."
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
            Write-GoldRefreshLog "Detected Wilbur process $($wilbur.Name) (PID=$($wilbur.ProcessId))."
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
                Write-GoldRefreshLog "Confirmed Wilbur readiness on ${HostName}:${Port}."
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

function Get-OptionalTextFileValue {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $value = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

$script:goldRefreshStep = 'initializing'
$repoSyncScript = Join-Path $RepoRoot 'SignallingWebServer\platform_scripts\powershell\ensure_repo_current.ps1'
$stackLauncher = Join-Path $RepoRoot 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
$buildStampPath = Join-Path $RepoRoot 'SignallingWebServer\state\repo-build-head.txt'
$wilburDistPath = Join-Path $RepoRoot 'SignallingWebServer\dist\index.js'
$frontendBundlePath = Join-Path $RepoRoot 'SignallingWebServer\www\player.html'

try {
    if (-not (Test-Path -LiteralPath $repoSyncScript)) {
        throw "Repo sync helper '$repoSyncScript' was not found."
    }

    if (-not (Test-Path -LiteralPath $stackLauncher)) {
        throw "Stack launcher '$stackLauncher' was not found."
    }

    $stoppedProcesses = [System.Collections.Generic.List[string]]::new()

    $script:goldRefreshStep = 'preflight_pinned_target'
    Set-Location -LiteralPath $RepoRoot

    if ([string]::IsNullOrWhiteSpace($GitTargetRef) -and [string]::IsNullOrWhiteSpace($GitTargetRefParam)) {
        throw 'Gold refresh requires a pinned git target via -GitTargetRef or -GitTargetRefParam. Upstream refresh is no longer supported.'
    }

    $env:SCALEWORLD_GIT_SYNC_MODE = 'pinned'
    if (-not [string]::IsNullOrWhiteSpace($GitTargetRef)) {
        $env:SCALEWORLD_GIT_TARGET_REF = $GitTargetRef
        Remove-Item Env:SCALEWORLD_GIT_TARGET_REF_PARAM -ErrorAction SilentlyContinue
    } else {
        $env:SCALEWORLD_GIT_TARGET_REF_PARAM = $GitTargetRefParam
        Remove-Item Env:SCALEWORLD_GIT_TARGET_REF -ErrorAction SilentlyContinue
    }

    $script:goldRefreshStep = 'stopping_existing_processes'
    Stop-GoldProcessMatches -Label 'watchdog-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_watchdog.bat*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'watchdog' -NamePattern 'powershell.exe' -CommandLinePattern '*watchdog.ps1*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePattern '*index.js*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'wilbur-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_dev_turn.bat*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'unreal' -NamePattern 'ScaleWorld*' -CommandLinePattern '*start_scaleworld.ps1*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'unreal-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_unreal.bat*' -StoppedProcesses $stoppedProcesses

    Start-Sleep -Seconds 2

    $script:goldRefreshStep = 'repo_sync_and_build_validation'
    $targetDescription = if (-not [string]::IsNullOrWhiteSpace($GitTargetRef)) {
        "explicit target '$GitTargetRef'"
    } else {
        "SSM target parameter '$GitTargetRefParam'"
    }
    Write-GoldRefreshLog "Synchronizing PixelStreaming repo to pinned $targetDescription and validating build outputs."
    $repoSyncArguments = @(
        '-RepoRoot', $RepoRoot,
        '-Mode', 'maintenance',
        '-GitSyncMode', 'pinned'
    )
    if (-not [string]::IsNullOrWhiteSpace($GitTargetRef)) {
        $repoSyncArguments += @('-GitTargetRef', $GitTargetRef)
    }
    if (-not [string]::IsNullOrWhiteSpace($GitTargetRefParam)) {
        $repoSyncArguments += @('-GitTargetRefParam', $GitTargetRefParam)
    }

    & $repoSyncScript @repoSyncArguments
    if ($LASTEXITCODE -ne 0) {
        throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
    }

    $script:goldRefreshStep = 'direct_stack_restart'
    Write-GoldRefreshLog 'Restarting Gold stack directly from the synced checkout.'
    $stackCommand = 'set "STACK_ENABLE_BOOT_GIT_SYNC=false" && set "SCALEWORLD_GIT_SYNC_MODE=pinned"'
    if (-not [string]::IsNullOrWhiteSpace($GitTargetRef)) {
        $stackCommand += (' && set "SCALEWORLD_GIT_TARGET_REF={0}"' -f $GitTargetRef)
    } else {
        $stackCommand += (' && set "SCALEWORLD_GIT_TARGET_REF_PARAM={0}"' -f $GitTargetRefParam)
    }
    $stackCommand += (' && call "{0}"' -f $stackLauncher)
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $stackCommand -WorkingDirectory (Split-Path -Parent $stackLauncher) -WindowStyle Hidden | Out-Null
    $startupMethod = 'direct pinned target'
    $script:goldRefreshStep = 'waiting_for_wilbur_after_direct_restart'
    $stackDetected = (Wait-ForWilbur -TimeoutSeconds $WaitForWilburTimeoutSeconds) -and
        (Wait-ForWilburReadiness -TimeoutSeconds $WaitForWilburTimeoutSeconds)

    if (-not $stackDetected) {
        throw "Gold stack restart did not reach Wilbur readiness within $WaitForWilburTimeoutSeconds seconds."
    }

    $stoppedSummary = if ($stoppedProcesses.Count -gt 0) { $stoppedProcesses -join ', ' } else { '(none)' }
    Write-Output ('Stopped processes: ' + $stoppedSummary)
    Write-Output ('Startup method: ' + $startupMethod)
    Write-Output 'Gold repo refresh completed and Wilbur readiness was confirmed.'
}
catch {
    $step = if ([string]::IsNullOrWhiteSpace($script:goldRefreshStep)) { 'unknown' } else { $script:goldRefreshStep }
    $message = $_.Exception.Message
    Write-Error ('Gold refresh failed during step ''{0}'': {1}' -f $step, $message)
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Error $_.ScriptStackTrace
    }

    if ($_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace($_.InvocationInfo.PositionMessage)) {
        Write-Error $_.InvocationInfo.PositionMessage
    }

    exit 1
}
