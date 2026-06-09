[CmdletBinding()]
param(
    [int]$FailureStopDelaySeconds = $(if ($env:SCALEWORLD_UPDATE_FAILURE_STOP_DELAY_SECONDS) { [int]$env:SCALEWORLD_UPDATE_FAILURE_STOP_DELAY_SECONDS } else { 1800 }),
    [int]$DetectionTimeoutSeconds = $(if ($env:SCALEWORLD_UPDATE_DETECTION_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_UPDATE_DETECTION_TIMEOUT_SECONDS } else { 90 }),
    [int]$RetryDelaySeconds = $(if ($env:SCALEWORLD_UPDATE_RETRY_DELAY_SECONDS) { [int]$env:SCALEWORLD_UPDATE_RETRY_DELAY_SECONDS } else { 15 }),
    [int]$ValidationTimeoutSeconds = $(if ($env:SCALEWORLD_UPDATE_VALIDATION_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_UPDATE_VALIDATION_TIMEOUT_SECONDS } else { 2700 }),
    [int]$RuntimeStatusValidationTimeoutSeconds = $(if ($env:SCALEWORLD_UPDATE_RUNTIME_STATUS_VALIDATION_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_UPDATE_RUNTIME_STATUS_VALIDATION_TIMEOUT_SECONDS } else { 120 }),
    [int]$ValidationStableSeconds = $(if ($env:SCALEWORLD_UPDATE_VALIDATION_STABLE_SECONDS) { [int]$env:SCALEWORLD_UPDATE_VALIDATION_STABLE_SECONDS } else { 15 }),
    [bool]$AllowUnchanged = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-UpdateModeLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [update-mode] $Message"
}

function Write-UpdateModeTrace {
    param(
        [string]$Step,
        [object]$Data = $null
    )

    if ([string]::IsNullOrWhiteSpace($script:UpdateModeTracePath)) {
        return
    }

    try {
        $directory = Split-Path -Parent $script:UpdateModeTracePath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $entry = [ordered]@{
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Step = $Step
        }

        if ($null -ne $Data) {
            $entry.Data = $Data
        }

        Add-Content -LiteralPath $script:UpdateModeTracePath -Value (($entry | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine) -Encoding UTF8
    } catch {
        Write-UpdateModeLog "Failed to write update trace '$Step': $($_.Exception.Message)" 'WARN'
    }
}

function Get-AwsCliPath {
    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
        'C:\Program Files\Amazon\AWSCLI\bin\aws.exe'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "AWS CLI ('aws') was not found."
}

function Get-InstanceIdentity {
    $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' }
    return [pscustomobject]@{
        InstanceId = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
        Region = (Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{ 'X-aws-ec2-metadata-token' = $token }).Trim()
    }
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

function Get-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId
    )

    $json = & $AwsCli ec2 describe-tags --region $Region --filters "Name=resource-id,Values=$InstanceId" "Name=key,Values=ScaleWorld*" --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to describe EC2 tags for $InstanceId."
    }

    $document = ($json | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $map = @{}
    foreach ($tag in @($document.Tags)) {
        $map[[string]$tag.Key] = [string]$tag.Value
    }

    return $map
}

function Invoke-AwsCliCapture {
    param(
        [string]$AwsCli,
        [string[]]$Arguments
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath $AwsCli -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath) {
            (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
        } else {
            ''
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
        } else {
            ''
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Combined = (@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [hashtable]$Tags
    )

    if (-not $Tags -or $Tags.Count -eq 0) {
        return
    }

    $tagPayload = foreach ($key in $Tags.Keys) {
        @{
            Key = [string]$key
            Value = Normalize-TagValue ([string]$Tags[$key])
        }
    }

    $tagPayloadPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText(
            $tagPayloadPath,
            (ConvertTo-Json -InputObject @($tagPayload) -Compress -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $args = @(
            'ec2',
            'create-tags',
            '--region', $Region,
            '--resources', $InstanceId,
            '--tags', ("file://{0}" -f $tagPayloadPath)
        )

        $result = Invoke-AwsCliCapture -AwsCli $AwsCli -Arguments $args
        if ($result.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($result.Combined)) {
                throw "Failed to set EC2 tags for $InstanceId. AWS CLI exited with code $($result.ExitCode)."
            }

            throw "Failed to set EC2 tags for $InstanceId. $($result.Combined)"
        }
    } finally {
        Remove-Item -LiteralPath $tagPayloadPath -Force -ErrorAction SilentlyContinue
    }
}

function TrySet-InstanceTags {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [hashtable]$Tags,
        [string]$FailureContext
    )

    try {
        Set-InstanceTags -AwsCli $AwsCli -Region $Region -InstanceId $InstanceId -Tags $Tags
    } catch {
        Write-UpdateModeLog "$FailureContext $($_.Exception.Message)" 'WARN'
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return ''
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }

    return ([string]$property.Value).Trim()
}

function Invoke-BootstrapCheckoutAlignment {
    param(
        [string]$RepoRoot,
        [string]$SourceCommit,
        [string]$SourceRef = ''
    )

    $targetCommit = ([string]$SourceCommit).Trim()
    if ([string]::IsNullOrWhiteSpace($targetCommit)) {
        throw 'Bootstrap checkout alignment requires a runtime artifact source commit.'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git') -PathType Container)) {
        throw "Bootstrap root '$RepoRoot' is not a git repository."
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Git ('git') was not found."
    }

    Write-UpdateModeLog "Aligning bootstrap checkout at '$RepoRoot' to runtime artifact source commit '$targetCommit'."
    $sourceRefValue = ([string]$SourceRef).Trim()
    if (-not [string]::IsNullOrWhiteSpace($sourceRefValue) -and -not [string]::Equals($sourceRefValue, 'HEAD', [System.StringComparison]::OrdinalIgnoreCase)) {
        & $git.Source -C $RepoRoot fetch origin $sourceRefValue
        if ($LASTEXITCODE -ne 0) {
            Write-UpdateModeLog "Bootstrap source ref fetch '$sourceRefValue' failed. Continuing with general origin fetch before checking out the artifact commit." 'WARN'
            $global:LASTEXITCODE = 0
        }
    }

    & $git.Source -C $RepoRoot fetch --tags --prune origin
    if ($LASTEXITCODE -ne 0) {
        throw 'Bootstrap checkout alignment failed while fetching origin.'
    }

    & $git.Source -C $RepoRoot checkout --force $targetCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrap checkout alignment failed while checking out '$targetCommit'."
    }

    $head = ((& $git.Source -C $RepoRoot rev-parse HEAD) | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$head)) {
        throw 'Bootstrap checkout alignment failed while verifying HEAD.'
    }

    $headValue = ([string]$head).Trim()
    if (-not [string]::Equals($headValue, $targetCommit, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Bootstrap checkout alignment ended at '$headValue' instead of '$targetCommit'."
    }

    $requiredFiles = @(
        'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat',
        'SignallingWebServer\platform_scripts\cmd\start_dev_turn.bat',
        'SignallingWebServer\platform_scripts\powershell\invoke_provisioning_mode.ps1',
        'SignallingWebServer\platform_scripts\powershell\invoke_update_mode.ps1',
        'SignallingWebServer\platform_scripts\powershell\install_pixelstreaming_runtime.ps1',
        'SignallingWebServer\platform_scripts\powershell\watchdog.ps1'
    )

    foreach ($relativePath in $requiredFiles) {
        $candidate = Join-Path $RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Bootstrap checkout '$targetCommit' does not contain required bootstrap file '$relativePath'."
        }
    }

    Write-UpdateModeLog "Bootstrap checkout aligned to runtime artifact source commit '$targetCommit'."
}

