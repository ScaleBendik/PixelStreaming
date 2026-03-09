[CmdletBinding()]
param(
    [string]$UnrealProcessName = "Scaleworld.exe",
    [string]$UnrealCommandLinePattern = $env:WATCHDOG_UNREAL_COMMANDLINE_PATTERN,
    [string]$WilburProcessName = $(if ($env:WATCHDOG_WILBUR_PROCESS_NAME) { $env:WATCHDOG_WILBUR_PROCESS_NAME } else { 'node.exe' }),
    [string]$WilburCommandLinePattern = $(if ($env:WATCHDOG_WILBUR_COMMANDLINE_PATTERN) { $env:WATCHDOG_WILBUR_COMMANDLINE_PATTERN } else { 'SignallingWebServer' }),
    [string]$PollIntervalSeconds = $(if ($env:WATCHDOG_POLL_INTERVAL_SECONDS) { $env:WATCHDOG_POLL_INTERVAL_SECONDS } else { '5' }),
    [string]$FailureThreshold = $(if ($env:WATCHDOG_FAILURE_THRESHOLD) { $env:WATCHDOG_FAILURE_THRESHOLD } else { '3' }),
    [string]$RestartCooldownSeconds = $(if ($env:WATCHDOG_RESTART_COOLDOWN_SECONDS) { $env:WATCHDOG_RESTART_COOLDOWN_SECONDS } else { '5' }),
    [string]$PostRestartGraceSeconds = $(if ($env:WATCHDOG_POST_RESTART_GRACE_SECONDS) { $env:WATCHDOG_POST_RESTART_GRACE_SECONDS } else { '8' }),
    [string]$TerminateMatchedProcesses = $(if ($env:WATCHDOG_TERMINATE_MATCHED_PROCESSES) { $env:WATCHDOG_TERMINATE_MATCHED_PROCESSES } else { 'false' }),
    [string]$DryRun = $(if ($env:WATCHDOG_DRY_RUN) { $env:WATCHDOG_DRY_RUN } else { 'false' }),
    [string]$RunOnce = $(if ($env:WATCHDOG_RUN_ONCE) { $env:WATCHDOG_RUN_ONCE } else { 'false' }),
    [string]$RestartCommand = $env:WATCHDOG_RESTART_COMMAND,
    [string]$PreRestartCommand = $env:WATCHDOG_PRE_RESTART_COMMAND,
    [string]$PostRestartCommand = $env:WATCHDOG_POST_RESTART_COMMAND,
    [string]$LogPath = $env:WATCHDOG_LOG_PATH,
    [string]$RuntimeStatusEnabled = $(if ($env:WATCHDOG_RUNTIME_STATUS_ENABLED) { $env:WATCHDOG_RUNTIME_STATUS_ENABLED } elseif ($env:RUNTIME_STATUS_ENABLED) { $env:RUNTIME_STATUS_ENABLED } else { 'true' }),
    [string]$RuntimeStatusSource = $(if ($env:WATCHDOG_RUNTIME_STATUS_SOURCE) { $env:WATCHDOG_RUNTIME_STATUS_SOURCE } else { 'watchdog' }),
    [string]$RuntimeStatusVersion = $(if ($env:WATCHDOG_RUNTIME_STATUS_VERSION) { $env:WATCHDOG_RUNTIME_STATUS_VERSION } else { '' }),
    [string]$AwsCliPath = $(if ($env:WATCHDOG_AWS_CLI_PATH) { $env:WATCHDOG_AWS_CLI_PATH } elseif ($env:RUNTIME_STATUS_AWS_CLI_PATH) { $env:RUNTIME_STATUS_AWS_CLI_PATH } else { 'aws' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IdentityCache = $null
$script:LastStatusPublishFailure = $null
$script:SignallingWebServerRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$defaultLogPath = Join-Path $script:SignallingWebServerRoot 'logs\scaleworld-watchdog.log'
$resolvedLogPath = if ([string]::IsNullOrWhiteSpace($LogPath)) { $defaultLogPath } elseif ([System.IO.Path]::IsPathRooted($LogPath)) { $LogPath } else { Join-Path $script:SignallingWebServerRoot $LogPath }
$logDir = Split-Path -Parent $resolvedLogPath
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function ConvertTo-Bool {
    param(
        [string]$Value,
        [bool]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'off' { return $false }
        default { return $Default }
    }
}

function ConvertTo-PositiveInt {
    param(
        [string]$Value,
        [int]$Default,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt 0) {
        throw "Invalid $Name value '$Value'."
    }

    return $parsed
}

function Normalize-TagValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $normalized = ($Value -replace '\s+', ' ').Trim()
    if ($normalized.Length -gt 256) {
        return $normalized.Substring(0, 256)
    }

    return $normalized
}

function Write-WatchdogLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "[$timestamp] [$Level] [watchdog] $Message"
    Write-Host $line
    Add-Content -Path $resolvedLogPath -Value $line
}

function Get-ImdsToken {
    Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
}

function Get-ImdsValue {
    param(
        [string]$PathSuffix,
        [string]$Token
    )

    Invoke-RestMethod -Method Get -Uri ("http://169.254.169.254/latest/meta-data/{0}" -f $PathSuffix) -Headers @{ 'X-aws-ec2-metadata-token' = $Token }
}

function Get-InstanceIdentity {
    if ($script:IdentityCache) {
        return $script:IdentityCache
    }

    $token = Get-ImdsToken
    $script:IdentityCache = [pscustomobject]@{
        InstanceId = (Get-ImdsValue -PathSuffix 'instance-id' -Token $token).Trim()
        Region = (Get-ImdsValue -PathSuffix 'placement/region' -Token $token).Trim()
    }

    return $script:IdentityCache
}

function Publish-RuntimeStatus {
    param(
        [string]$Status,
        [string]$Reason
    )

    if (-not $runtimeStatusEnabledValue) {
        return
    }

    try {
        $identity = Get-InstanceIdentity
        $timestamp = (Get-Date).ToUniversalTime().ToString('o')
        $args = @(
            'ec2', 'create-tags',
            '--region', $identity.Region,
            '--resources', $identity.InstanceId,
            '--tags',
            ("Key=ScaleWorldRuntimeStatus,Value={0}" -f (Normalize-TagValue $Status)),
            ("Key=ScaleWorldRuntimeStatusAtUtc,Value={0}" -f $timestamp),
            ("Key=ScaleWorldRuntimeStatusSource,Value={0}" -f (Normalize-TagValue $RuntimeStatusSource)),
            ("Key=ScaleWorldRuntimeStatusReason,Value={0}" -f (Normalize-TagValue $Reason)),
            ("Key=ScaleWorldRuntimeStatusVersion,Value={0}" -f (Normalize-TagValue $RuntimeStatusVersion))
        )
        $output = & $AwsCliPath @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String).Trim()
        }

        Write-WatchdogLog "Published runtime status '$Status' (reason=$Reason)."
        $script:LastStatusPublishFailure = $null
    } catch {
        $failure = $_.Exception.Message
        if ($script:LastStatusPublishFailure -ne $failure) {
            Write-WatchdogLog "Failed to publish runtime status '$Status': $failure" 'WARN'
            $script:LastStatusPublishFailure = $failure
        }
    }
}

