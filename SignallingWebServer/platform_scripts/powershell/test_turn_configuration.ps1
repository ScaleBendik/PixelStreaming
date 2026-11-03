[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolver = Join-Path $PSScriptRoot 'resolve_turn_configuration.ps1'
$checks = 0

function Invoke-Case {
    param([hashtable]$Values, [string]$Phase = 'Select', [bool]$Succeeds = $true, [switch]$Launcher)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$resolver`" -Phase $Phase"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @($info.EnvironmentVariables.Keys)) {
        if ($name -like 'TURN_*' -or $name -in @('SCALEWORLD_TURN_MODE', 'SCALEWORLD_STREAMING_LANE', 'SCALEWORLD_DEPLOYMENT_TRACK')) {
            $info.EnvironmentVariables.Remove($name)
        }
    }
    $info.EnvironmentVariables['SCALEWORLD_STREAMING_LANE'] = 'nonprod'
    $info.EnvironmentVariables['SCALEWORLD_DEPLOYMENT_TRACK'] = 'stage'
    foreach ($entry in $Values.GetEnumerator()) { $info.EnvironmentVariables[$entry.Key] = $entry.Value }
    $batchPath = $null
    if ($Launcher) {
        # Execute the real selector bridge in cmd, stopping before any AWS/IMDS
        # operation. This catches lost exit status and stale empty assignments.
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_dev_turn.bat') -Raw
        $match = [regex]::Match($source, '(?s):after_streaming_lane_defaults\r?\n(.*?)set "AWS_EXE=aws"')
        if (-not $match.Success) { throw 'Cannot locate the TURN selector bridge.' }
        $batchPath = Join-Path ([System.IO.Path]::GetTempPath()) ("scaleworld-turn-test-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $lines = @('@echo off', 'setlocal EnableExtensions EnableDelayedExpansion', $match.Groups[1].Value)
        foreach ($name in @('SCALEWORLD_TURN_MODE', 'TURN_PUBLIC_HOST', 'TURN_PRIVATE_HOST', 'TURN_USER_PARAM', 'TURN_CONFIGURATION_READY')) {
            $lines += "echo $name=%$name%"
        }
        $lines += 'exit /b 0'
        [System.IO.File]::WriteAllText($batchPath, ($lines -join "`r`n"))
        $info.FileName = 'cmd.exe'
        $info.Arguments = "/d /c `"$batchPath`""
        $info.EnvironmentVariables['SCRIPT_DIR'] = (Resolve-Path (Join-Path $PSScriptRoot '..\cmd')).Path + '\'
    }
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'TURN resolver timed out.' }
        if (($process.ExitCode -eq 0) -ne $Succeeds) { throw "Unexpected resolver result: $stderr" }
        if (($stdout + $stderr).Contains('test-secret-do-not-log')) { throw 'TURN secret appeared in output.' }
        if (-not $Succeeds -and $stdout.Contains('TURN_CONFIGURATION_READY=1')) { throw 'Failed selection reported success.' }
        $script:checks++
        $output = @{}
        foreach ($line in ($stdout -split '\r?\n')) {
            if ($line -match '^([^=]+)=(.*)$') { $output[$Matches[1]] = $Matches[2] }
        }
        return $output
    } finally {
        $process.Dispose()
        if ($batchPath) { Remove-Item -LiteralPath $batchPath -Force }
    }
}

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', received '$Actual'." }
}

foreach ($track in @('dev', 'stage', 'prod')) {
    $lane = if ($track -eq 'prod') { 'prod' } else { 'nonprod' }
    $values = @{ SCALEWORLD_STREAMING_LANE = $lane; SCALEWORLD_DEPLOYMENT_TRACK = $track }
    $selected = Invoke-Case $values
    Assert-Equal $selected.SCALEWORLD_TURN_MODE 'legacy-shared'
    Assert-Equal $selected.TURN_USER_PARAM '/pixelstreaming/turn/username'
    Assert-Equal $selected.TURN_CREDENTIAL_PARAM '/pixelstreaming/turn/credential'
    Assert-Equal $selected.TURN_PUBLIC_HOST 'turn.scaleworld.net'
    Assert-Equal $selected.TURN_PRIVATE_HOST '172.31.32.124'
    Assert-Equal $selected.TURN_PUBLIC_HOST_PARAM ''

    $values.SCALEWORLD_TURN_MODE = 'isolated'
    # Stale inherited endpoint values must not hide an absent SSM response.
    $values.TURN_PUBLIC_HOST = 'stale.example.invalid'
    $values.TURN_PRIVATE_HOST = 'stale.example.invalid'
    $selected = Invoke-Case $values
    Assert-Equal $selected.TURN_USER_PARAM "/pixelstreaming/$lane/turn/username"
    Assert-Equal $selected.TURN_CREDENTIAL_PARAM "/pixelstreaming/$lane/turn/credential"
    Assert-Equal $selected.TURN_PUBLIC_HOST_PARAM "/pixelstreaming/$lane/turn/public-host"
    Assert-Equal $selected.TURN_PRIVATE_HOST_PARAM "/pixelstreaming/$lane/turn/private-host"
    Assert-Equal $selected.TURN_PUBLIC_HOST ''
    Assert-Equal $selected.TURN_PRIVATE_HOST ''

    $values.TURN_USERNAME = 'test-user'
    $values.TURN_CREDENTIAL = 'test-secret-do-not-log'
    $values.TURN_PUBLIC_HOST = "turn-$lane.scaleworld.net"
    $values.TURN_PRIVATE_HOST = "turn-$lane.internal.scaleworld.net"
    $null = Invoke-Case $values -Phase Validate
    $values.TURN_PRIVATE_HOST = '172.31.32.124'
    $null = Invoke-Case $values -Phase Validate -Succeeds $false
    $values.TURN_PRIVATE_HOST = ''
    $null = Invoke-Case $values -Phase Validate -Succeeds $false
}

