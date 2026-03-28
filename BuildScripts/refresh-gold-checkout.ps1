[CmdletBinding()]
param(
    [string]$RepoRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$StackTaskName = '',
    [int]$WaitForWilburTimeoutSeconds = 120
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

$script:goldRefreshStep = 'initializing'
$repoSyncScript = Join-Path $RepoRoot 'SignallingWebServer\platform_scripts\powershell\ensure_repo_current.ps1'
$stackLauncher = Join-Path $RepoRoot 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'

try {
    if (-not (Test-Path -LiteralPath $repoSyncScript)) {
        throw "Repo sync helper '$repoSyncScript' was not found."
    }

    if (-not (Test-Path -LiteralPath $stackLauncher)) {
        throw "Stack launcher '$stackLauncher' was not found."
    }

    $stoppedProcesses = [System.Collections.Generic.List[string]]::new()

    $script:goldRefreshStep = 'stopping_existing_processes'
    Stop-GoldProcessMatches -Label 'watchdog-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_watchdog.bat*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'watchdog' -NamePattern 'powershell.exe' -CommandLinePattern '*watchdog.ps1*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePattern '*index.js*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'wilbur-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_dev_turn.bat*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'unreal' -NamePattern 'ScaleWorld*' -CommandLinePattern '*start_scaleworld.ps1*' -StoppedProcesses $stoppedProcesses
    Stop-GoldProcessMatches -Label 'unreal-launcher' -NamePattern 'cmd.exe' -CommandLinePattern '*start_unreal.bat*' -StoppedProcesses $stoppedProcesses

    Start-Sleep -Seconds 2

    $script:goldRefreshStep = 'repo_sync_and_build_validation'
    Write-GoldRefreshLog 'Synchronizing PixelStreaming repo and validating build outputs.'
    & $repoSyncScript -RepoRoot $RepoRoot -Mode 'maintenance' -GitSyncMode 'upstream'
    if ($LASTEXITCODE -ne 0) {
        throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
    }

    $startupMethod = ''
    $stackDetected = $false

    if (-not [string]::IsNullOrWhiteSpace($StackTaskName)) {
        $script:goldRefreshStep = 'scheduled_task_query'
        schtasks.exe /Query /TN $StackTaskName *> $null
        if ($LASTEXITCODE -eq 0) {
            $script:goldRefreshStep = 'scheduled_task_restart'
            Write-GoldRefreshLog "Restarting Gold stack via scheduled task '$StackTaskName'."
            schtasks.exe /Run /TN $StackTaskName *> $null
            if ($LASTEXITCODE -eq 0) {
                $startupMethod = 'scheduled-task'
            } else {
                Write-GoldRefreshLog "Scheduled task '$StackTaskName' returned exit code $LASTEXITCODE. Falling back to direct stack restart." 'WARN'
            }
        }
    }

    if ($startupMethod -eq 'scheduled-task') {
        $script:goldRefreshStep = 'waiting_for_wilbur_after_scheduled_task'
        $stackDetected = Wait-ForWilbur -TimeoutSeconds $WaitForWilburTimeoutSeconds
    }

    if (-not $stackDetected) {
        $script:goldRefreshStep = 'direct_stack_restart'
        Write-GoldRefreshLog 'Restarting Gold stack directly via start_streamer_stack.bat.'
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f $stackLauncher) -WorkingDirectory (Split-Path -Parent $stackLauncher) -WindowStyle Hidden | Out-Null
        $startupMethod = if ($startupMethod.Length -gt 0) { $startupMethod + ' -> direct' } else { 'direct' }
        $script:goldRefreshStep = 'waiting_for_wilbur_after_direct_restart'
        $stackDetected = Wait-ForWilbur -TimeoutSeconds $WaitForWilburTimeoutSeconds
    }

    if (-not $stackDetected) {
        throw "Gold stack restart did not detect Wilbur within $WaitForWilburTimeoutSeconds seconds."
    }

    $stoppedSummary = if ($stoppedProcesses.Count -gt 0) { $stoppedProcesses -join ', ' } else { '(none)' }
    Write-Output ('Stopped processes: ' + $stoppedSummary)
    Write-Output ('Startup method: ' + $startupMethod)
    Write-Output 'Gold repo refresh completed and Wilbur was detected.'
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