function Test-NameMatch {
    param(
        [string]$Name,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return $false
    }

    if ($Pattern.Contains('*') -or $Pattern.Contains('?')) {
        return $Name -like $Pattern
    }

    return $Name.Equals($Pattern, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ProcessSnapshot {
    Get-CimInstance Win32_Process | Select-Object ProcessId, Name, CommandLine
}

function Find-MatchingProcesses {
    param(
        [object[]]$Snapshot,
        [pscustomobject]$Rule
    )

    $matches = @(
        $Snapshot | Where-Object {
            $name = [string]($_.Name)
            if (-not (Test-NameMatch -Name $name -Pattern $Rule.ProcessName)) {
                return $false
            }

            if ([string]::IsNullOrWhiteSpace($Rule.CommandLinePattern)) {
                return $true
            }

            $commandLine = [string]($_.CommandLine)
            return $commandLine.IndexOf($Rule.CommandLinePattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }
    )

    return ,$matches
}
function Invoke-CommandString {
    param(
        [string]$Command,
        [string]$Label,
        [bool]$WaitForExit = $true
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $true
    }

    if ($dryRunValue) {
        Write-WatchdogLog "DRY RUN: would execute $Label command: $Command"
        return $true
    }

    $parsedCommand = $null
    try {
        $trimmedCommand = $Command.Trim()
        if ($trimmedCommand.StartsWith('"')) {
            $closingQuote = $trimmedCommand.IndexOf('"', 1)
            if ($closingQuote -gt 1) {
                $parsedCommand = [pscustomobject]@{
                    Executable = $trimmedCommand.Substring(1, $closingQuote - 1)
                    Arguments = $trimmedCommand.Substring($closingQuote + 1).Trim()
                }
            }
        } else {
            $parts = $trimmedCommand -split '\s+', 2
            if ($parts.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
                $parsedCommand = [pscustomobject]@{
                    Executable = $parts[0]
                    Arguments = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
                }
            }
        }
    } catch {
        $parsedCommand = $null
    }

    Write-WatchdogLog "Executing $Label command: $Command"
    if ($WaitForExit) {
        if ($parsedCommand -and $parsedCommand.Executable -match '\.(cmd|bat)$') {
            $cmdLine = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) {
                ('call "{0}"' -f $parsedCommand.Executable)
            } else {
                ('call "{0}" {1}' -f $parsedCommand.Executable, $parsedCommand.Arguments)
            }
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -Wait -PassThru -WindowStyle Hidden
        } elseif ($parsedCommand) {
            $argumentList = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) { @() } else { @($parsedCommand.Arguments) }
            $process = Start-Process -FilePath $parsedCommand.Executable -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
        } else {
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Command -Wait -PassThru -WindowStyle Hidden
        }
        if ($process.ExitCode -ne 0) {
            Write-WatchdogLog "$Label command failed with exit code $($process.ExitCode)." 'ERROR'
            return $false
        }

        Write-WatchdogLog "$Label command completed successfully."
        return $true
    }

    if ($parsedCommand -and $parsedCommand.Executable -match '\.(cmd|bat)$') {
        $cmdLine = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) {
            ('call "{0}"' -f $parsedCommand.Executable)
        } else {
            ('call "{0}" {1}' -f $parsedCommand.Executable, $parsedCommand.Arguments)
        }
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -PassThru -WindowStyle Hidden
    } elseif ($parsedCommand) {
        $argumentList = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) { @() } else { @($parsedCommand.Arguments) }
        $process = Start-Process -FilePath $parsedCommand.Executable -ArgumentList $argumentList -PassThru -WindowStyle Hidden
    } else {
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Command -PassThru -WindowStyle Hidden
    }
    Write-WatchdogLog "$Label command started in detached cmd.exe process $($process.Id)."
    return $true
}