function Schedule-DelayedStop {
    param(
        [int]$DelaySeconds
    )

    $scriptPath = Join-Path $PSScriptRoot 'stop_instance_after_delay.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-UpdateModeLog "Delayed stop script not found at '$scriptPath'. Manual cleanup may be required." 'WARN'
        return
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-DelaySeconds', $DelaySeconds
    ) -WindowStyle Hidden | Out-Null

    Write-UpdateModeLog "Scheduled delayed instance stop in $DelaySeconds seconds."
}

function Request-InstanceStop {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [int]$FallbackDelaySeconds = 15
    )

    try {
        & $AwsCli ec2 stop-instances --region $Region --instance-ids $InstanceId *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "AWS CLI exited with code $LASTEXITCODE."
        }

        Write-UpdateModeLog "Issued EC2 stop request for $InstanceId."
        return $true
    } catch {
        Write-UpdateModeLog "Failed to request EC2 stop for ${InstanceId}: $($_.Exception.Message). Scheduling delayed stop fallback." 'WARN'
        Schedule-DelayedStop -DelaySeconds $FallbackDelaySeconds
        return $false
    }
}

function Set-UpdatePhase {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [string]$Phase
    )

    try {
        Set-InstanceTags -AwsCli $AwsCli -Region $Region -InstanceId $InstanceId -Tags @{
            ScaleWorldUpdatePhase = $Phase
        }
    } catch {
        Write-UpdateModeLog "Failed to publish update phase '$Phase': $($_.Exception.Message)" 'WARN'
    }
}

function Publish-CurrentBuildTags {
    param(
        [string]$PublishScriptPath,
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [string]$CurrentReleaseStatePath
    )

    if (-not (Test-Path -LiteralPath $PublishScriptPath)) {
        Write-UpdateModeLog "Current build publish script not found at '$PublishScriptPath'." 'WARN'
        return $false
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PublishScriptPath -InstanceId $InstanceId -Region $Region -AwsCliPath $AwsCli -CurrentReleaseStatePath $CurrentReleaseStatePath
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    if ($LASTEXITCODE -eq 2) {
        Write-UpdateModeLog 'Current release metadata was not available after update validation. Falling back to zip filename tags.' 'WARN'
        return $false
    }

    Write-UpdateModeLog "Current build tag publish script failed with exit code $LASTEXITCODE. Falling back to zip filename tags." 'WARN'
    return $false
}

function Get-CurrentReleaseStateSnapshot {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Current release state file '$Path' was not found after update activation."
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Current release state file '$Path' could not be parsed after update activation. $($_.Exception.Message)"
    }
}

function Get-ReleaseStateSnapshot {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Path = $Path
        }
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{
            Exists = $true
            Path = $Path
            BuildId = if ($state.PSObject.Properties.Name -contains 'BuildId') { [string]$state.BuildId } else { '' }
            ZipKey = if ($state.PSObject.Properties.Name -contains 'ZipKey') { [string]$state.ZipKey } else { '' }
            ReleasePath = if ($state.PSObject.Properties.Name -contains 'ReleasePath') { [string]$state.ReleasePath } else { '' }
            PreparedPath = if ($state.PSObject.Properties.Name -contains 'PreparedPath') { [string]$state.PreparedPath } else { '' }
            ActivatedAtUtc = if ($state.PSObject.Properties.Name -contains 'ActivatedAtUtc') { [string]$state.ActivatedAtUtc } else { '' }
            DownloadedAtUtc = if ($state.PSObject.Properties.Name -contains 'DownloadedAtUtc') { [string]$state.DownloadedAtUtc } else { '' }
        }
    } catch {
        return [pscustomobject]@{
            Exists = $true
            Path = $Path
            ParseError = $_.Exception.Message
        }
    }
}

function Get-ActiveInstallTargetSnapshot {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Path = $Path
        }
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $isReparsePoint = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $target = $null
        if ($isReparsePoint) {
            $parent = Split-Path -Parent $Path
            $leaf = Split-Path -Leaf $Path
            $output = cmd /c dir /AL "$parent" 2>$null
            foreach ($line in $output) {
                if ($line -match ([regex]::Escape($leaf) + '\s+\[(.+)\]')) {
                    $target = $matches[1]
                    break
                }
            }
        }

        return [pscustomobject]@{
            Exists = $true
            Path = $Path
            IsReparsePoint = $isReparsePoint
            Target = $target
        }
    } catch {
        return [pscustomobject]@{
            Exists = $true
            Path = $Path
            ReadError = $_.Exception.Message
        }
    }
}

function Get-LogTail {
    param(
        [string]$Path,
        [int]$Tail = 20
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $lines = @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop)
        if ($lines.Count -eq 0) {
            return $null
        }

        return ($lines -join [Environment]::NewLine).Trim()
    } catch {
        return $null
    }
}

function Invoke-RuntimeInstallerProcess {
    param(
        [string[]]$Arguments,
        [string]$StdOutPath,
        [string]$StdErrPath,
        [string]$FailureContext
    )

    foreach ($path in @($StdOutPath, $StdErrPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $Arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath

    $exitCode = $process.ExitCode
    if ($exitCode -ne 0) {
        $stdOutTail = Get-LogTail -Path $StdOutPath -Tail 80
        $stdErrTail = Get-LogTail -Path $StdErrPath -Tail 80
        $detail = @($stdErrTail, $stdOutTail) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        $exitCodeText = if ($null -eq $exitCode) { 'unknown' } else { [string]$exitCode }
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            throw "$FailureContext exited with code $exitCodeText. Last output: $detail"
        }

        throw "$FailureContext exited with code $exitCodeText."
    }
}

function ConvertTo-EncodedPowerShellCommand {
    param([string]$Script)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Script)
    return [Convert]::ToBase64String($bytes)
}

function Enter-UpdateModeLock {
    param(
        [string]$Name
    )

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $Name, [ref]$createdNew)
    $acquired = $false

    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }

    return [pscustomobject]@{
        Mutex = $mutex
        Acquired = $acquired
    }
}

function Exit-UpdateModeLock {
    param(
        [object]$Handle
    )

    if ($null -eq $Handle -or $null -eq $Handle.Mutex) {
        return
    }

    try {
        if ($Handle.Acquired) {
            $Handle.Mutex.ReleaseMutex()
        }
    } catch {
        Write-UpdateModeLog "Failed to release update-mode lock: $($_.Exception.Message)" 'WARN'
    } finally {
        try {
            $Handle.Mutex.Dispose()
        } catch {
        }
    }
}

function Parse-UtcTimestamp {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }

    return $null
}

function Get-VisiblePrepareWindowEnabled {
    if (-not [string]::IsNullOrWhiteSpace($env:SCALEWORLD_UPDATE_PREPARE_VISIBLE)) {
        return [System.Boolean]::Parse($env:SCALEWORLD_UPDATE_PREPARE_VISIBLE)
    }

    return $false
}

function Stop-ProcessIfRunning {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
        }
    } catch {
        Write-UpdateModeLog "Failed to stop background process $($Process.Id): $($_.Exception.Message)" 'WARN'
    }
}

