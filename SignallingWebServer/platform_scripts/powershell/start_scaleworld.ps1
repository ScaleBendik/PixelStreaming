[CmdletBinding()]
param(
    [string]$InstallRoot = $(if ($env:SCALEWORLD_INSTALL_ROOT) { $env:SCALEWORLD_INSTALL_ROOT } else { 'C:\PixelStreaming\WindowsNoEditor' }),
    [string]$ExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
    [string]$RuntimeProcessPattern = $(if ($env:SCALEWORLD_RUNTIME_PROCESS_PATTERN) { $env:SCALEWORLD_RUNTIME_PROCESS_PATTERN } else { 'ScaleWorld*' }),
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

$installRoot = Resolve-Path -Path $InstallRoot -ErrorAction Stop
$processPath = Join-Path $installRoot $ExecutableName
if (-not (Test-Path -LiteralPath $processPath)) {
    throw "ScaleWorld executable not found at '$processPath'."
}

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

$process = Start-Process -FilePath $processPath -ArgumentList $arguments -WorkingDirectory $installRoot -PassThru
Write-Output ("Running: {0} {1}" -f $processPath, ($arguments -join ' '))
Write-Output ("Started ScaleWorld wrapper process with PID {0}" -f $process.Id)

$wrapperExited = $false
$deadline = (Get-Date).AddSeconds($RuntimeProcessWaitSeconds)
$matchedRuntimeProcess = $null
while ((Get-Date) -lt $deadline) {
    $wrapperAlive = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    $runtimeProcesses = @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.ProcessId -ne $process.Id -and [string]$_.Name -like $RuntimeProcessPattern
        }
    )

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
} elseif ($wrapperExited) {
    throw "ScaleWorld wrapper exited before a runtime process matching '$RuntimeProcessPattern' appeared."
}
