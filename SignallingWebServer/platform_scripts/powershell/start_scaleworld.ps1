[CmdletBinding()]
param(
    [string]$InstallRoot = $(if ($env:SCALEWORLD_INSTALL_ROOT) { $env:SCALEWORLD_INSTALL_ROOT } else { 'C:\PixelStreaming\WindowsNoEditor' }),
    [string]$ExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
    [string]$RuntimeProcessPattern = $(if ($env:SCALEWORLD_RUNTIME_PROCESS_PATTERN) { $env:SCALEWORLD_RUNTIME_PROCESS_PATTERN } else { '' }),
    [int]$RuntimeProcessWaitSeconds = $(if ($env:SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS) { [int]$env:SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS } else { 120 }),
    [string]$PixelStreamingIp = $(if ($env:SCALEWORLD_PIXEL_STREAMING_IP) { $env:SCALEWORLD_PIXEL_STREAMING_IP } else { 'localhost' }),
    [int]$PixelStreamingPort = $(if ($env:SCALEWORLD_PIXEL_STREAMING_PORT) { [int]$env:SCALEWORLD_PIXEL_STREAMING_PORT } else { 8888 }),
    [string]$EncoderCodec = $(if ($env:SCALEWORLD_ENCODER_CODEC) { $env:SCALEWORLD_ENCODER_CODEC } else { 'vp9' }),
    [int]$ResX = $(if ($env:SCALEWORLD_RES_X) { [int]$env:SCALEWORLD_RES_X } else { 2240 }),
    [int]$ResY = $(if ($env:SCALEWORLD_RES_Y) { [int]$env:SCALEWORLD_RES_Y } else { 1260 }),
    [int]$Fps = $(if ($env:SCALEWORLD_PIXEL_STREAMING_FPS) { [int]$env:SCALEWORLD_PIXEL_STREAMING_FPS } else { 30 }),
    [string]$WebRtcPortBankRotationEnabled = $(if ($env:SCALEWORLD_WEBRTC_PORT_BANK_ROTATION_ENABLED) { $env:SCALEWORLD_WEBRTC_PORT_BANK_ROTATION_ENABLED } else { 'true' }),
    [string]$WebRtcPortBankStatePath = $(if ($env:SCALEWORLD_WEBRTC_PORT_BANK_STATE_PATH) { $env:SCALEWORLD_WEBRTC_PORT_BANK_STATE_PATH } else { '' }),
    [int]$WebRtcPortRangeMin = $(if ($env:SCALEWORLD_WEBRTC_PORT_RANGE_MIN) { [int]$env:SCALEWORLD_WEBRTC_PORT_RANGE_MIN } else { 49152 }),
    [int]$WebRtcPortRangeMax = $(if ($env:SCALEWORLD_WEBRTC_PORT_RANGE_MAX) { [int]$env:SCALEWORLD_WEBRTC_PORT_RANGE_MAX } else { 65535 }),
    [int]$WebRtcPortBankSize = $(if ($env:SCALEWORLD_WEBRTC_PORT_BANK_SIZE) { [int]$env:SCALEWORLD_WEBRTC_PORT_BANK_SIZE } else { 256 }),
    [int]$WebRtcPortBankReuseCooldownSeconds = $(if ($env:SCALEWORLD_WEBRTC_PORT_BANK_REUSE_COOLDOWN_SECONDS) { [int]$env:SCALEWORLD_WEBRTC_PORT_BANK_REUSE_COOLDOWN_SECONDS } else { 660 }),
    [int]$WebRtcPortBankLockTimeoutSeconds = $(if ($env:SCALEWORLD_WEBRTC_PORT_BANK_LOCK_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_WEBRTC_PORT_BANK_LOCK_TIMEOUT_SECONDS } else { 30 }),
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ScaleWorldStrictBoolean {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$SettingName
    )

    switch ($Value.Trim().ToLowerInvariant()) {
        'true' { return $true }
        '1' { return $true }
        'false' { return $false }
        '0' { return $false }
        default {
            throw "webrtc_port_bank_configuration_invalid: $SettingName must be true, false, 1, or 0; got '$Value'."
        }
    }
}