function Stop-MatchingProcesses {
    param(
        [object[]]$Snapshot,
        [object[]]$Rules
    )

    $allMatches = @()
    foreach ($rule in $Rules) {
        $allMatches += Find-MatchingProcesses -Snapshot $Snapshot -Rule $rule
    }

    $uniqueMatches = $allMatches | Sort-Object ProcessId -Unique
    foreach ($match in $uniqueMatches) {
        if ($dryRunValue) {
            Write-WatchdogLog "DRY RUN: would stop process $($match.Name) (PID=$($match.ProcessId))."
            continue
        }

        try {
            Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
            Write-WatchdogLog "Stopped process $($match.Name) (PID=$($match.ProcessId))."
        } catch {
            Write-WatchdogLog "Failed to stop process $($match.Name) (PID=$($match.ProcessId)): $($_.Exception.Message)" 'WARN'
        }
    }
}

$pollIntervalSecondsValue = ConvertTo-PositiveInt -Value $PollIntervalSeconds -Default 15 -Name 'PollIntervalSeconds'
$failureThresholdValue = ConvertTo-PositiveInt -Value $FailureThreshold -Default 3 -Name 'FailureThreshold'
$restartCooldownSecondsValue = ConvertTo-PositiveInt -Value $RestartCooldownSeconds -Default 120 -Name 'RestartCooldownSeconds'
$postRestartGraceSecondsValue = ConvertTo-PositiveInt -Value $PostRestartGraceSeconds -Default 30 -Name 'PostRestartGraceSeconds'
$terminateMatchedProcessesValue = ConvertTo-Bool -Value $TerminateMatchedProcesses -Default $false
$dryRunValue = ConvertTo-Bool -Value $DryRun -Default $false
$runOnceValue = ConvertTo-Bool -Value $RunOnce -Default $false
$runtimeStatusEnabledValue = ConvertTo-Bool -Value $RuntimeStatusEnabled -Default $true