function Get-ValidationProcessMatches {
    param(
        [string]$NamePattern,
        [string[]]$CommandLinePatterns = @()
    )

    $resolvedCommandLinePatterns = @(
        $CommandLinePatterns | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    return @(
        Get-CimInstance Win32_Process | Where-Object {
            if ([int]$_.ProcessId -eq $PID) {
                return $false
            }

            if (-not ([string]$_.Name -like $NamePattern)) {
                return $false
            }

            if ($resolvedCommandLinePatterns.Count -eq 0) {
                return $true
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

function Stop-ValidationProcessMatches {
    param(
        [string]$Label,
        [string]$NamePattern,
        [string[]]$CommandLinePatterns = @()
    )

    $matches = @(Get-ValidationProcessMatches -NamePattern $NamePattern -CommandLinePatterns $CommandLinePatterns)
    foreach ($match in $matches) {
        try {
            Write-UpdateModeLog "Stopping existing $Label process $($match.Name) (PID=$($match.ProcessId)) before validation."
            Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
        } catch {
            $remaining = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $match.ProcessId) -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($remaining) {
                Write-UpdateModeLog "Failed to stop existing $Label process $($match.Name) (PID=$($match.ProcessId)): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Wait-ForValidationProcessAbsence {
    param(
        [string]$Label,
        [string]$NamePattern,
        [string[]]$CommandLinePatterns = @(),
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $matches = @(Get-ValidationProcessMatches -NamePattern $NamePattern -CommandLinePatterns $CommandLinePatterns)
        if ($matches.Count -eq 0) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    $remaining = @(Get-ValidationProcessMatches -NamePattern $NamePattern -CommandLinePatterns $CommandLinePatterns)
    if ($remaining.Count -gt 0) {
        $summary = ($remaining | ForEach-Object { "$($_.Name) PID=$($_.ProcessId)" }) -join ', '
        Write-UpdateModeLog "Existing $Label processes still running before validation: $summary" 'WARN'
    }

    return $remaining.Count -eq 0
}

function Stop-ExistingStreamerStackForValidation {
    Stop-ValidationProcessMatches -Label 'watchdog' -NamePattern 'powershell.exe' -CommandLinePatterns @('*watchdog.ps1*')
    Stop-ValidationProcessMatches -Label 'watchdog-launcher' -NamePattern 'cmd.exe' -CommandLinePatterns @('*start_watchdog.bat*')
    Stop-ValidationProcessMatches -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePatterns @('*index.js*')
    Stop-ValidationProcessMatches -Label 'wilbur-launcher' -NamePattern 'cmd.exe' -CommandLinePatterns @('*start_dev_turn.bat*')
    Stop-ValidationProcessMatches -Label 'unreal-wrapper' -NamePattern 'powershell.exe' -CommandLinePatterns @('*start_scaleworld.ps1*')
    Stop-ValidationProcessMatches -Label 'unreal-launcher' -NamePattern 'cmd.exe' -CommandLinePatterns @('*start_unreal.bat*')
    Stop-ValidationProcessMatches -Label 'unreal' -NamePattern 'ScaleWorld*.exe'

    [void](Wait-ForValidationProcessAbsence -Label 'wilbur' -NamePattern 'node.exe' -CommandLinePatterns @('*index.js*') -TimeoutSeconds 15)
    [void](Wait-ForValidationProcessAbsence -Label 'unreal' -NamePattern 'ScaleWorld*.exe' -TimeoutSeconds 20)
}

function Get-StreamerHealthSnapshot {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Wait-ForStreamerValidation {
    param(
        [string]$HealthPath,
        [int]$TimeoutSeconds,
        [int]$StableSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $healthySince = $null

    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-StreamerHealthSnapshot -Path $HealthPath
        $isHealthy =
            $snapshot -and
            [string]$snapshot.status -eq 'ready' -and
            $snapshot.healthy -eq $true -and
            [int]$snapshot.streamerCount -gt 0

        if ($isHealthy) {
            if (-not $healthySince) {
                $healthySince = Get-Date
            }

            if (((Get-Date) - $healthySince).TotalSeconds -ge $StableSeconds) {
                return $true
            }
        } else {
            $healthySince = $null
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

function Wait-ForRuntimeStatusValidation {
    param(
        [string]$AwsCli,
        [string]$Region,
        [string]$InstanceId,
        [DateTimeOffset]$ValidationStartedAtUtc,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    $minimumObservedAtUtc = $ValidationStartedAtUtc.AddSeconds(-5)
    $lastSummary = 'no_runtime_status_observed'

    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        try {
            $tags = Get-InstanceTags -AwsCli $AwsCli -Region $Region -InstanceId $InstanceId
            $status = ([string]$tags['ScaleWorldRuntimeStatus']).Trim().ToLowerInvariant()
            $source = ([string]$tags['ScaleWorldRuntimeStatusSource']).Trim().ToLowerInvariant()
            $statusAtUtc = Parse-UtcTimestamp ([string]$tags['ScaleWorldRuntimeStatusAtUtc'])
            $heartbeatAtUtc = Parse-UtcTimestamp ([string]$tags['ScaleWorldRuntimeStatusHeartbeatAtUtc'])

            $lastSummary = "status='$status'; source='$source'; statusAtUtc='$statusAtUtc'; heartbeatAtUtc='$heartbeatAtUtc'"

            $hasFreshObservation = ($statusAtUtc -and $statusAtUtc -ge $minimumObservedAtUtc) -or
                ($heartbeatAtUtc -and $heartbeatAtUtc -ge $minimumObservedAtUtc)

            if ($status -eq 'ready' -and $source -eq 'signalling-server' -and $hasFreshObservation) {
                return [pscustomobject]@{
                    Success = $true
                    Summary = $lastSummary
                }
            }
        } catch {
            $lastSummary = "failed_to_read_runtime_tags: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        Success = $false
        Summary = $lastSummary
    }
}

function Get-UpdateTagValue {
    param(
        [hashtable]$Tags,
        [string]$Key
    )

    $value = [string]$Tags[$Key]
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }

    return $value.Trim()
}

function Get-UpdateTargetType {
    param(
        [hashtable]$Tags,
        [string]$TargetZipKey,
        [string]$TargetRuntimeManifestKey
    )

    $targetType = (Get-UpdateTagValue -Tags $Tags -Key 'ScaleWorldUpdateTargetType').ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($targetType)) {
        return $targetType
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetRuntimeManifestKey) -and -not [string]::IsNullOrWhiteSpace($TargetZipKey)) {
        return 'combined_runtime_unreal'
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetRuntimeManifestKey)) {
        return 'pixelstreaming_runtime'
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetZipKey)) {
        return 'unreal_zip'
    }

    return 'unreal_zip'
}

function Get-ActiveRuntimeStackLauncher {
    param([string]$InstallBasePath)

    $activeRuntimeRoot = Join-Path $InstallBasePath 'PixelStreamingRuntime'
    $launcher = Join-Path $activeRuntimeRoot 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
    if (Test-Path -LiteralPath $launcher) {
        return $launcher
    }

    return $null
}

function Start-ValidationStack {
    param(
        [string]$LauncherPath,
        [switch]$RuntimeArtifact
    )

    $previousDeliveryMode = $env:SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE
    if ($RuntimeArtifact) {
        $env:SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE = 'runtime_artifact'
    }

    try {
        Start-Process -FilePath $LauncherPath -ArgumentList '--validation' -WindowStyle Hidden | Out-Null
    } finally {
        if ($RuntimeArtifact) {
            if ($null -eq $previousDeliveryMode) {
                Remove-Item Env:\SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE -ErrorAction SilentlyContinue
            } else {
                $env:SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE = $previousDeliveryMode
            }
        }
    }
}

$detectionDeadline = (Get-Date).AddSeconds([Math]::Max($DetectionTimeoutSeconds, 1))
$attempt = 0
$awsCli = $null
$identity = $null
$instanceTags = $null
$updateModeLock = $null

while ($true) {
    $attempt++

    try {
        $awsCli = Get-AwsCliPath
        $identity = Get-InstanceIdentity
        $instanceTags = Get-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId

        $maintenanceMode = ([string]$instanceTags['ScaleWorldMaintenanceMode']).Trim().ToLowerInvariant()
        if ($maintenanceMode -ne 'update') {
            Write-UpdateModeLog 'No update maintenance mode requested. Continuing with normal startup.'
            exit 0
        }

        break
    } catch {
        $message = $_.Exception.Message

        if ((Get-Date) -ge $detectionDeadline) {
            Write-UpdateModeLog "Update maintenance state could not be confirmed within $DetectionTimeoutSeconds seconds. Continuing with normal startup. Last error: $message" 'WARN'
            exit 0
        }

        Write-UpdateModeLog "Update maintenance state not confirmed yet (attempt $attempt): $message" 'WARN'
        Start-Sleep -Seconds ([Math]::Max($RetryDelaySeconds, 1))
    }
}

$updateModeLock = Enter-UpdateModeLock -Name 'Global\ScaleWorldUpdateMode'
if (-not $updateModeLock.Acquired) {
    Write-UpdateModeLog 'Another update-mode process is already running. Leaving this invocation in maintenance hold.' 'WARN'
    exit 11
}

$currentUpdateState = ([string]$instanceTags['ScaleWorldUpdateState']).Trim().ToLowerInvariant()
if ($currentUpdateState -in @('succeeded', 'failed', 'stopping')) {
    Write-UpdateModeLog "Maintenance update is already in terminal state '$currentUpdateState'. Waiting for API reconciliation or explicit retry."
    exit 11
}

$targetZipKey = Get-UpdateTagValue -Tags $instanceTags -Key 'ScaleWorldTargetZipKey'
$targetRuntimeManifestKey = Get-UpdateTagValue -Tags $instanceTags -Key 'ScaleWorldTargetRuntimeManifestKey'
$targetRuntimeArtifactKey = Get-UpdateTagValue -Tags $instanceTags -Key 'ScaleWorldTargetRuntimeArtifactKey'
$targetRuntimeBundleId = Get-UpdateTagValue -Tags $instanceTags -Key 'ScaleWorldTargetRuntimeBundleId'
$targetRuntimeSourceCommit = Get-UpdateTagValue -Tags $instanceTags -Key 'ScaleWorldTargetRuntimeSourceCommit'
$targetRuntimeContractVersion = Get-UpdateTagValue -Tags $instanceTags -Key 'ScaleWorldTargetRuntimeContractVersion'
$updateTargetType = Get-UpdateTargetType -Tags $instanceTags -TargetZipKey $targetZipKey -TargetRuntimeManifestKey $targetRuntimeManifestKey
$pixelStreamingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$updateScript = Join-Path $pixelStreamingRoot 'SWupdate.ps1'
$stackLauncher = Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat'
$streamerHealthPath = Join-Path $pixelStreamingRoot 'SignallingWebServer\state\streamer-health.json'
$repoSyncScript = Join-Path $PSScriptRoot 'ensure_repo_current.ps1'
$publishCurrentBuildScript = Join-Path $PSScriptRoot 'publish_current_build_tags.ps1'
$runtimeInstallerScript = Join-Path $PSScriptRoot 'install_pixelstreaming_runtime.ps1'
$installBasePath = if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }
$runtimeArtifactBucket = if ($env:SCALEWORLD_RUNTIME_ARTIFACT_BUCKET) { $env:SCALEWORLD_RUNTIME_ARTIFACT_BUCKET } else { 'scaleworlddepot' }
$activeInstallPath = Join-Path $installBasePath 'WindowsNoEditor'
$currentReleaseStatePath = Join-Path $installBasePath 'state\current-release.json'
$pendingReleaseStatePath = Join-Path $installBasePath 'state\pending-release.json'
$runtimeInstallResultPath = Join-Path $installBasePath 'state\runtime-install-result.json'
$script:UpdateModeTracePath = Join-Path $installBasePath 'state\update-mode-trace.log'
$runtimePrepareStdOutPath = Join-Path $installBasePath 'state\runtime-prepare.stdout.log'
$runtimePrepareStdErrPath = Join-Path $installBasePath 'state\runtime-prepare.stderr.log'
$runtimeInstallStdOutPath = Join-Path $installBasePath 'state\runtime-install.stdout.log'
$runtimeInstallStdErrPath = Join-Path $installBasePath 'state\runtime-install.stderr.log'
$prepareUpdateStdOutPath = Join-Path $installBasePath 'state\update-prepare.stdout.log'
$prepareUpdateStdErrPath = Join-Path $installBasePath 'state\update-prepare.stderr.log'
$runtimePrepareProcess = $null
$prepareUpdateProcess = $null
$installResult = $null
$installedBundleId = ''
$installedArtifactKey = ''
$installedSourceCommit = ''
$installedSourceRef = ''
$installedContractVersion = ''
$runtimeStackLauncher = $null
$runtimeStreamerHealthPath = $null
$showVisiblePrepareWindow = Get-VisiblePrepareWindowEnabled

$prepareDataDrive = if ($env:STACK_PREPARE_DATA_DRIVE) { [System.Boolean]::Parse($env:STACK_PREPARE_DATA_DRIVE) } else { $true }
$requireDataDrive = if ($env:STACK_REQUIRE_DATA_DRIVE) { [System.Boolean]::Parse($env:STACK_REQUIRE_DATA_DRIVE) } else { $false }
$dataDiskNumber = if ($env:SCALEWORLD_DATA_DISK_NUMBER) { [int]$env:SCALEWORLD_DATA_DISK_NUMBER } else { 1 }

$hasUnrealPayload = $updateTargetType -eq 'unreal_zip' -or $updateTargetType -eq 'combined_runtime_unreal'
$hasRuntimePayload = $updateTargetType -eq 'pixelstreaming_runtime' -or $updateTargetType -eq 'combined_runtime_unreal'

if (-not $hasUnrealPayload -and -not $hasRuntimePayload) {
    Schedule-DelayedStop -DelaySeconds $FailureStopDelaySeconds
    TrySet-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'failed'
        ScaleWorldUpdatePhase = ''
        ScaleWorldUpdateResultReason = "unsupported_update_target_type:$updateTargetType"
        ScaleWorldUpdateCompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    } -FailureContext "Failed to publish unsupported update target failure state."
    Write-UpdateModeLog "Update maintenance mode requested unsupported target type '$updateTargetType'." 'ERROR'
    exit 11
}

if ($hasUnrealPayload -and [string]::IsNullOrWhiteSpace($targetZipKey)) {
    Schedule-DelayedStop -DelaySeconds $FailureStopDelaySeconds
    TrySet-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'failed'
        ScaleWorldUpdatePhase = ''
        ScaleWorldUpdateResultReason = 'missing_target_zip'
        ScaleWorldUpdateCompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    } -FailureContext "Failed to publish missing target zip failure state."
    Write-UpdateModeLog 'Update maintenance mode was requested without ScaleWorldTargetZipKey.' 'ERROR'
    exit 11
}

if ($hasRuntimePayload -and [string]::IsNullOrWhiteSpace($targetRuntimeManifestKey)) {
    Schedule-DelayedStop -DelaySeconds $FailureStopDelaySeconds
    TrySet-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'failed'
        ScaleWorldUpdatePhase = ''
        ScaleWorldUpdateResultReason = 'missing_runtime_manifest'
        ScaleWorldUpdateCompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    } -FailureContext "Failed to publish missing runtime manifest failure state."
    Write-UpdateModeLog 'PixelStreaming runtime update was requested without ScaleWorldTargetRuntimeManifestKey.' 'ERROR'
    exit 11
}

$zipFileName = if ($targetZipKey) { Split-Path -Leaf $targetZipKey } else { '' }
$initialPhase = if ($updateTargetType -eq 'pixelstreaming_runtime') {
    'installing_runtime'
} elseif ($updateTargetType -eq 'combined_runtime_unreal') {
    'preparing_payloads'
} else {
    'syncing_repo'
}
Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
    ScaleWorldUpdateState = 'running'
    ScaleWorldUpdatePhase = $initialPhase
    ScaleWorldUpdateResultReason = ''
    ScaleWorldUpdateCompletedAtUtc = ''
}

try {
    Write-UpdateModeTrace -Step 'update_mode_started' -Data @{
        TargetType = $updateTargetType
        TargetZipKey = $targetZipKey
        TargetRuntimeManifestKey = $targetRuntimeManifestKey
        TargetRuntimeBundleId = $targetRuntimeBundleId
        CurrentRelease = Get-ReleaseStateSnapshot -Path $currentReleaseStatePath
        PendingRelease = Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath
        ActiveInstall = Get-ActiveInstallTargetSnapshot -Path $activeInstallPath
        VisiblePrepareWindow = $showVisiblePrepareWindow
    }

    if ($prepareDataDrive) {
        $dataDriveScript = Join-Path $PSScriptRoot 'ensure_data_drive.ps1'
        if (Test-Path -LiteralPath $dataDriveScript) {
            Write-UpdateModeLog 'Preparing data drive for update mode.'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dataDriveScript -DataDiskNumber $dataDiskNumber -SkipIfUnavailable
            if ($LASTEXITCODE -ne 0) {
                if ($requireDataDrive) {
                    throw "Data drive preparation failed with code $LASTEXITCODE."
                }

                Write-UpdateModeLog "Data drive preparation failed with code $LASTEXITCODE. Continuing without prepared data drive." 'WARN'
            }
        } else {
            Write-UpdateModeLog "Data drive script not found at '$dataDriveScript'. Continuing without prepared data drive." 'WARN'
        }
    }

    if ($hasRuntimePayload -and -not $hasUnrealPayload) {
        if (-not (Test-Path -LiteralPath $runtimeInstallerScript)) {
            throw "PixelStreaming runtime installer not found at '$runtimeInstallerScript'."
        }

        if (Test-Path -LiteralPath $runtimeInstallResultPath) {
            Remove-Item -LiteralPath $runtimeInstallResultPath -Force
        }

        Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'installing_runtime'
        Write-UpdateModeLog "Installing PixelStreaming runtime artifact '$targetRuntimeManifestKey'."
        Write-UpdateModeTrace -Step 'before_runtime_install' -Data @{
            TargetRuntimeManifestKey = $targetRuntimeManifestKey
            TargetRuntimeBundleId = $targetRuntimeBundleId
        }

        Write-UpdateModeLog 'Stopping existing streamer stack before PixelStreaming runtime activation.'
        Stop-ExistingStreamerStackForValidation

        $runtimeInstallArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $runtimeInstallerScript,
            '-BucketName', $runtimeArtifactBucket,
            '-ManifestS3Key', $targetRuntimeManifestKey,
            '-Region', $identity.Region,
            '-InstallRoot', $installBasePath,
            '-ResultPath', $runtimeInstallResultPath,
            '-Activate'
        )
        Invoke-RuntimeInstallerProcess `
            -Arguments $runtimeInstallArgs `
            -StdOutPath $runtimeInstallStdOutPath `
            -StdErrPath $runtimeInstallStdErrPath `
            -FailureContext 'install_pixelstreaming_runtime.ps1'

        $installResult = Get-Content -LiteralPath $runtimeInstallResultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $installedBundleId = if (-not [string]::IsNullOrWhiteSpace($targetRuntimeBundleId)) { $targetRuntimeBundleId } else { [string]$installResult.BundleId }
        $installedArtifactKey = if (-not [string]::IsNullOrWhiteSpace($targetRuntimeArtifactKey)) { $targetRuntimeArtifactKey } else { [string]$installResult.RuntimeZipKey }
        $installedSourceCommit = Get-ObjectPropertyValue -InputObject $installResult -Name 'SourceCommit'
        $installedSourceRef = Get-ObjectPropertyValue -InputObject $installResult -Name 'SourceRef'
        $installedContractVersion = if (-not [string]::IsNullOrWhiteSpace($targetRuntimeContractVersion)) { $targetRuntimeContractVersion } else { [string]$installResult.ContractVersion }
        $activeRuntimeRoot = [string]$installResult.ActiveRoot
        $runtimeStreamerHealthPath = if (-not [string]::IsNullOrWhiteSpace($activeRuntimeRoot)) {
            Join-Path $activeRuntimeRoot 'SignallingWebServer\state\streamer-health.json'
        } else {
            $streamerHealthPath
        }

        $runtimeStackLauncher = Get-ActiveRuntimeStackLauncher -InstallBasePath $installBasePath
        if ([string]::IsNullOrWhiteSpace($runtimeStackLauncher)) {
            throw "Active PixelStreaming runtime launcher was not found under '$installBasePath\PixelStreamingRuntime'."
        }

        Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
            ScaleWorldUpdateState = 'validating'
            ScaleWorldUpdatePhase = 'validating'
            ScaleWorldUpdateResultReason = ''
            ScaleWorldUpdateCompletedAtUtc = ''
        }

        if (Test-Path -LiteralPath $runtimeStreamerHealthPath) {
            Remove-Item -LiteralPath $runtimeStreamerHealthPath -Force
        }

        Stop-ExistingStreamerStackForValidation

        Write-UpdateModeLog "Launching validation stack for PixelStreaming runtime '$installedBundleId'."
        $validationStartedAtUtc = (Get-Date).ToUniversalTime()
        Start-ValidationStack -LauncherPath $runtimeStackLauncher -RuntimeArtifact

        Write-UpdateModeLog "Waiting up to $ValidationTimeoutSeconds seconds for streamer validation."
        $validated = Wait-ForStreamerValidation -HealthPath $runtimeStreamerHealthPath -TimeoutSeconds $ValidationTimeoutSeconds -StableSeconds $ValidationStableSeconds
        if (-not $validated) {
            throw "PixelStreaming runtime artifact failed validation within $ValidationTimeoutSeconds seconds."
        }

        Write-UpdateModeLog "Waiting up to $RuntimeStatusValidationTimeoutSeconds seconds for EC2 runtime status validation."
        $runtimeStatusValidated = Wait-ForRuntimeStatusValidation `
            -AwsCli $awsCli `
            -Region $identity.Region `
            -InstanceId $identity.InstanceId `
            -ValidationStartedAtUtc $validationStartedAtUtc `
            -TimeoutSeconds $RuntimeStatusValidationTimeoutSeconds
        if (-not $runtimeStatusValidated.Success) {
            throw "EC2 runtime status validation did not reach ready within $RuntimeStatusValidationTimeoutSeconds seconds. Last observed: $($runtimeStatusValidated.Summary)"
        }

        Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'syncing_bootstrap'
        Invoke-BootstrapCheckoutAlignment -RepoRoot $pixelStreamingRoot -SourceCommit $installedSourceCommit -SourceRef $installedSourceRef

        $completionTime = (Get-Date).ToUniversalTime().ToString('o')
        $successTags = @{
            ScaleWorldUpdateState = 'succeeded'
            ScaleWorldUpdatePhase = ''
            ScaleWorldUpdateResultReason = 'validated_runtime_artifact'
            ScaleWorldUpdateCompletedAtUtc = $completionTime
            ScaleWorldLastUpdatedAtUtc = $completionTime
            ScaleWorldPixelStreamingDeliveryMode = 'runtime_artifact'
            ScaleWorldPixelStreamingRuntimeManifestKey = $targetRuntimeManifestKey
            ScaleWorldPixelStreamingUpdateCapabilities = 'pixelstreaming_runtime,combined_runtime_unreal'
        }
        if (-not [string]::IsNullOrWhiteSpace($installedBundleId)) {
            $successTags['ScaleWorldPixelStreamingRuntimeBundleId'] = $installedBundleId
            $successTags['ScaleWorldPixelStreamingVersion'] = $installedBundleId
        }
        if (-not [string]::IsNullOrWhiteSpace($installedArtifactKey)) {
            $successTags['ScaleWorldPixelStreamingRuntimeArtifactKey'] = $installedArtifactKey
        }
        if (-not [string]::IsNullOrWhiteSpace($installedSourceCommit)) {
            $successTags['ScaleWorldPixelStreamingRuntimeSourceCommit'] = $installedSourceCommit
        }
        if (-not [string]::IsNullOrWhiteSpace($installedContractVersion)) {
            $successTags['ScaleWorldPixelStreamingRuntimeContractVersion'] = $installedContractVersion
        }

        Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags $successTags
        Write-UpdateModeTrace -Step 'after_runtime_validation' -Data @{
            TargetRuntimeManifestKey = $targetRuntimeManifestKey
            RuntimeStatusSummary = $runtimeStatusValidated.Summary
            InstalledBundleId = $installedBundleId
            InstalledArtifactKey = $installedArtifactKey
        }

        Write-UpdateModeLog "PixelStreaming runtime '$installedBundleId' validated successfully. Requesting instance stop and leaving Fleet command tags for API reconciliation."
        Request-InstanceStop -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId | Out-Null
        exit 10
    }

    if ($hasRuntimePayload) {
        if (-not (Test-Path -LiteralPath $runtimeInstallerScript)) {
            throw "PixelStreaming runtime installer not found at '$runtimeInstallerScript'."
        }

        foreach ($path in @($runtimeInstallResultPath, $runtimePrepareStdOutPath, $runtimePrepareStdErrPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }

        Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'preparing_payloads'
        Write-UpdateModeLog "Preparing PixelStreaming runtime artifact '$targetRuntimeManifestKey' in parallel with Unreal update preparation."
        Write-UpdateModeTrace -Step 'before_runtime_prepare' -Data @{
            TargetRuntimeManifestKey = $targetRuntimeManifestKey
            TargetRuntimeBundleId = $targetRuntimeBundleId
        }

        $runtimePrepareArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $runtimeInstallerScript,
            '-BucketName', $runtimeArtifactBucket,
            '-ManifestS3Key', $targetRuntimeManifestKey,
            '-Region', $identity.Region,
            '-InstallRoot', $installBasePath,
            '-ResultPath', $runtimeInstallResultPath
        )
        $runtimePrepareProcess = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $runtimePrepareArgs `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $runtimePrepareStdOutPath `
            -RedirectStandardError $runtimePrepareStdErrPath
    }

    if (-not (Test-Path -LiteralPath $repoSyncScript)) {
        throw "Repo sync helper not found at '$repoSyncScript'."
    }

    Write-UpdateModeLog 'Preparing PixelStreaming repo/bootstrap state before Unreal update.'
    & $repoSyncScript -RepoRoot $pixelStreamingRoot -Mode 'update' -PhaseAwsCli $awsCli -PhaseRegion $identity.Region -PhaseInstanceId $identity.InstanceId -BuildingUpdatePhase 'building_pixelstreaming'
    if ($LASTEXITCODE -ne 0) {
        throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $updateScript)) {
        throw "SWupdate.ps1 not found at '$updateScript'."
    }

    if (Test-Path -LiteralPath $pendingReleaseStatePath) {
        Remove-Item -LiteralPath $pendingReleaseStatePath -Force
    }
    foreach ($path in @($prepareUpdateStdOutPath, $prepareUpdateStdErrPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $updateArgs = @('-ZipKey', $targetZipKey)
    if ($AllowUnchanged) {
        $updateArgs += '-AllowUnchanged'
    }

    $prepareUpdateArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $updateScript
    ) + $updateArgs + @('-PrepareReleaseOnly')

    Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'preparing_release'
    Write-UpdateModeLog "Preparing Unreal update payload for '$zipFileName' in parallel with PixelStreaming repo sync."
    if ($showVisiblePrepareWindow) {
        $quotedUpdateScript = $updateScript.Replace("'", "''")
        $quotedZipKey = $targetZipKey.Replace("'", "''")
        $quotedStdOutPath = $prepareUpdateStdOutPath.Replace("'", "''")
        $allowUnchangedLiteral = if ($AllowUnchanged) { '$true' } else { '$false' }
        $prepareCommand = @(
            ("`$args = @('-ZipKey', '{0}', '-PrepareReleaseOnly')" -f $quotedZipKey),
            ("if ({0}) {{" -f $allowUnchangedLiteral),
            "    `$args += '-AllowUnchanged'",
            "}",
            ("& '{0}' @args 2>&1 | Tee-Object -FilePath '{1}' -Append" -f $quotedUpdateScript, $quotedStdOutPath),
            'exit $LASTEXITCODE'
        ) -join "`r`n"
        $encodedPrepareCommand = ConvertTo-EncodedPowerShellCommand -Script $prepareCommand
        $prepareUpdateProcess = Start-Process `
            -FilePath 'cmd.exe' `
            -ArgumentList @('/c', "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedPrepareCommand") `
            -WindowStyle Normal `
            -PassThru
    } else {
        $prepareUpdateProcess = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $prepareUpdateArgs `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $prepareUpdateStdOutPath `
            -RedirectStandardError $prepareUpdateStdErrPath
    }

    Write-UpdateModeLog 'Preparing PixelStreaming repo/bootstrap state before Unreal activation.'
    & $repoSyncScript -RepoRoot $pixelStreamingRoot -Mode 'update' -PhaseAwsCli $awsCli -PhaseRegion $identity.Region -PhaseInstanceId $identity.InstanceId -BuildingUpdatePhase 'building_pixelstreaming'
    if ($LASTEXITCODE -ne 0) {
        throw "ensure_repo_current.ps1 exited with code $LASTEXITCODE."
    }

    Write-UpdateModeLog "Waiting for Unreal update payload preparation for '$zipFileName' to finish."
    $prepareUpdateProcess.WaitForExit()
    try {
        $prepareUpdateProcess.Refresh()
    } catch {
    }

    $prepareExitCode = $prepareUpdateProcess.ExitCode
    $preparedReleaseState = if (Test-Path -LiteralPath $pendingReleaseStatePath) {
        Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath
    } else {
        $null
    }
    $preparedReleaseZipKey = if ($preparedReleaseState -and $preparedReleaseState.PSObject.Properties.Name -contains 'ZipKey') {
        [string]$preparedReleaseState.ZipKey
    } else {
        ''
    }
    $preparedReleasePath = if ($preparedReleaseState -and $preparedReleaseState.PSObject.Properties.Name -contains 'PreparedPath') {
        [string]$preparedReleaseState.PreparedPath
    } else {
        ''
    }
    $hasPreparedReleaseForTarget = `
        $preparedReleaseState `
        -and -not [string]::IsNullOrWhiteSpace($preparedReleaseZipKey) `
        -and [string]::Equals($preparedReleaseZipKey.Trim(), $targetZipKey.Trim(), [System.StringComparison]::Ordinal) `
        -and -not [string]::IsNullOrWhiteSpace($preparedReleasePath) `
        -and (Test-Path -LiteralPath $preparedReleasePath)

    $currentReleaseAfterPrepare = Get-CurrentReleaseStateSnapshot -Path $currentReleaseStatePath
    $currentReleaseZipKeyAfterPrepare = if ($currentReleaseAfterPrepare -and $currentReleaseAfterPrepare.PSObject.Properties.Name -contains 'ZipKey') {
        [string]$currentReleaseAfterPrepare.ZipKey
    } else {
        ''
    }
    $currentReleaseAlreadyMatchesTarget = -not [string]::IsNullOrWhiteSpace($currentReleaseZipKeyAfterPrepare) `
        -and [string]::Equals($currentReleaseZipKeyAfterPrepare.Trim(), $targetZipKey.Trim(), [System.StringComparison]::Ordinal)

    if ($null -eq $prepareExitCode -and ($hasPreparedReleaseForTarget -or $currentReleaseAlreadyMatchesTarget)) {
        $reason = if ($hasPreparedReleaseForTarget) { 'prepared release metadata' } else { 'current release metadata' }
        Write-UpdateModeLog "Prepare process did not report an exit code, but $reason for '$zipFileName' is present. Continuing with activation." 'WARN'
        $prepareExitCode = 0
    }

    if ($prepareExitCode -ne 0) {
        $stdOutTail = Get-LogTail -Path $prepareUpdateStdOutPath
        $stdErrTail = Get-LogTail -Path $prepareUpdateStdErrPath
        $detail = @($stdErrTail, $stdOutTail) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        $prepareExitCodeText = if ($null -eq $prepareExitCode) { 'unknown' } else { [string]$prepareExitCode }
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            throw "SWupdate preparation failed with exit code $prepareExitCodeText. Last output: $detail"
        }

        throw "SWupdate preparation failed with exit code $prepareExitCodeText."
    }

    if ($runtimePrepareProcess) {
        Write-UpdateModeLog "Waiting for PixelStreaming runtime artifact preparation for '$targetRuntimeManifestKey' to finish."
        $runtimePrepareProcess.WaitForExit()
        try {
            $runtimePrepareProcess.Refresh()
        } catch {
        }

        $runtimePrepareExitCode = $runtimePrepareProcess.ExitCode
        $hasRuntimeInstallResult = Test-Path -LiteralPath $runtimeInstallResultPath
        if ($null -eq $runtimePrepareExitCode -and $hasRuntimeInstallResult) {
            Write-UpdateModeLog "Runtime prepare process did not report an exit code, but '$runtimeInstallResultPath' is present. Continuing with activation." 'WARN'
            $runtimePrepareExitCode = 0
        }

        if ($runtimePrepareExitCode -ne 0) {
            $stdOutTail = Get-LogTail -Path $runtimePrepareStdOutPath
            $stdErrTail = Get-LogTail -Path $runtimePrepareStdErrPath
            $detail = @($stdErrTail, $stdOutTail) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            $runtimePrepareExitCodeText = if ($null -eq $runtimePrepareExitCode) { 'unknown' } else { [string]$runtimePrepareExitCode }
            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                throw "PixelStreaming runtime preparation failed with exit code $runtimePrepareExitCodeText. Last output: $detail"
            }

            throw "PixelStreaming runtime preparation failed with exit code $runtimePrepareExitCodeText."
        }

        if (-not $hasRuntimeInstallResult) {
            throw "PixelStreaming runtime preparation completed without writing '$runtimeInstallResultPath'."
        }

        $runtimePrepareProcess = $null
        Write-UpdateModeTrace -Step 'runtime_prepare_completed' -Data @{
            TargetRuntimeManifestKey = $targetRuntimeManifestKey
            RuntimePrepareExitCode = $runtimePrepareExitCode
        }
    }

    $prepareUpdateProcess = $null
    Write-UpdateModeTrace -Step 'prepare_release_completed' -Data @{
        TargetZipKey = $targetZipKey
        PrepareExitCode = $prepareExitCode
        PendingRelease = if ($preparedReleaseState) { $preparedReleaseState } else { Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath }
        CurrentRelease = Get-ReleaseStateSnapshot -Path $currentReleaseStatePath
        PrepareStdOutExists = (Test-Path -LiteralPath $prepareUpdateStdOutPath)
        PrepareStdErrExists = (Test-Path -LiteralPath $prepareUpdateStdErrPath)
    }

    if ($hasRuntimePayload) {
        Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'activating_runtime'
        Write-UpdateModeLog "Activating PixelStreaming runtime artifact '$targetRuntimeManifestKey'."
        Write-UpdateModeTrace -Step 'before_runtime_activation' -Data @{
            TargetRuntimeManifestKey = $targetRuntimeManifestKey
            TargetRuntimeBundleId = $targetRuntimeBundleId
        }

        Write-UpdateModeLog 'Stopping existing streamer stack before PixelStreaming runtime activation.'
        Stop-ExistingStreamerStackForValidation

        $runtimeInstallArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $runtimeInstallerScript,
            '-BucketName', $runtimeArtifactBucket,
            '-ManifestS3Key', $targetRuntimeManifestKey,
            '-Region', $identity.Region,
            '-InstallRoot', $installBasePath,
            '-ResultPath', $runtimeInstallResultPath,
            '-Activate'
        )
        Invoke-RuntimeInstallerProcess `
            -Arguments $runtimeInstallArgs `
            -StdOutPath $runtimeInstallStdOutPath `
            -StdErrPath $runtimeInstallStdErrPath `
            -FailureContext 'install_pixelstreaming_runtime.ps1 activation'

        $installResult = Get-Content -LiteralPath $runtimeInstallResultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $installedBundleId = if (-not [string]::IsNullOrWhiteSpace($targetRuntimeBundleId)) { $targetRuntimeBundleId } else { [string]$installResult.BundleId }
        $installedArtifactKey = if (-not [string]::IsNullOrWhiteSpace($targetRuntimeArtifactKey)) { $targetRuntimeArtifactKey } else { [string]$installResult.RuntimeZipKey }
        $installedSourceCommit = Get-ObjectPropertyValue -InputObject $installResult -Name 'SourceCommit'
        $installedSourceRef = Get-ObjectPropertyValue -InputObject $installResult -Name 'SourceRef'
        $installedContractVersion = if (-not [string]::IsNullOrWhiteSpace($targetRuntimeContractVersion)) { $targetRuntimeContractVersion } else { [string]$installResult.ContractVersion }
        $activeRuntimeRoot = [string]$installResult.ActiveRoot
        $runtimeStreamerHealthPath = if (-not [string]::IsNullOrWhiteSpace($activeRuntimeRoot)) {
            Join-Path $activeRuntimeRoot 'SignallingWebServer\state\streamer-health.json'
        } else {
            $streamerHealthPath
        }

        $runtimeStackLauncher = Get-ActiveRuntimeStackLauncher -InstallBasePath $installBasePath
        if ([string]::IsNullOrWhiteSpace($runtimeStackLauncher)) {
            throw "Active PixelStreaming runtime launcher was not found under '$installBasePath\PixelStreamingRuntime'."
        }
        Write-UpdateModeTrace -Step 'after_runtime_activation' -Data @{
            TargetRuntimeManifestKey = $targetRuntimeManifestKey
            InstalledBundleId = $installedBundleId
            InstalledArtifactKey = $installedArtifactKey
        }
    }

    if (Test-Path -LiteralPath $pendingReleaseStatePath) {
        Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'activating_release'
        Write-UpdateModeLog "Activating prepared build '$zipFileName'."
        Write-UpdateModeTrace -Step 'before_activation' -Data @{
            TargetZipKey = $targetZipKey
            CurrentRelease = Get-ReleaseStateSnapshot -Path $currentReleaseStatePath
            PendingRelease = Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath
            ActiveInstall = Get-ActiveInstallTargetSnapshot -Path $activeInstallPath
        }
        $activateUpdateArgs = @('-ZipKey', $targetZipKey, '-ActivatePreparedRelease')
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updateScript @activateUpdateArgs
    } else {
        $currentReleaseState = Get-CurrentReleaseStateSnapshot -Path $currentReleaseStatePath
        $alreadyActiveZipKey = [string]$currentReleaseState.ZipKey
        if ([string]::IsNullOrWhiteSpace($alreadyActiveZipKey)) {
            throw "Prepared release metadata was missing and current release state at '$currentReleaseStatePath' had no ZipKey for requested update '$targetZipKey'."
        }

        if (-not [string]::Equals($alreadyActiveZipKey.Trim(), $targetZipKey.Trim(), [System.StringComparison]::Ordinal)) {
            throw "Prepared release metadata was missing and current release state still reported zip '$alreadyActiveZipKey' instead of requested update '$targetZipKey'."
        }

        Write-UpdateModeLog "No prepared release activation was required for '$zipFileName' because the requested build is already active."
    }

    if ($LASTEXITCODE -ne 0) {
        throw "SWupdate.ps1 exited with code $LASTEXITCODE."
    }
    Write-UpdateModeTrace -Step 'after_activation' -Data @{
        TargetZipKey = $targetZipKey
        CurrentRelease = Get-ReleaseStateSnapshot -Path $currentReleaseStatePath
        PendingRelease = Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath
        ActiveInstall = Get-ActiveInstallTargetSnapshot -Path $activeInstallPath
    }

    Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'validating'
        ScaleWorldUpdatePhase = 'validating'
        ScaleWorldUpdateResultReason = ''
        ScaleWorldUpdateCompletedAtUtc = ''
    }

    $validationStackLauncher = if ($hasRuntimePayload -and -not [string]::IsNullOrWhiteSpace($runtimeStackLauncher)) {
        $runtimeStackLauncher
    } else {
        $stackLauncher
    }
    $validationHealthPath = if ($hasRuntimePayload -and -not [string]::IsNullOrWhiteSpace($runtimeStreamerHealthPath)) {
        $runtimeStreamerHealthPath
    } else {
        $streamerHealthPath
    }

    if (-not (Test-Path -LiteralPath $validationStackLauncher)) {
        throw "Validation stack launcher not found at '$validationStackLauncher'."
    }

    if (Test-Path -LiteralPath $validationHealthPath) {
        Remove-Item -LiteralPath $validationHealthPath -Force
    }

    if ($hasRuntimePayload) {
        Stop-ExistingStreamerStackForValidation
    }

    $validationTargetLabel = if ($hasRuntimePayload) { "$zipFileName + $installedBundleId" } else { $zipFileName }
    Write-UpdateModeLog "Launching validation stack for '$validationTargetLabel'."
    $validationStartedAtUtc = (Get-Date).ToUniversalTime()
    Start-ValidationStack -LauncherPath $validationStackLauncher -RuntimeArtifact:$hasRuntimePayload

    Write-UpdateModeLog "Waiting up to $ValidationTimeoutSeconds seconds for streamer validation."
    $validated = Wait-ForStreamerValidation -HealthPath $validationHealthPath -TimeoutSeconds $ValidationTimeoutSeconds -StableSeconds $ValidationStableSeconds
    if (-not $validated) {
        throw "Updated build failed validation within $ValidationTimeoutSeconds seconds."
    }

    Write-UpdateModeLog "Waiting up to $RuntimeStatusValidationTimeoutSeconds seconds for EC2 runtime status validation."
    $runtimeStatusValidated = Wait-ForRuntimeStatusValidation `
        -AwsCli $awsCli `
        -Region $identity.Region `
        -InstanceId $identity.InstanceId `
        -ValidationStartedAtUtc $validationStartedAtUtc `
        -TimeoutSeconds $RuntimeStatusValidationTimeoutSeconds
    if (-not $runtimeStatusValidated.Success) {
        throw "EC2 runtime status validation did not reach ready within $RuntimeStatusValidationTimeoutSeconds seconds. Last observed: $($runtimeStatusValidated.Summary)"
    }
    Write-UpdateModeTrace -Step 'after_validation' -Data @{
        TargetZipKey = $targetZipKey
        RuntimeStatusSummary = $runtimeStatusValidated.Summary
        CurrentRelease = Get-ReleaseStateSnapshot -Path $currentReleaseStatePath
        PendingRelease = Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath
        ActiveInstall = Get-ActiveInstallTargetSnapshot -Path $activeInstallPath
    }

    $currentReleaseState = Get-CurrentReleaseStateSnapshot -Path $currentReleaseStatePath
    $activatedZipKey = [string]$currentReleaseState.ZipKey
    if ([string]::IsNullOrWhiteSpace($activatedZipKey)) {
        throw "Current release state at '$currentReleaseStatePath' had no ZipKey after validation."
    }

    if (-not [string]::Equals($activatedZipKey.Trim(), $targetZipKey.Trim(), [System.StringComparison]::Ordinal)) {
        throw "Validated runtime is still reporting zip '$activatedZipKey' instead of requested update '$targetZipKey'."
    }

    if ($hasRuntimePayload) {
        Set-UpdatePhase -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Phase 'syncing_bootstrap'
        Invoke-BootstrapCheckoutAlignment -RepoRoot $pixelStreamingRoot -SourceCommit $installedSourceCommit -SourceRef $installedSourceRef
    }

    $completionTime = (Get-Date).ToUniversalTime().ToString('o')
    $publishedCurrentBuild = Publish-CurrentBuildTags -PublishScriptPath $publishCurrentBuildScript -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -CurrentReleaseStatePath $currentReleaseStatePath
    $successTags = @{
        ScaleWorldUpdateState = 'succeeded'
        ScaleWorldUpdatePhase = ''
        ScaleWorldUpdateResultReason = 'validated_streamer_connected'
        ScaleWorldUpdateCompletedAtUtc = $completionTime
    }
    if (-not $publishedCurrentBuild) {
        $successTags.ScaleWorldCurrentBuild = $zipFileName
        $successTags.ScaleWorldLastUpdatedAtUtc = $completionTime
    }
    if ($hasRuntimePayload) {
        $successTags.ScaleWorldLastUpdatedAtUtc = $completionTime
        $successTags.ScaleWorldPixelStreamingDeliveryMode = 'runtime_artifact'
        $successTags.ScaleWorldPixelStreamingRuntimeManifestKey = $targetRuntimeManifestKey
        $successTags.ScaleWorldPixelStreamingUpdateCapabilities = 'pixelstreaming_runtime,combined_runtime_unreal'
        if (-not [string]::IsNullOrWhiteSpace($installedBundleId)) {
            $successTags.ScaleWorldPixelStreamingRuntimeBundleId = $installedBundleId
            $successTags.ScaleWorldPixelStreamingVersion = $installedBundleId
        }
        if (-not [string]::IsNullOrWhiteSpace($installedArtifactKey)) {
            $successTags.ScaleWorldPixelStreamingRuntimeArtifactKey = $installedArtifactKey
        }
        if (-not [string]::IsNullOrWhiteSpace($installedSourceCommit)) {
            $successTags.ScaleWorldPixelStreamingRuntimeSourceCommit = $installedSourceCommit
        }
        if (-not [string]::IsNullOrWhiteSpace($installedContractVersion)) {
            $successTags.ScaleWorldPixelStreamingRuntimeContractVersion = $installedContractVersion
        }
    }
    Set-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags $successTags
    Write-UpdateModeLog "Update validated successfully for '$zipFileName'. Requesting instance stop and leaving Fleet command tags for API reconciliation."
    Request-InstanceStop -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId | Out-Null
    exit 10
} catch {
    Stop-ProcessIfRunning -Process $runtimePrepareProcess
    Stop-ProcessIfRunning -Process $prepareUpdateProcess
    $reason = $_.Exception.Message
    Write-UpdateModeTrace -Step 'update_failed' -Data @{
        TargetZipKey = $targetZipKey
        TargetRuntimeManifestKey = $targetRuntimeManifestKey
        Reason = $reason
        CurrentRelease = Get-ReleaseStateSnapshot -Path $currentReleaseStatePath
        PendingRelease = Get-ReleaseStateSnapshot -Path $pendingReleaseStatePath
        ActiveInstall = Get-ActiveInstallTargetSnapshot -Path $activeInstallPath
        RuntimePrepareStdOutExists = (Test-Path -LiteralPath $runtimePrepareStdOutPath)
        RuntimePrepareStdErrExists = (Test-Path -LiteralPath $runtimePrepareStdErrPath)
        RuntimeInstallStdOutExists = (Test-Path -LiteralPath $runtimeInstallStdOutPath)
        RuntimeInstallStdErrExists = (Test-Path -LiteralPath $runtimeInstallStdErrPath)
        PrepareStdOutExists = (Test-Path -LiteralPath $prepareUpdateStdOutPath)
        PrepareStdErrExists = (Test-Path -LiteralPath $prepareUpdateStdErrPath)
    }
    Schedule-DelayedStop -DelaySeconds $FailureStopDelaySeconds
    TrySet-InstanceTags -AwsCli $awsCli -Region $identity.Region -InstanceId $identity.InstanceId -Tags @{
        ScaleWorldUpdateState = 'failed'
        ScaleWorldUpdatePhase = ''
        ScaleWorldUpdateResultReason = $reason
        ScaleWorldUpdateCompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    } -FailureContext "Failed to publish update failure state."
    Write-UpdateModeLog "Update failed: $reason" 'ERROR'
    exit 11
} finally {
    Exit-UpdateModeLock -Handle $updateModeLock
}
