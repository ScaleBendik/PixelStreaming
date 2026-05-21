[CmdletBinding()]
param(
    [string]$CurrentRoot,
    [string]$InstallRoot = $(if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Optional {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim()
}

function Get-FullPathOrNull {
    param([string]$Path)

    $normalized = Normalize-Optional $Path
    if (-not $normalized) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($normalized).TrimEnd('\')
    } catch {
        return $null
    }
}

$installRootPath = Get-FullPathOrNull $InstallRoot
if (-not $installRootPath) {
    exit 0
}

$activeRuntimeRoot = Join-Path $installRootPath 'PixelStreamingRuntime'
$activeLauncher = Join-Path $activeRuntimeRoot 'SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
if (-not (Test-Path -LiteralPath $activeLauncher)) {
    exit 0
}

$currentRootPath = Get-FullPathOrNull $CurrentRoot
$activeRuntimeRootPath = Get-FullPathOrNull $activeRuntimeRoot
if ($currentRootPath -and $activeRuntimeRootPath -and [string]::Equals($currentRootPath, $activeRuntimeRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    exit 0
}

Write-Output $activeLauncher
