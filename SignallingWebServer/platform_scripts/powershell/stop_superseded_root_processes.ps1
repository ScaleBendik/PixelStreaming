param(
    [Parameter(Mandatory = $true)]
    [string]$CurrentRoot,
    [Parameter(Mandatory = $true)]
    [string]$ActiveRoot,
    [string]$InstallRoot = $(if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { '' }),
    [switch]$AllRoots,
    [int]$WaitSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SupersededProcessEnumerationFailed = $false

function Normalize-PathForMatch {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $Path.Trim().TrimEnd('\')
    }
}

function Test-CommandLineContainsPath {
    param(
        [string]$CommandLine,
        [string]$Path
    )

    return -not [string]::IsNullOrWhiteSpace($CommandLine) `
        -and -not [string]::IsNullOrWhiteSpace($Path) `
        -and $CommandLine.IndexOf($Path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-SupersededProcessMatches {
    param(
        [string]$CurrentRootPath,
        [string]$ActiveRootPath,
        [string]$ActiveRootTargetPath,
        [string]$InstallRootPath,
        [bool]$IncludeAllRoots
    )

    $currentSignallingRoot = Join-Path $CurrentRootPath 'SignallingWebServer'
    $currentWatchdogScript = Join-Path $currentSignallingRoot 'platform_scripts\powershell\watchdog.ps1'
    $currentWatchdogLauncher = Join-Path $currentSignallingRoot 'platform_scripts\cmd\start_watchdog.bat'
    $currentWilburLauncher = Join-Path $currentSignallingRoot 'platform_scripts\cmd\start_dev_turn.bat'
    $knownScriptFragments = @(
        'platform_scripts\powershell\watchdog.ps1',
        'platform_scripts\cmd\start_watchdog.bat',
        'platform_scripts\cmd\start_dev_turn.bat'
    )

    $processes = try {
        @(Get-CimInstance Win32_Process)
    } catch {
        $script:SupersededProcessEnumerationFailed = $true
        Write-Warning "Could not enumerate Windows processes while checking for superseded PixelStreaming root processes: $($_.Exception.Message)"
        @()
    }

    $processes | Where-Object {
        $commandLine = $_.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            return $false
        }

        if (Test-CommandLineContainsPath -CommandLine $commandLine -Path $ActiveRootPath) {
            return $false
        }
        if (Test-CommandLineContainsPath -CommandLine $commandLine -Path $ActiveRootTargetPath) {
            return $false
        }

        if ($IncludeAllRoots) {
            if (-not (Test-CommandLineContainsPath -CommandLine $commandLine -Path $InstallRootPath)) {
                return $false
            }
        } else {
            $isCurrentRootProcess =
                Test-CommandLineContainsPath -CommandLine $commandLine -Path $CurrentRootPath
            if (-not $isCurrentRootProcess) {
                return $false
            }
        }

        $name = [string]$_.Name
        if ($IncludeAllRoots) {
            if ($name.Equals('powershell.exe', [System.StringComparison]::OrdinalIgnoreCase) `
                -and ((Test-CommandLineContainsPath -CommandLine $commandLine -Path 'watchdog.ps1') `
                    -or (Test-CommandLineContainsPath -CommandLine $commandLine -Path 'start_watchdog.bat'))) {
                return $true
            }

            if ($name.Equals('cmd.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                foreach ($fragment in $knownScriptFragments) {
                    if (Test-CommandLineContainsPath -CommandLine $commandLine -Path $fragment) {
                        return $true
                    }
                }
            }

            if ($name.Equals('node.exe', [System.StringComparison]::OrdinalIgnoreCase) `
                -and (Test-CommandLineContainsPath -CommandLine $commandLine -Path 'index.js')) {
                return $true
            }

            return $false
        }

        if ($name.Equals('powershell.exe', [System.StringComparison]::OrdinalIgnoreCase) `
            -and ((Test-CommandLineContainsPath -CommandLine $commandLine -Path $currentWatchdogScript) `
                -or (Test-CommandLineContainsPath -CommandLine $commandLine -Path $currentWatchdogLauncher))) {
            return $true
        }

        if ($name.Equals('cmd.exe', [System.StringComparison]::OrdinalIgnoreCase) `
            -and ((Test-CommandLineContainsPath -CommandLine $commandLine -Path $currentWatchdogLauncher) `
                -or (Test-CommandLineContainsPath -CommandLine $commandLine -Path $currentWilburLauncher))) {
            return $true
        }

        if ($name.Equals('node.exe', [System.StringComparison]::OrdinalIgnoreCase) `
            -and (Test-CommandLineContainsPath -CommandLine $commandLine -Path $currentSignallingRoot)) {
            return $true
        }

        return $false
    }
}

$currentRootPath = Normalize-PathForMatch $CurrentRoot
$activeRootPath = Normalize-PathForMatch $ActiveRoot
$installRootPath = Normalize-PathForMatch $InstallRoot
if (-not $currentRootPath -or -not $activeRootPath) {
    exit 0
}

if ($AllRoots -and -not $installRootPath) {
    exit 0
}

$activeRootTargetPath = $null
try {
    if (Test-Path -LiteralPath $activeRootPath) {
        $activeItem = Get-Item -LiteralPath $activeRootPath -Force
        $activeTarget = @($activeItem.Target | Select-Object -First 1)[0]
        if (-not [string]::IsNullOrWhiteSpace($activeTarget)) {
            $activeRootTargetPath = Normalize-PathForMatch ([string]$activeTarget)
        }
    }
} catch {
    $activeRootTargetPath = $null
}

if (-not $AllRoots -and [string]::Equals($currentRootPath, $activeRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    exit 0
}

$matches = @(Get-SupersededProcessMatches -CurrentRootPath $currentRootPath -ActiveRootPath $activeRootPath -ActiveRootTargetPath $activeRootTargetPath -InstallRootPath $installRootPath -IncludeAllRoots:$AllRoots)
if ($matches.Count -eq 0) {
    if ($script:SupersededProcessEnumerationFailed) {
        exit 1
    }

    exit 0
}

$stopped = [System.Collections.Generic.List[string]]::new()
foreach ($process in $matches) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        $stopped.Add("$($process.Name) PID=$($process.ProcessId)")
    } catch {
        Write-Warning "Failed to stop superseded PixelStreaming process PID=$($process.ProcessId): $($_.Exception.Message)"
    }
}

if ($stopped.Count -gt 0) {
    Write-Host ("Stopped superseded PixelStreaming root processes before active-runtime handoff: {0}" -f ($stopped -join ', '))
}

$deadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 0))
while ((Get-Date) -lt $deadline) {
    $remaining = @(Get-SupersededProcessMatches -CurrentRootPath $currentRootPath -ActiveRootPath $activeRootPath -ActiveRootTargetPath $activeRootTargetPath -InstallRootPath $installRootPath -IncludeAllRoots:$AllRoots)
    if ($remaining.Count -eq 0) {
        if ($script:SupersededProcessEnumerationFailed) {
            exit 1
        }

        exit 0
    }

    Start-Sleep -Milliseconds 500
}

$remainingSummary = (@(Get-SupersededProcessMatches -CurrentRootPath $currentRootPath -ActiveRootPath $activeRootPath -ActiveRootTargetPath $activeRootTargetPath -InstallRootPath $installRootPath -IncludeAllRoots:$AllRoots) |
    ForEach-Object { "$($_.Name) PID=$($_.ProcessId)" }) -join ', '
if (-not [string]::IsNullOrWhiteSpace($remainingSummary)) {
    Write-Warning "Superseded PixelStreaming root processes are still running after cleanup wait: $remainingSummary"
    exit 1
}

if ($script:SupersededProcessEnumerationFailed) {
    exit 1
}

exit 0
