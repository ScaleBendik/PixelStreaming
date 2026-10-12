[CmdletBinding()]
param([int]$DelaySeconds = 3)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
$gate = $null
try {
    $installBase = if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }
    $gate = Enter-StackLaunchGate -RepoRoot $repoRoot -InstallBase $installBase -GenerationId $env:SCALEWORLD_STACK_LAUNCH_GENERATION
    $launcher = Join-Path $repoRoot 'platform_scripts\cmd\start_watchdog.bat'
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/s', '/c', ('""{0}""' -f $launcher) -WorkingDirectory (Split-Path -Parent $launcher) -WindowStyle Hidden | Out-Null
} finally { if ($null -ne $gate) { Exit-StackLaunchGate -Handle $gate } }
