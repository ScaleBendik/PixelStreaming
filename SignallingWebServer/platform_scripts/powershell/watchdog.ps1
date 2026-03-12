[CmdletBinding()]
param(
    [string]$UnrealProcessName = $(if ($env:WATCHDOG_UNREAL_PROCESS_NAME) { $env:WATCHDOG_UNREAL_PROCESS_NAME } else { 'ScaleWorld*' }),
    [string]$UnrealCommandLinePattern = $env:WATCHDOG_UNREAL_COMMANDLINE_PATTERN,
    [string]$WilburProcessName = $(if ($env:WATCHDOG_WILBUR_PROCESS_NAME) { $env:WATCHDOG_WILBUR_PROCESS_NAME } else { 'node.exe' }),
    [string]$WilburCommandLinePattern = $(if ($env:WATCHDOG_WILBUR_COMMANDLINE_PATTERN) { $env:WATCHDOG_WILBUR_COMMANDLINE_PATTERN } else { 'index.js' }),
    [string]$PollIntervalSeconds = $(if ($env:WATCHDOG_POLL_INTERVAL_SECONDS) { $env:WATCHDOG_POLL_INTERVAL_SECONDS } else { '5' }),
    [string]$FailureThreshold = $(if ($env:WATCHDOG_FAILURE_THRESHOLD) { $env:WATCHDOG_FAILURE_THRESHOLD } else { '3' }),
    [string]$RestartCooldownSeconds = $(if ($env:WATCHDOG_RESTART_COOLDOWN_SECONDS) { $env:WATCHDOG_RESTART_COOLDOWN_SECONDS } else { '5' }),
    [string]$PostRestartGraceSeconds = $(if ($env:WATCHDOG_POST_RESTART_GRACE_SECONDS) { $env:WATCHDOG_POST_RESTART_GRACE_SECONDS } else { '8' }),
    [string]$ProcessStartupGraceSeconds = $(if ($env:WATCHDOG_PROCESS_STARTUP_GRACE_SECONDS) { $env:WATCHDOG_PROCESS_STARTUP_GRACE_SECONDS } else { '15' }),
    [string]$TerminateMatchedProcesses = $(if ($env:WATCHDOG_TERMINATE_MATCHED_PROCESSES) { $env:WATCHDOG_TERMINATE_MATCHED_PROCESSES } else { 'false' }),
    [string]$DryRun = $(if ($env:WATCHDOG_DRY_RUN) { $env:WATCHDOG_DRY_RUN } else { 'false' }),
    [string]$RunOnce = $(if ($env:WATCHDOG_RUN_ONCE) { $env:WATCHDOG_RUN_ONCE } else { 'false' }),
    [string]$RestartCommand = $env:WATCHDOG_RESTART_COMMAND,
    [string]$WilburRestartCommand = $env:WATCHDOG_WILBUR_RESTART_COMMAND,
    [string]$UnrealRestartCommand = $env:WATCHDOG_UNREAL_RESTART_COMMAND,
    [string]$PreRestartCommand = $env:WATCHDOG_PRE_RESTART_COMMAND,
    [string]$PostRestartCommand = $env:WATCHDOG_POST_RESTART_COMMAND,
    [string]$LogPath = $env:WATCHDOG_LOG_PATH,
    [string]$RuntimeStatusEnabled = $(if ($env:WATCHDOG_RUNTIME_STATUS_ENABLED) { $env:WATCHDOG_RUNTIME_STATUS_ENABLED } elseif ($env:RUNTIME_STATUS_ENABLED) { $env:RUNTIME_STATUS_ENABLED } else { 'true' }),
    [string]$RuntimeStatusSource = $(if ($env:WATCHDOG_RUNTIME_STATUS_SOURCE) { $env:WATCHDOG_RUNTIME_STATUS_SOURCE } else { 'watchdog' }),
    [string]$RuntimeStatusVersion = $(if ($env:WATCHDOG_RUNTIME_STATUS_VERSION) { $env:WATCHDOG_RUNTIME_STATUS_VERSION } else { '' }),
    [string]$AwsCliPath = $(if ($env:WATCHDOG_AWS_CLI_PATH) { $env:WATCHDOG_AWS_CLI_PATH } elseif ($env:RUNTIME_STATUS_AWS_CLI_PATH) { $env:RUNTIME_STATUS_AWS_CLI_PATH } else { 'aws' }),
    [string]$StreamerHealthEnabled = $(if ($env:WATCHDOG_STREAMER_HEALTH_ENABLED) { $env:WATCHDOG_STREAMER_HEALTH_ENABLED } else { 'true' }),
    [string]$StreamerHealthPath = $(if ($env:WATCHDOG_STREAMER_HEALTH_PATH) { $env:WATCHDOG_STREAMER_HEALTH_PATH } else { 'state\streamer-health.json' }),
    [string]$StreamerHealthMaxStaleSeconds = $(if ($env:WATCHDOG_STREAMER_HEALTH_MAX_STALE_SECONDS) { $env:WATCHDOG_STREAMER_HEALTH_MAX_STALE_SECONDS } else { '75' }),
    [string]$StreamerHealthStartupGraceSeconds = $(if ($env:WATCHDOG_STREAMER_HEALTH_STARTUP_GRACE_SECONDS) { $env:WATCHDOG_STREAMER_HEALTH_STARTUP_GRACE_SECONDS } else { '120' }),
    [string]$ProvisioningStreamerHealthStartupGraceSeconds = $(if ($env:WATCHDOG_PROVISIONING_STREAMER_HEALTH_STARTUP_GRACE_SECONDS) { $env:WATCHDOG_PROVISIONING_STREAMER_HEALTH_STARTUP_GRACE_SECONDS } else { '3600' }),
    [string]$ProvisioningStreamerConnectTimeoutSeconds = $(if ($env:WATCHDOG_PROVISIONING_STREAMER_CONNECT_TIMEOUT_SECONDS) { $env:WATCHDOG_PROVISIONING_STREAMER_CONNECT_TIMEOUT_SECONDS } else { '900' }),
    [string]$ProvisioningMaxRecoveryRestarts = $(if ($env:WATCHDOG_PROVISIONING_MAX_RECOVERY_RESTARTS) { $env:WATCHDOG_PROVISIONING_MAX_RECOVERY_RESTARTS } else { '1' }),
    [string]$MaintenanceModeRefreshSeconds = $(if ($env:WATCHDOG_MAINTENANCE_MODE_REFRESH_SECONDS) { $env:WATCHDOG_MAINTENANCE_MODE_REFRESH_SECONDS } else { '60' }),
    [string]$UnrealCpuStallConfirmEnabled = $(if ($env:WATCHDOG_UNREAL_CPU_STALL_CONFIRM_ENABLED) { $env:WATCHDOG_UNREAL_CPU_STALL_CONFIRM_ENABLED } else { 'true' }),
    [string]$UnrealCpuStallMinDeltaSeconds = $(if ($env:WATCHDOG_UNREAL_CPU_STALL_MIN_DELTA_SECONDS) { $env:WATCHDOG_UNREAL_CPU_STALL_MIN_DELTA_SECONDS } else { '0.001' }),
    [string]$UnrealCpuStallConfirmSeconds = $(if ($env:WATCHDOG_UNREAL_CPU_STALL_CONFIRM_SECONDS) { $env:WATCHDOG_UNREAL_CPU_STALL_CONFIRM_SECONDS } else { '10' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IdentityCache = $null
$script:LastStatusPublishFailure = $null
$script:LastMaintenanceModeReadAtUtc = [DateTimeOffset]::MinValue
$script:MaintenanceModeCache = $null
$script:LastMaintenanceModeReadFailure = $null
$script:LastLoggedMaintenanceMode = '__uninitialized__'
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

function ConvertTo-NonNegativeDouble {
    param(
        [string]$Value,
        [double]$Default,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    $parsed = 0.0
    if (-not [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or $parsed -lt 0) {
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
            ("Key=ScaleWorldRuntimeStatusHeartbeatAtUtc,Value={0}" -f $timestamp),
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

function Get-MaintenanceMode {
    if ($maintenanceModeRefreshSecondsValue -le 0) {
        return $null
    }

    $nowUtc = [DateTimeOffset]::UtcNow
    if (
        $script:LastMaintenanceModeReadAtUtc -ne [DateTimeOffset]::MinValue -and
        ($nowUtc - $script:LastMaintenanceModeReadAtUtc).TotalSeconds -lt $maintenanceModeRefreshSecondsValue
    ) {
        return $script:MaintenanceModeCache
    }

    try {
        $identity = Get-InstanceIdentity
        $args = @(
            'ec2', 'describe-tags',
            '--region', $identity.Region,
            '--filters',
            ("Name=resource-id,Values={0}" -f $identity.InstanceId),
            'Name=key,Values=ScaleWorldMaintenanceMode',
            '--query', 'Tags[0].Value',
            '--output', 'text'
        )
        $output = & $AwsCliPath @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String).Trim()
        }

        $maintenanceMode = (($output | Out-String).Trim())
        if (
            [string]::IsNullOrWhiteSpace($maintenanceMode) -or
            $maintenanceMode.Equals('None', [System.StringComparison]::OrdinalIgnoreCase) -or
            $maintenanceMode.Equals('null', [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $maintenanceMode = $null
        }

        $script:MaintenanceModeCache = $maintenanceMode
        $script:LastMaintenanceModeReadAtUtc = $nowUtc
        $script:LastMaintenanceModeReadFailure = $null

        $loggedMode = if ($maintenanceMode) { $maintenanceMode } else { '<none>' }
        if ($loggedMode -ne $script:LastLoggedMaintenanceMode) {
            Write-WatchdogLog "Observed maintenance mode: $loggedMode"
            $script:LastLoggedMaintenanceMode = $loggedMode
        }

        return $script:MaintenanceModeCache
    } catch {
        $failure = $_.Exception.Message
        if ($script:LastMaintenanceModeReadFailure -ne $failure) {
            Write-WatchdogLog "Failed to read maintenance mode: $failure" 'WARN'
            $script:LastMaintenanceModeReadFailure = $failure
        }

        return $script:MaintenanceModeCache
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

function Get-ProcessCpuSnapshot {
    param([int[]]$ProcessIds)

    if (-not $ProcessIds -or $ProcessIds.Count -eq 0) {
        return [pscustomobject]@{
            IdKey = ''
            TotalCpuSeconds = 0.0
        }
    }

    $processes = @(Get-Process -Id $ProcessIds -ErrorAction SilentlyContinue)
    $orderedProcesses = $processes | Sort-Object Id
    $idKey = (($orderedProcesses | ForEach-Object { [string]$_.Id }) -join ',')
    $totalCpuSeconds = 0.0
    foreach ($process in $orderedProcesses) {
        $totalCpuSeconds += [double]$process.CPU
    }

    return [pscustomobject]@{
        IdKey = $idKey
        TotalCpuSeconds = $totalCpuSeconds
    }
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

    $windowStyle = if ($Label -eq 'wilbur restart') { 'Normal' } else { 'Hidden' }

    Write-WatchdogLog "Executing $Label command: $Command"
    if ($WaitForExit) {
        if ($parsedCommand -and $parsedCommand.Executable -match '\.(cmd|bat)$') {
            $cmdLine = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) {
                ('call "{0}"' -f $parsedCommand.Executable)
            } else {
                ('call "{0}" {1}' -f $parsedCommand.Executable, $parsedCommand.Arguments)
            }
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -Wait -PassThru -WindowStyle $windowStyle
        } elseif ($parsedCommand) {
            $argumentList = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) { @() } else { @($parsedCommand.Arguments) }
            $process = Start-Process -FilePath $parsedCommand.Executable -ArgumentList $argumentList -Wait -PassThru -WindowStyle $windowStyle
        } else {
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Command -Wait -PassThru -WindowStyle $windowStyle
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
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -PassThru -WindowStyle $windowStyle
    } elseif ($parsedCommand) {
        $argumentList = if ([string]::IsNullOrWhiteSpace($parsedCommand.Arguments)) { @() } else { @($parsedCommand.Arguments) }
        $process = Start-Process -FilePath $parsedCommand.Executable -ArgumentList $argumentList -PassThru -WindowStyle $windowStyle
    } else {
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Command -PassThru -WindowStyle $windowStyle
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

function Get-RecoveryPlan {
    param(
        [object[]]$FailedRules,
        [object[]]$PrimaryRules,
        [object[]]$LauncherRules,
        [string]$DefaultCommand,
        [string]$WilburOnlyCommand,
        [string]$UnrealOnlyCommand
    )

    $failedRuleNames = @($FailedRules | ForEach-Object { $_.Name })
    $nonHealthFailedRules = @($FailedRules | Where-Object { $_.Name -ne 'streamer-health' })

    if ($nonHealthFailedRules.Count -eq 1 -and $failedRuleNames.Count -eq 1) {
        $singleRule = $nonHealthFailedRules[0]
        if ($singleRule.Name -eq 'wilbur' -and -not [string]::IsNullOrWhiteSpace($WilburOnlyCommand)) {
            return [pscustomobject]@{
                Label = 'wilbur restart'
                Command = $WilburOnlyCommand
                TerminationRules = @($PrimaryRules | Where-Object { $_.Name -eq 'wilbur' }) + @($LauncherRules | Where-Object { $_.Name -like 'wilbur-*' })
                BootReason = 'watchdog_wilbur_restart_pending'
            }
        }

        if ($singleRule.Name -eq 'unreal' -and -not [string]::IsNullOrWhiteSpace($UnrealOnlyCommand)) {
            return [pscustomobject]@{
                Label = 'unreal restart'
                Command = $UnrealOnlyCommand
                TerminationRules = @($PrimaryRules | Where-Object { $_.Name -eq 'unreal' }) + @($LauncherRules | Where-Object { $_.Name -like 'unreal-*' })
                BootReason = 'watchdog_unreal_restart_pending'
            }
        }
    }

    return [pscustomobject]@{
        Label = 'stack restart'
        Command = $DefaultCommand
        TerminationRules = @($PrimaryRules) + @($LauncherRules)
        BootReason = 'watchdog_restart_pending'
    }
}

function Read-StreamerHealthSnapshot {
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

$pollIntervalSecondsValue = ConvertTo-PositiveInt -Value $PollIntervalSeconds -Default 15 -Name 'PollIntervalSeconds'
$failureThresholdValue = ConvertTo-PositiveInt -Value $FailureThreshold -Default 3 -Name 'FailureThreshold'
$restartCooldownSecondsValue = ConvertTo-PositiveInt -Value $RestartCooldownSeconds -Default 120 -Name 'RestartCooldownSeconds'
$postRestartGraceSecondsValue = ConvertTo-PositiveInt -Value $PostRestartGraceSeconds -Default 30 -Name 'PostRestartGraceSeconds'
$processStartupGraceSecondsValue = ConvertTo-PositiveInt -Value $ProcessStartupGraceSeconds -Default 30 -Name 'ProcessStartupGraceSeconds'
$terminateMatchedProcessesValue = ConvertTo-Bool -Value $TerminateMatchedProcesses -Default $false
$dryRunValue = ConvertTo-Bool -Value $DryRun -Default $false
$runOnceValue = ConvertTo-Bool -Value $RunOnce -Default $false
$runtimeStatusEnabledValue = ConvertTo-Bool -Value $RuntimeStatusEnabled -Default $true
$streamerHealthEnabledValue = ConvertTo-Bool -Value $StreamerHealthEnabled -Default $true
$streamerHealthMaxStaleSecondsValue = ConvertTo-PositiveInt -Value $StreamerHealthMaxStaleSeconds -Default 75 -Name 'StreamerHealthMaxStaleSeconds'
$streamerHealthStartupGraceSecondsValue = ConvertTo-PositiveInt -Value $StreamerHealthStartupGraceSeconds -Default 120 -Name 'StreamerHealthStartupGraceSeconds'
$provisioningStreamerHealthStartupGraceSecondsValue = ConvertTo-PositiveInt -Value $ProvisioningStreamerHealthStartupGraceSeconds -Default 3600 -Name 'ProvisioningStreamerHealthStartupGraceSeconds'
$provisioningStreamerConnectTimeoutSecondsValue = ConvertTo-PositiveInt -Value $ProvisioningStreamerConnectTimeoutSeconds -Default 900 -Name 'ProvisioningStreamerConnectTimeoutSeconds'
$provisioningMaxRecoveryRestartsValue = ConvertTo-PositiveInt -Value $ProvisioningMaxRecoveryRestarts -Default 1 -Name 'ProvisioningMaxRecoveryRestarts'
$maintenanceModeRefreshSecondsValue = ConvertTo-PositiveInt -Value $MaintenanceModeRefreshSeconds -Default 60 -Name 'MaintenanceModeRefreshSeconds'
$unrealCpuStallConfirmEnabledValue = ConvertTo-Bool -Value $UnrealCpuStallConfirmEnabled -Default $true
$unrealCpuStallMinDeltaSecondsValue = ConvertTo-NonNegativeDouble -Value $UnrealCpuStallMinDeltaSeconds -Default 0.001 -Name 'UnrealCpuStallMinDeltaSeconds'
$unrealCpuStallConfirmSecondsValue = ConvertTo-NonNegativeDouble -Value $UnrealCpuStallConfirmSeconds -Default 10 -Name 'UnrealCpuStallConfirmSeconds'
$resolvedStreamerHealthPath = if ([System.IO.Path]::IsPathRooted($StreamerHealthPath)) { $StreamerHealthPath } else { Join-Path $script:SignallingWebServerRoot $StreamerHealthPath }

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

$recoveryLauncherRules = @(
    [pscustomobject]@{
        Name = 'wilbur-launcher-cmd'
        ProcessName = 'cmd.exe'
        CommandLinePattern = 'start_dev_turn.bat'
        FaultReason = $null
    },
    [pscustomobject]@{
        Name = 'unreal-launcher-cmd'
        ProcessName = 'cmd.exe'
        CommandLinePattern = 'start_unreal.bat'
        FaultReason = $null
    },
    [pscustomobject]@{
        Name = 'unreal-launcher-powershell'
        ProcessName = 'powershell.exe'
        CommandLinePattern = 'start_scaleworld.ps1'
        FaultReason = $null
    }
)

if ($rules.Count -eq 0) {
    throw 'No watchdog rules configured. Set WATCHDOG_UNREAL_PROCESS_NAME and/or WATCHDOG_WILBUR_PROCESS_NAME.'
}

if ([string]::IsNullOrWhiteSpace($UnrealProcessName)) {
    Write-WatchdogLog 'WATCHDOG_UNREAL_PROCESS_NAME not set. Watchdog will not detect Unreal crashes yet.' 'WARN'
}
if ([string]::IsNullOrWhiteSpace($RestartCommand)) {
    Write-WatchdogLog 'WATCHDOG_RESTART_COMMAND not set. Watchdog will publish faults but cannot recover automatically.' 'WARN'
}
if ([string]::IsNullOrWhiteSpace($WilburRestartCommand)) {
    $WilburRestartCommand = $RestartCommand
}
if ([string]::IsNullOrWhiteSpace($UnrealRestartCommand)) {
    $UnrealRestartCommand = $RestartCommand
}
if ($streamerHealthEnabledValue -and ([string]::IsNullOrWhiteSpace($UnrealProcessName) -or [string]::IsNullOrWhiteSpace($WilburProcessName))) {
    Write-WatchdogLog 'WATCHDOG_STREAMER_HEALTH_ENABLED requires both Unreal and Wilbur process rules. Disabling streamer health checks.' 'WARN'
    $streamerHealthEnabledValue = $false
}
if ($unrealCpuStallConfirmEnabledValue -and [string]::IsNullOrWhiteSpace($UnrealProcessName)) {
    Write-WatchdogLog 'WATCHDOG_UNREAL_CPU_STALL_CONFIRM_ENABLED requires an Unreal process rule. Disabling CPU stall confirmation.' 'WARN'
    $unrealCpuStallConfirmEnabledValue = $false
}

$ruleFailures = @{}
foreach ($rule in $rules) {
    $ruleFailures[$rule.Name] = 0
}
$streamerHealthFailureCount = 0

$watchdogStartedAtUtc = [DateTimeOffset]::UtcNow
$lastRestartAtUtc = [DateTimeOffset]::MinValue
$lastFaultSignature = $null
$lastSuspiciousSignature = $null
$healthyLogged = $false
$lastUnrealCpuSnapshot = $null
$unrealCpuStallAccumulatedSeconds = 0.0
$provisioningRecoveryRestartCount = 0

Write-WatchdogLog ('Starting watchdog. Poll={0}s threshold={1} restartCooldown={2}s postRestartGrace={3}s processStartupGrace={4}s dryRun={5} runtimeStatus={6} streamerHealth={7} streamerHealthPath={8} streamerHealthMaxStale={9}s streamerHealthStartupGrace={10}s provisioningStreamerHealthStartupGrace={11}s provisioningConnectTimeout={12}s provisioningMaxRecoveryRestarts={13}s maintenanceRefresh={14}s unrealCpuConfirm={15} unrealCpuMinDelta={16}s unrealCpuConfirmWindow={17}s' -f $pollIntervalSecondsValue, $failureThresholdValue, $restartCooldownSecondsValue, $postRestartGraceSecondsValue, $processStartupGraceSecondsValue, $dryRunValue, $runtimeStatusEnabledValue, $streamerHealthEnabledValue, $resolvedStreamerHealthPath, $streamerHealthMaxStaleSecondsValue, $streamerHealthStartupGraceSecondsValue, $provisioningStreamerHealthStartupGraceSecondsValue, $provisioningStreamerConnectTimeoutSecondsValue, $provisioningMaxRecoveryRestartsValue, $maintenanceModeRefreshSecondsValue, $unrealCpuStallConfirmEnabledValue, $unrealCpuStallMinDeltaSecondsValue, $unrealCpuStallConfirmSecondsValue)
Write-WatchdogLog ('Rules: {0}' -f (($rules | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_.CommandLinePattern)) { $_.ProcessName } else { '{0} [{1}]' -f $_.ProcessName, $_.CommandLinePattern } }) -join ', '))

while ($true) {
    try {
    $processStartupGraceActive = $processStartupGraceSecondsValue -gt 0 -and (([DateTimeOffset]::UtcNow - $watchdogStartedAtUtc).TotalSeconds -lt $processStartupGraceSecondsValue)
    $snapshot = @(Get-ProcessSnapshot)
    $ruleMatches = @{}
    $failedRules = @()
    $currentMaintenanceMode = Get-MaintenanceMode
    $isProvisioningMaintenance = -not [string]::IsNullOrWhiteSpace($currentMaintenanceMode) -and $currentMaintenanceMode.Equals('provisioning', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isProvisioningMaintenance) {
        $provisioningRecoveryRestartCount = 0
    }

    foreach ($rule in $rules) {
        $matches = Find-MatchingProcesses -Snapshot $snapshot -Rule $rule
        $ruleMatches[$rule.Name] = $matches
        if ($matches.Count -gt 0) {
            $ruleFailures[$rule.Name] = 0
            continue
        }

        $ruleFailures[$rule.Name] = [int]$ruleFailures[$rule.Name] + 1
        if (-not $processStartupGraceActive -and $ruleFailures[$rule.Name] -ge $failureThresholdValue) {
            $failedRules += $rule
        }
    }

    $pendingFaultSignature = $null
    $pendingFaultSummary = $null
    $unrealCpuStallConfirmed = $false
    $unrealCpuStallSummary = $null
    if ($unrealCpuStallConfirmEnabledValue -and $ruleMatches.ContainsKey('unreal') -and $ruleMatches['unreal'].Count -gt 0) {
        $unrealProcessIds = @($ruleMatches['unreal'] | ForEach-Object { [int]$_.ProcessId })
        $unrealCpuSnapshot = Get-ProcessCpuSnapshot -ProcessIds $unrealProcessIds
        $sampledAtUtc = [DateTimeOffset]::UtcNow
        if ($lastUnrealCpuSnapshot -and $lastUnrealCpuSnapshot.IdKey -eq $unrealCpuSnapshot.IdKey -and -not [string]::IsNullOrWhiteSpace($unrealCpuSnapshot.IdKey)) {
            $elapsedCpuSeconds = ($sampledAtUtc - $lastUnrealCpuSnapshot.SampledAtUtc).TotalSeconds
            if ($elapsedCpuSeconds -gt 0) {
                $cpuDeltaSeconds = [Math]::Max(0.0, $unrealCpuSnapshot.TotalCpuSeconds - $lastUnrealCpuSnapshot.TotalCpuSeconds)
                if ($cpuDeltaSeconds -le $unrealCpuStallMinDeltaSecondsValue) {
                    $unrealCpuStallAccumulatedSeconds += $elapsedCpuSeconds
                } else {
                    $unrealCpuStallAccumulatedSeconds = 0.0
                }

                $unrealCpuStallSummary = 'unreal cpu delta {0:N3}s over {1:N1}s (stall {2:N1}/{3:N1}s)' -f $cpuDeltaSeconds, $elapsedCpuSeconds, $unrealCpuStallAccumulatedSeconds, $unrealCpuStallConfirmSecondsValue
                if ($unrealCpuStallAccumulatedSeconds -ge $unrealCpuStallConfirmSecondsValue) {
                    $unrealCpuStallConfirmed = $true
                }
            }
        } else {
            $unrealCpuStallAccumulatedSeconds = 0.0
            $unrealCpuStallSummary = 'unreal cpu stall confirmation reset (new or restarted process)'
        }

        $lastUnrealCpuSnapshot = [pscustomobject]@{
            IdKey = $unrealCpuSnapshot.IdKey
            TotalCpuSeconds = $unrealCpuSnapshot.TotalCpuSeconds
            SampledAtUtc = $sampledAtUtc
        }
    } else {
        $lastUnrealCpuSnapshot = $null
        $unrealCpuStallAccumulatedSeconds = 0.0
    }

    if (
        $streamerHealthEnabledValue -and
        $ruleMatches.ContainsKey('unreal') -and
        $ruleMatches.ContainsKey('wilbur') -and
        $ruleMatches['unreal'].Count -gt 0 -and
        $ruleMatches['wilbur'].Count -gt 0
    ) {
        $healthGraceReferenceUtc = if ($lastRestartAtUtc -ne [DateTimeOffset]::MinValue) { $lastRestartAtUtc } else { $watchdogStartedAtUtc }
        $secondsSinceHealthGraceReference = ([DateTimeOffset]::UtcNow - $healthGraceReferenceUtc).TotalSeconds
        $effectiveStreamerHealthStartupGraceSeconds = $streamerHealthStartupGraceSecondsValue
        if ($isProvisioningMaintenance) {
            $effectiveStreamerHealthStartupGraceSeconds = [Math]::Min(
                [Math]::Max(
                    $effectiveStreamerHealthStartupGraceSeconds,
                    $provisioningStreamerHealthStartupGraceSecondsValue
                ),
                $provisioningStreamerConnectTimeoutSecondsValue
            )
        }

        if ($secondsSinceHealthGraceReference -lt $effectiveStreamerHealthStartupGraceSeconds) {
            $streamerHealthFailureCount = 0
        } else {
            $streamerHealthResult = Read-StreamerHealthSnapshot -Path $resolvedStreamerHealthPath
            $streamerHealthFaultReason = $null
            $streamerHealthFaultSummary = $null

            if ($streamerHealthResult.State -eq 'missing') {
                $streamerHealthFaultReason = 'streamer_health_missing'
                $streamerHealthFaultSummary = "streamer health file missing ($resolvedStreamerHealthPath)"
            } elseif ($streamerHealthResult.State -eq 'invalid') {
                $streamerHealthFaultReason = 'streamer_health_invalid'
                $streamerHealthFaultSummary = "streamer health file invalid ($($streamerHealthResult.Error))"
            } else {
                $streamerHealthSnapshot = $streamerHealthResult.Snapshot
                $updatedAtUtc = $null
                $updatedAtText = [string]$streamerHealthSnapshot.updatedAtUtc
                if ([string]::IsNullOrWhiteSpace($updatedAtText)) {
                    $streamerHealthFaultReason = 'streamer_health_missing_timestamp'
                    $streamerHealthFaultSummary = 'streamer health file missing updatedAtUtc timestamp'
                } else {
                    try {
                        $updatedAtUtc = [DateTimeOffset]::Parse(
                            $updatedAtText,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                    } catch {
                        $streamerHealthFaultReason = 'streamer_health_missing_timestamp'
                        $streamerHealthFaultSummary = 'streamer health file missing updatedAtUtc timestamp'
                    }

                    if ($streamerHealthFaultReason) {
                        # timestamp parse failed
                    } else {
                    $healthAgeSeconds = ([DateTimeOffset]::UtcNow - $updatedAtUtc).TotalSeconds
                    $healthy = $false
                    try {
                        $healthy = [bool]$streamerHealthSnapshot.healthy
                    } catch {
                        $healthy = $false
                    }

                    if ($healthAgeSeconds -gt $streamerHealthMaxStaleSecondsValue) {
                        $streamerHealthFaultReason = 'streamer_health_file_stale'
                        $streamerHealthFaultSummary = "streamer health file stale (${healthAgeSeconds:N0}s)"
                    } elseif (-not $healthy) {
                        $snapshotReason = [string]$streamerHealthSnapshot.reason
                        $snapshotStatus = [string]$streamerHealthSnapshot.status
                        if ([string]::IsNullOrWhiteSpace($snapshotReason)) {
                            $snapshotReason = 'streamer_unhealthy'
                        }
                        if ([string]::IsNullOrWhiteSpace($snapshotStatus)) {
                            $snapshotStatus = 'unknown'
                        }
                        $streamerHealthFaultReason = $snapshotReason
                        $streamerHealthFaultSummary = "streamer health unhealthy (status=$snapshotStatus reason=$snapshotReason)"
                    }
                    }
                }
            }

            if ($streamerHealthFaultReason) {
                $streamerHealthFailureCount = $streamerHealthFailureCount + 1
                if ($streamerHealthFailureCount -ge $failureThresholdValue) {
                    $streamerHealthSummaryWithCpu = if ([string]::IsNullOrWhiteSpace($unrealCpuStallSummary)) {
                        $streamerHealthFaultSummary
                    } else {
                        '{0}; {1}' -f $streamerHealthFaultSummary, $unrealCpuStallSummary
                    }

                    if (-not $unrealCpuStallConfirmEnabledValue -or $unrealCpuStallConfirmed) {
                        $failedRules += [pscustomobject]@{
                            Name = 'streamer-health'
                            ProcessName = 'streamer-health'
                            CommandLinePattern = $null
                            FaultReason = $streamerHealthFaultReason
                            Summary = $streamerHealthSummaryWithCpu
                        }
                    } else {
                        $pendingFaultSignature = $streamerHealthFaultReason
                        $pendingFaultSummary = '{0}; awaiting CPU stall confirmation' -f $streamerHealthSummaryWithCpu
                    }
                }
            } else {
                $streamerHealthFailureCount = 0
            }
        }
    } else {
        $streamerHealthFailureCount = 0
    }

    if ($failedRules.Count -eq 0) {
        if ($processStartupGraceActive) {
            $lastSuspiciousSignature = $null
            $lastFaultSignature = $null
            $healthyLogged = $false
            if ($runOnceValue) {
                break
            }

            Start-Sleep -Seconds $pollIntervalSecondsValue
            continue
        }

        if ($pendingFaultSignature) {
            if ($pendingFaultSignature -ne $lastSuspiciousSignature) {
                Write-WatchdogLog "Suspicious runtime state detected: $pendingFaultSummary" 'WARN'
                $lastSuspiciousSignature = $pendingFaultSignature
            }

            $healthyLogged = $false
            $lastFaultSignature = $null
            if ($runOnceValue) {
                break
            }

            Start-Sleep -Seconds $pollIntervalSecondsValue
            continue
        }

        $lastSuspiciousSignature = $null
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
    $lastSuspiciousSignature = $null
    $faultSignature = ($failedRules | ForEach-Object FaultReason) -join '+'
    $faultSummary = ($failedRules | ForEach-Object {
        if ($_.Name -eq 'streamer-health') {
            '{0} ({1}/{2})' -f $_.Summary, $streamerHealthFailureCount, $failureThresholdValue
        } else {
            '{0} missing ({1}/{2})' -f $_.Name, $ruleFailures[$_.Name], $failureThresholdValue
        }
    }) -join '; '

    if ($faultSignature -ne $lastFaultSignature) {
        Write-WatchdogLog "Fault detected: $faultSummary" 'WARN'
        Publish-RuntimeStatus -Status 'runtime_fault' -Reason $faultSignature
        $lastFaultSignature = $faultSignature
    }

    $recoveryPlan = Get-RecoveryPlan -FailedRules $failedRules -PrimaryRules $rules -LauncherRules $recoveryLauncherRules -DefaultCommand $RestartCommand -WilburOnlyCommand $WilburRestartCommand -UnrealOnlyCommand $UnrealRestartCommand

    if ([string]::IsNullOrWhiteSpace($recoveryPlan.Command)) {
        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $pollIntervalSecondsValue
        continue
    }

    if ($isProvisioningMaintenance -and $provisioningRecoveryRestartCount -ge $provisioningMaxRecoveryRestartsValue) {
        Write-WatchdogLog "Provisioning recovery budget exhausted. Leaving maintenance in place and publishing runtime fault for: $faultSummary" 'WARN'
        Publish-RuntimeStatus -Status 'runtime_fault' -Reason 'provisioning_recovery_exhausted'
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

    Write-WatchdogLog ("Starting {0} for fault '{1}'." -f $recoveryPlan.Label, $faultSignature)
    if (-not (Invoke-CommandString -Command $PreRestartCommand -Label 'pre-restart' -WaitForExit $true)) {
        if ($runOnceValue) {
            break
        }

        Start-Sleep -Seconds $pollIntervalSecondsValue
        continue
    }

    if ($terminateMatchedProcessesValue) {
        Stop-MatchingProcesses -Snapshot $snapshot -Rules $recoveryPlan.TerminationRules
    }

    Publish-RuntimeStatus -Status 'booting' -Reason $recoveryPlan.BootReason
    $restartSucceeded = Invoke-CommandString -Command $recoveryPlan.Command -Label $recoveryPlan.Label -WaitForExit $false
    if ($restartSucceeded) {
        $null = Invoke-CommandString -Command $PostRestartCommand -Label 'post-restart' -WaitForExit $true
        $lastRestartAtUtc = [DateTimeOffset]::UtcNow
        if ($isProvisioningMaintenance) {
            $provisioningRecoveryRestartCount = $provisioningRecoveryRestartCount + 1
            Write-WatchdogLog "Provisioning recovery restart $provisioningRecoveryRestartCount/$provisioningMaxRecoveryRestartsValue launched."
        }
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