$helperScriptPath = Join-Path $PSScriptRoot 'scaleworld_process_helpers.ps1'
if (-not (Test-Path -LiteralPath $helperScriptPath)) {
    throw "ScaleWorld process helper '$helperScriptPath' was not found."
}
. $helperScriptPath

$installRootEntry = Resolve-Path -LiteralPath $InstallRoot -ErrorAction Stop | Select-Object -First 1
$installRootPath = if ($installRootEntry -is [System.Management.Automation.PathInfo]) {
    $installRootEntry.ProviderPath
} else {
    [string]$installRootEntry
}
if ([string]::IsNullOrWhiteSpace($installRootPath)) {
    throw "ScaleWorld install root '$InstallRoot' could not be resolved to a filesystem path."
}

$processPath = Join-Path $installRootPath $ExecutableName
if (-not (Test-Path -LiteralPath $processPath)) {
    throw "ScaleWorld executable not found at '$processPath'."
}

$prerequisiteModulePath = Join-Path $PSScriptRoot 'unreal_prerequisite.psm1'
if (-not (Test-Path -LiteralPath $prerequisiteModulePath -PathType Leaf)) {
    throw "ScaleWorld prerequisite helper '$prerequisiteModulePath' was not found."
}
Import-Module $prerequisiteModulePath -Force -ErrorAction Stop

# Normal startup is deliberately check-only. Installation is restricted to the
# update pre-activation path so a serving start cannot mutate Windows or request
# a reboot. Failing here also prevents Unreal's bootstrap executable from opening
# an invisible interactive redistributable prompt.
$prerequisiteStatus = Assert-ScaleWorldUnrealPrerequisite -UnrealRoot $installRootPath -LauncherExecutableName $ExecutableName
Write-Output ("Verified Unreal Visual C++ prerequisite required={0} installed={1}." -f $prerequisiteStatus.RequiredVersion, $prerequisiteStatus.InstalledVersion)

$runtimeMatcher = Get-ScaleWorldRuntimeProcessMatcher -InstallRoot $installRootPath -ExecutableName $ExecutableName -RuntimeProcessPattern $RuntimeProcessPattern -IncludeLauncherExecutable $false

$arguments = @(
    "-PixelStreamingEncoderCodec=$EncoderCodec",
    '-AllowPixelStreamingCommands',
    '-PixelStreamingEncoderTargetBitrate=-1',
    '-PixelStreaming2.Encoder.LatencyMode=LOW_LATENCY',
    "-PixelStreaming2.WebRTC.Fps=$Fps",
    '-RenderOffScreen',
    "-ResX=$ResX",
    "-ResY=$ResY",
    '-log',
    '-AUTO',
    '-UNATTENDED',
    "-PixelStreamingIP=$PixelStreamingIp",
    "-PixelStreamingPort=$PixelStreamingPort"
)

if ($AdditionalArgs) {
    $manualPortRangeArguments = @(
        $AdditionalArgs |
            Where-Object { $_ -match '^-PixelStreamingWebRTC(?:Min|Max)Port(?:=|$)' }
    )
} else {
    $manualPortRangeArguments = @()
}

$portBankRotationEnabled = ConvertTo-ScaleWorldStrictBoolean `
    -Value $WebRtcPortBankRotationEnabled `
    -SettingName 'SCALEWORLD_WEBRTC_PORT_BANK_ROTATION_ENABLED'

