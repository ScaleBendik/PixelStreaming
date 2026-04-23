[CmdletBinding()]
param(
    [string]$InstallRoot = $(if ($env:SCALEWORLD_INSTALL_ROOT) { $env:SCALEWORLD_INSTALL_ROOT } else { 'C:\PixelStreaming\WindowsNoEditor' }),
    [string]$ExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
    [string]$RuntimeProcessPattern = $(if ($env:SCALEWORLD_RUNTIME_PROCESS_PATTERN) { $env:SCALEWORLD_RUNTIME_PROCESS_PATTERN } else { '' }),
    [int]$RuntimeProcessWaitSeconds = $(if ($env:SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS) { [int]$env:SCALEWORLD_RUNTIME_PROCESS_WAIT_SECONDS } else { 20 }),
    [string]$PixelStreamingIp = $(if ($env:SCALEWORLD_PIXEL_STREAMING_IP) { $env:SCALEWORLD_PIXEL_STREAMING_IP } else { 'localhost' }),
    [int]$PixelStreamingPort = $(if ($env:SCALEWORLD_PIXEL_STREAMING_PORT) { [int]$env:SCALEWORLD_PIXEL_STREAMING_PORT } else { 8888 }),
    [string]$EncoderCodec = $(if ($env:SCALEWORLD_ENCODER_CODEC) { $env:SCALEWORLD_ENCODER_CODEC } else { 'vp9' }),
    [int]$ResX = $(if ($env:SCALEWORLD_RES_X) { [int]$env:SCALEWORLD_RES_X } else { 2240 }),
    [int]$ResY = $(if ($env:SCALEWORLD_RES_Y) { [int]$env:SCALEWORLD_RES_Y } else { 1260 }),
    [int]$Fps = $(if ($env:SCALEWORLD_PIXEL_STREAMING_FPS) { [int]$env:SCALEWORLD_PIXEL_STREAMING_FPS } else { 30 }),
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

throw "ScaleWorld runtime process matching '$($runtimeMatcher.NamePatterns -join ';')' did not appear within $RuntimeProcessWaitSeconds seconds; $launcherState."
