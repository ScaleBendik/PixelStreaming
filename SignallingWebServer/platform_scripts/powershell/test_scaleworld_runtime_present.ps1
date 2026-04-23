[CmdletBinding()]
param(
    [int]$ExcludeProcessId = 0,
    [switch]$IncludeLaunchers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperScriptPath = Join-Path $PSScriptRoot 'scaleworld_process_helpers.ps1'
if (-not (Test-Path -LiteralPath $helperScriptPath)) {
    throw "ScaleWorld process helper '$helperScriptPath' was not found."
}
. $helperScriptPath

$excludeProcessIds = [System.Collections.Generic.List[int]]::new()
$excludeProcessIds.Add($PID) | Out-Null
if ($ExcludeProcessId -gt 0) {
    $excludeProcessIds.Add($ExcludeProcessId) | Out-Null
}

$matches = @(Get-ScaleWorldRuntimeProcesses -ExcludeProcessIds $excludeProcessIds.ToArray())
if ($matches.Count -gt 0) {
    exit 0
}

if ($IncludeLaunchers.IsPresent) {
    $launchers = @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.ProcessId -ne $PID -and
            $_.ProcessId -ne $ExcludeProcessId -and
            (
                ($_.Name -ieq 'cmd.exe' -and ([string]$_.CommandLine) -like '*start_unreal.bat*') -or
                ($_.Name -ieq 'powershell.exe' -and ([string]$_.CommandLine) -like '*start_scaleworld.ps1*')
            )
        }
    )

    if ($launchers.Count -gt 0) {
        exit 0
    }
}

exit 1