$rules = [System.Collections.Generic.List[object]]::new()
if (-not [string]::IsNullOrWhiteSpace($UnrealProcessName)) {
    $rules.Add([pscustomobject]@{
        Name = 'unreal'
        ProcessName = $UnrealProcessName
        CommandLinePattern = $UnrealCommandLinePattern
        FaultReason = 'unreal_process_missing'
    })
}
if (-not [string]::IsNullOrWhiteSpace($WilburProcessName)) {
    $rules.Add([pscustomobject]@{
        Name = 'wilbur'
        ProcessName = $WilburProcessName
        CommandLinePattern = $WilburCommandLinePattern
        FaultReason = 'wilbur_process_missing'
    })
}

if ($rules.Count -eq 0) {
    throw 'No watchdog rules configured. Set WATCHDOG_UNREAL_PROCESS_NAME and/or WATCHDOG_WILBUR_PROCESS_NAME.'
}

if ([string]::IsNullOrWhiteSpace($UnrealProcessName)) {
    Write-WatchdogLog 'WATCHDOG_UNREAL_PROCESS_NAME not set. Watchdog will not detect Unreal crashes yet.' 'WARN'
}
if ([string]::IsNullOrWhiteSpace($RestartCommand)) {
    Write-WatchdogLog 'WATCHDOG_RESTART_COMMAND not set. Watchdog will publish faults but cannot recover automatically.' 'WARN'
}

$ruleFailures = @{}
foreach ($rule in $rules) {
    $ruleFailures[$rule.Name] = 0
}

$lastRestartAtUtc = [DateTimeOffset]::MinValue
$lastFaultSignature = $null
$healthyLogged = $false

Write-WatchdogLog ('Starting watchdog. Poll={0}s threshold={1} restartCooldown={2}s postRestartGrace={3}s dryRun={4} runtimeStatus={5}' -f $pollIntervalSecondsValue, $failureThresholdValue, $restartCooldownSecondsValue, $postRestartGraceSecondsValue, $dryRunValue, $runtimeStatusEnabledValue)
Write-WatchdogLog ('Rules: {0}' -f (($rules | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_.CommandLinePattern)) { $_.ProcessName } else { '{0} [{1}]' -f $_.ProcessName, $_.CommandLinePattern } }) -join ', '))

