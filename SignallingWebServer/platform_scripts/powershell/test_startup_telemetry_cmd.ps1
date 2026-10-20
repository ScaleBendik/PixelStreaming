[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'startup_telemetry.ps1')
$helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\cmd\startup_telemetry.bat'))
$launcherPaths = @('start_streamer_stack.bat', 'start_dev_turn.bat') | ForEach-Object { Join-Path $PSScriptRoot ('..\cmd\' + $_) }
$phaseWrappers = @($launcherPaths | ForEach-Object {
    $launcherText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($_))
    $wrapperMatch = [regex]::Match($launcherText, '(?m)^:startup_phase\r?\n[^\r\n]*\r?\nexit /b %errorlevel%')
    if (!$wrapperMatch.Success) { throw 'Current launcher phase wrapper could not be found.' }
    $wrapperMatch.Value.Replace("`r`n", "`n")
})
if ($phaseWrappers[0] -ne $phaseWrappers[1]) { throw 'Review distinct launcher phase wrappers before using this harness.' }
$scratchBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $scratchBase ('sw-startup-cmd-' + [guid]::NewGuid().ToString('N'))))
if (!$scratch.StartsWith($scratchBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test scratch path.' }
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $missingHelper = Join-Path $scratch 'missing-helper\startup_telemetry.bat'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $missingHelper))
    [IO.File]::WriteAllText($missingHelper, [IO.File]::ReadAllText($helper), [Text.Encoding]::ASCII)
    $driver = @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCALEWORLD_INSTALL_BASE=[SCRATCH]"
set "SCALEWORLD_STARTUP_TELEMETRY_ENABLED=true"
set "STARTUP_TELEMETRY_CMD=[HELPER]"
call "[HELPER]" begin stack normal
if not defined SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE exit /b 90
set "SW_TEST_FIRST_JOURNAL=!SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE!"
for %%C in (1 2 42) do (
  cmd /d /c exit %%C
  call :startup_phase preserved_phase %%C
  if not "!errorlevel!"=="%%C" exit /b 91
  cmd /d /c exit %%C
  call "[HELPER]" end %%C
  if not "!errorlevel!"=="%%C" exit /b 92
)
>"[RESULT]" echo !SW_TEST_FIRST_JOURNAL!
set "SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE=[SCRATCH]\missing\journal.log"
for %%C in (1 2 42) do (
  cmd /d /c exit %%C
  call :startup_phase missing_directory %%C
  if not "!errorlevel!"=="%%C" exit /b 93
  cmd /d /c exit %%C
  call "[HELPER]" end %%C
  if not "!errorlevel!"=="%%C" exit /b 94
)
set "SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE=[SCRATCH]"
for %%C in (1 2 42) do (
  cmd /d /c exit %%C
  call :startup_phase directory_target %%C
  if not "!errorlevel!"=="%%C" exit /b 95
  cmd /d /c exit %%C
  call "[HELPER]" end %%C
  if not "!errorlevel!"=="%%C" exit /b 96
)
call "[MISSING_HELPER]" begin stack normal
if defined SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE exit /b 97
for %%C in (1 2 42) do (
  cmd /d /c exit %%C
  call "[MISSING_HELPER]" phase absent_helper %%C
  if not "!errorlevel!"=="%%C" exit /b 98
  cmd /d /c exit %%C
  call "[MISSING_HELPER]" end %%C
  if not "!errorlevel!"=="%%C" exit /b 99
)
set "SCALEWORLD_STARTUP_TELEMETRY_ENABLED=false"
call "[HELPER]" begin stack normal
if defined SCALEWORLD_STARTUP_TELEMETRY_PHASE_FILE exit /b 100
cmd /d /c exit 42
call "[HELPER]" phase opted_out 42
if not "!errorlevel!"=="42" exit /b 101
set "STARTUP_TELEMETRY_CMD=[SCRATCH]\absent.cmd"
for %%C in (1 2 42) do (
  cmd /d /c exit %%C
  call :startup_phase absent_wrapper_helper %%C
  if not "!errorlevel!"=="%%C" exit /b 102
)
exit /b 0
[PHASE_WRAPPER]
'@
    $resultPath = Join-Path $scratch 'journal-path.txt'
    $driver = $driver.Replace('[HELPER]', $helper).Replace('[SCRATCH]', $scratch).Replace('[RESULT]', $resultPath).Replace('[MISSING_HELPER]', $missingHelper).Replace('[PHASE_WRAPPER]', $phaseWrappers[0])
    $driverPath = Join-Path $scratch 'driver.cmd'
    [IO.File]::WriteAllText($driverPath, $driver, [Text.Encoding]::ASCII)
    $ErrorActionPreference = 'Continue'
    $output = @(& $env:ComSpec /d /v:on /c $driverPath 2>&1)
    $resultCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($resultCode -ne 0) { throw "Real CMD diagnostics changed return behavior (harness stage $resultCode)." }
    if ($output.Count -ne 0) { throw ('Diagnostics emitted unexpected stdout/stderr on normal, missing or unwritable paths: ' + ($output -join ' / ')) }
    $journalPath = [IO.File]::ReadAllText($resultPath).Trim()
    $journal = Read-ScaleWorldStartupCmdJournal $journalPath
    if ($journal.Status -ne 'readable' -or !$journal.Ended -or $journal.Records.Count -ne 3) {
        throw ('CMD append journal was not independently readable. Parsed: ' + ($journal | ConvertTo-Json -Compress -Depth 5) +
            '. Synthetic journal: ' + [IO.File]::ReadAllText($journalPath))
    }
    if (($journal.Records.exitCode -join ',') -ne '1,2,42') { throw 'CMD phase records changed the saved operation result.' }
    Write-Output 'Startup telemetry CMD tests passed: incoming 1/2/42 preserved by current launcher wrapper/phase/End, quiet missing/unwritable paths, absent helper, explicit opt-out and readable append journal.'
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if ($resolvedScratch.StartsWith($scratchBase, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedScratch)) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