if ($portBankRotationEnabled) {
    if ($manualPortRangeArguments.Count -gt 0) {
        throw "webrtc_port_bank_configuration_invalid: AdditionalArgs cannot override PixelStreamingWebRTCMinPort or PixelStreamingWebRTCMaxPort while port-bank rotation is enabled."
    }

    $portBankModulePath = Join-Path $PSScriptRoot 'webrtc_port_bank.psm1'
    if (-not (Test-Path -LiteralPath $portBankModulePath -PathType Leaf)) {
        throw "webrtc_port_bank_helper_missing: ScaleWorld WebRTC port-bank helper '$portBankModulePath' was not found."
    }
    Import-Module $portBankModulePath -Force -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($WebRtcPortBankStatePath)) {
        $installBase = if ($env:SCALEWORLD_INSTALL_BASE) {
            [System.IO.Path]::GetFullPath($env:SCALEWORLD_INSTALL_BASE)
        } else {
            Split-Path -Parent $installRootPath
        }
        $WebRtcPortBankStatePath = Join-Path $installBase 'state\webrtc-port-bank.json'
    }

    $portBank = Select-ScaleWorldWebRtcPortBank `
        -StatePath $WebRtcPortBankStatePath `
        -RangeMin $WebRtcPortRangeMin `
        -RangeMax $WebRtcPortRangeMax `
        -BankSize $WebRtcPortBankSize `
        -ReuseCooldownSeconds $WebRtcPortBankReuseCooldownSeconds `
        -LockTimeoutSeconds $WebRtcPortBankLockTimeoutSeconds
    $arguments += @(
        "-PixelStreamingWebRTCMinPort=$($portBank.MinPort)",
        "-PixelStreamingWebRTCMaxPort=$($portBank.MaxPort)"
    )
    Write-Output ("Selected WebRTC port bank generation={0} bank={1}/{2} ports={3}-{4} reuseCooldownSeconds={5} state='{6}'." -f $portBank.Generation, ($portBank.BankIndex + 1), $portBank.BankCount, $portBank.MinPort, $portBank.MaxPort, $portBank.ReuseCooldownSeconds, $portBank.StatePath)
} else {
    Write-Warning 'WebRTC port-bank rotation is disabled; Unreal will use its default or explicitly supplied WebRTC port range.'
}

if ($AdditionalArgs) {
    $arguments += $AdditionalArgs
}

$process = Start-Process -FilePath $processPath -ArgumentList $arguments -WorkingDirectory $installRootPath -PassThru
Write-Output ("Running: {0} {1}" -f $processPath, ($arguments -join ' '))
Write-Output ("Started ScaleWorld launcher process with PID {0}" -f $process.Id)
Write-Output ("Monitoring ScaleWorld runtime matcher installRoot='{0}' namePatterns='{1}'" -f $runtimeMatcher.InstallRoot, ($runtimeMatcher.NamePatterns -join ';'))

$wrapperExited = $false
$deadline = (Get-Date).AddSeconds($RuntimeProcessWaitSeconds)
$matchedRuntimeProcess = $null
while ((Get-Date) -lt $deadline) {

    $wrapperAlive = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    $runtimeProcesses = @(Get-ScaleWorldRuntimeProcesses -ExcludeProcessIds @($process.Id) -Matcher $runtimeMatcher)

    if ($runtimeProcesses.Count -gt 0) {
        $matchedRuntimeProcess = $runtimeProcesses | Select-Object -First 1
        break
    }

    if (-not $wrapperAlive) {
        $wrapperExited = $true
    }

    Start-Sleep -Milliseconds 500
}

if ($matchedRuntimeProcess) {
    Write-Output ("Detected ScaleWorld runtime process {0} (PID {1})" -f $matchedRuntimeProcess.Name, $matchedRuntimeProcess.ProcessId)
    exit 0
}

$launcherProcess = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $process.Id) | Select-Object -First 1
$launcherState = if ($launcherProcess) {
    "launcher process '{0}' (PID {1}) is still alive; executable='{2}'" -f $launcherProcess.Name, $launcherProcess.ProcessId, ([string]$launcherProcess.ExecutablePath)
} elseif ($wrapperExited) {
    'launcher process exited before a runtime appeared'
} else {
    'launcher process state could not be determined'
}

if ($launcherProcess) {
    try {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        Write-Output ("Stopped ScaleWorld launcher process PID {0} after runtime startup timeout." -f $process.Id)
    } catch {
        Write-Warning ("Failed to stop ScaleWorld launcher process PID {0} after startup timeout: {1}" -f $process.Id, $_.Exception.Message)
    }
}

throw "ScaleWorld runtime process matching '$($runtimeMatcher.NamePatterns -join ';')' did not appear within $RuntimeProcessWaitSeconds seconds; $launcherState."