while ($true) {
    try {
    $snapshot = @(Get-ProcessSnapshot)
    $failedRules = @()

    foreach ($rule in $rules) {
        $matches = Find-MatchingProcesses -Snapshot $snapshot -Rule $rule
        if ($matches.Count -gt 0) {
            $ruleFailures[$rule.Name] = 0
            continue
        }

        $ruleFailures[$rule.Name] = [int]$ruleFailures[$rule.Name] + 1
        if ($ruleFailures[$rule.Name] -ge $failureThresholdValue) {
            $failedRules += $rule
        }
    }

    if ($failedRules.Count -eq 0) {
        if (-not $healthyLogged) {
            Write-WatchdogLog 'All required processes are present.'
            $healthyLogged = $true
        }

        $lastFaultSignature = $null
        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $pollIntervalSecondsValue
        continue
    }

    $healthyLogged = $false
    $faultSignature = ($failedRules | ForEach-Object FaultReason) -join '+'
    $faultSummary = ($failedRules | ForEach-Object { '{0} missing ({1}/{2})' -f $_.Name, $ruleFailures[$_.Name], $failureThresholdValue }) -join '; '

    if ($faultSignature -ne $lastFaultSignature) {
        Write-WatchdogLog "Fault detected: $faultSummary" 'WARN'
        Publish-RuntimeStatus -Status 'runtime_fault' -Reason $faultSignature
        $lastFaultSignature = $faultSignature
    }

    if ([string]::IsNullOrWhiteSpace($RestartCommand)) {
        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $pollIntervalSecondsValue
        continue
    }

    $secondsSinceRestart = if ($lastRestartAtUtc -eq [DateTimeOffset]::MinValue) {
        [double]::PositiveInfinity
    } else {
        ([DateTimeOffset]::UtcNow - $lastRestartAtUtc).TotalSeconds
    }
    if ($lastRestartAtUtc -ne [DateTimeOffset]::MinValue -and $secondsSinceRestart -lt $restartCooldownSecondsValue) {
        $cooldownRemainingSeconds = [int][Math]::Ceiling($restartCooldownSecondsValue - $secondsSinceRestart)
        Write-WatchdogLog "Restart cooldown active for $cooldownRemainingSeconds s. Fault persists: $faultSummary" 'WARN'
        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $pollIntervalSecondsValue
        continue
    }

    Write-WatchdogLog "Starting recovery for fault '$faultSignature'."
    if (-not (Invoke-CommandString -Command $PreRestartCommand -Label 'pre-restart' -WaitForExit $true)) {
        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $pollIntervalSecondsValue
        continue
    }

    if ($terminateMatchedProcessesValue) {
        Stop-MatchingProcesses -Snapshot $snapshot -Rules $rules
    }

    Publish-RuntimeStatus -Status 'booting' -Reason 'watchdog_restart_pending'
    $restartSucceeded = Invoke-CommandString -Command $RestartCommand -Label 'restart' -WaitForExit $false
    if ($restartSucceeded) {
        $null = Invoke-CommandString -Command $PostRestartCommand -Label 'post-restart' -WaitForExit $true
        $lastRestartAtUtc = [DateTimeOffset]::UtcNow
        foreach ($rule in $rules) {
            $ruleFailures[$rule.Name] = 0
        }
        $lastFaultSignature = $null
        Write-WatchdogLog "Restart command launched. Allowing $postRestartGraceSecondsValue seconds before next health evaluation."

        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $postRestartGraceSecondsValue
        continue
    }

    Publish-RuntimeStatus -Status 'runtime_fault' -Reason 'watchdog_restart_failed'
    if ($runOnceValue) {
        break
    }

    Start-Sleep -Seconds $pollIntervalSecondsValue
    } catch {
        $errorMessage = $_.Exception.Message
        $stackTrace = $_.ScriptStackTrace
        Write-WatchdogLog "Unhandled watchdog loop error: $errorMessage" 'ERROR'
        if (-not [string]::IsNullOrWhiteSpace($stackTrace)) {
            Write-WatchdogLog $stackTrace 'ERROR'
        }
        Start-Sleep -Seconds $pollIntervalSecondsValue
    }
}