$null = Invoke-Case @{ SCALEWORLD_TURN_MODE = 'automatic' } -Succeeds $false
$null = Invoke-Case @{ SCALEWORLD_DEPLOYMENT_TRACK = 'prod' } -Succeeds $false
$null = Invoke-Case @{ SCALEWORLD_STREAMING_LANE = 'prod' } -Succeeds $false
foreach ($path in @('/pixelstreaming/turn/username', '/pixelstreaming/prod/turn/username', '/invalid&command')) {
    $null = Invoke-Case @{ SCALEWORLD_TURN_MODE = 'isolated'; TURN_USER_PARAM = $path } -Succeeds $false
}
$null = Invoke-Case @{ TURN_USER_PARAM = '/pixelstreaming/prod/turn/username' } -Succeeds $false
$selected = Invoke-Case @{ TURN_USER_PARAM = '/emergency/turn/username' }
Assert-Equal $selected.TURN_USER_PARAM '/emergency/turn/username'

$validLegacy = @{
    TURN_PUBLIC_HOST = 'turn.scaleworld.net'; TURN_PRIVATE_HOST = '172.31.32.124'
    TURN_USERNAME = 'test-user'; TURN_CREDENTIAL = 'test-secret-do-not-log'
}
$null = Invoke-Case $validLegacy -Phase Validate
foreach ($missing in @('TURN_USERNAME', 'TURN_CREDENTIAL', 'TURN_PUBLIC_HOST', 'TURN_PRIVATE_HOST')) {
    $values = $validLegacy.Clone()
    $values[$missing] = ''
    $null = Invoke-Case $values -Phase Validate -Succeeds $false
}
$values = $validLegacy.Clone()
$values.SCALEWORLD_TURN_MODE = 'isolated'
$null = Invoke-Case $values -Phase Validate -Succeeds $false
$values.TURN_PUBLIC_HOST = 'turn-prod.scaleworld.net'
$values.TURN_PRIVATE_HOST = 'turn-prod.internal.scaleworld.net'
$null = Invoke-Case $values -Phase Validate -Succeeds $false

$selected = Invoke-Case @{} -Launcher
Assert-Equal $selected.TURN_CONFIGURATION_READY '1'
Assert-Equal $selected.TURN_PUBLIC_HOST 'turn.scaleworld.net'
$selected = Invoke-Case @{
    SCALEWORLD_TURN_MODE = 'isolated'
    TURN_PUBLIC_HOST = 'stale.example.invalid'; TURN_PRIVATE_HOST = 'stale.example.invalid'
} -Launcher
Assert-Equal $selected.TURN_PUBLIC_HOST ''
Assert-Equal $selected.TURN_PRIVATE_HOST ''
Assert-Equal $selected.TURN_USER_PARAM '/pixelstreaming/nonprod/turn/username'
$null = Invoke-Case @{ SCALEWORLD_TURN_MODE = 'invalid' } -Launcher -Succeeds $false

$selected = Invoke-Case @{ SCALEWORLD_STREAMING_LANE = 'prod'; SCALEWORLD_DEPLOYMENT_TRACK = 'prod'; SCALEWORLD_TURN_MODE = 'redundant'; TURN_FALLBACK_USERNAME = 'stale-user'; TURN_FALLBACK_CREDENTIAL = 'stale-secret' }
Assert-Equal $selected.TURN_FALLBACK_USER_PARAM '/pixelstreaming/prod/turn-fallback/username'
Assert-Equal $selected.TURN_FALLBACK_USERNAME ''
Assert-Equal $selected.TURN_FALLBACK_CREDENTIAL ''
$redundant = @{
    SCALEWORLD_STREAMING_LANE = 'prod'; SCALEWORLD_DEPLOYMENT_TRACK = 'prod'; SCALEWORLD_TURN_MODE = 'redundant'
    TURN_PUBLIC_HOST = 'turn-prod.scaleworld.net'; TURN_PRIVATE_HOST = 'turn-prod.internal.scaleworld.net'
    TURN_USERNAME = 'primary-user'; TURN_CREDENTIAL = 'test-secret-do-not-log'
    TURN_FALLBACK_USERNAME = 'fallback-user'; TURN_FALLBACK_CREDENTIAL = 'independent-fallback-secret'
}
$selected = Invoke-Case $redundant
Assert-Equal $selected.TURN_FALLBACK_CREDENTIAL_PARAM '/pixelstreaming/prod/turn-fallback/credential'
$null = Invoke-Case $redundant -Phase Validate
foreach ($missing in @('TURN_FALLBACK_USERNAME', 'TURN_FALLBACK_CREDENTIAL')) {
    $values = $redundant.Clone(); $values[$missing] = ''
    $null = Invoke-Case $values -Phase Validate -Succeeds $false
}
$values = $redundant.Clone(); $values.TURN_FALLBACK_CREDENTIAL = $values.TURN_CREDENTIAL
$null = Invoke-Case $values -Phase Validate -Succeeds $false
foreach ($track in @('dev', 'stage')) {
    $values = $redundant.Clone(); $values.SCALEWORLD_STREAMING_LANE = 'nonprod'; $values.SCALEWORLD_DEPLOYMENT_TRACK = $track
    $null = Invoke-Case $values -Succeeds $false
    $null = Invoke-Case $values -Phase Validate -Succeeds $false
    $null = Invoke-Case $values -Launcher -Succeeds $false
}
Write-Output "TURN configuration tests passed ($checks cases)."
