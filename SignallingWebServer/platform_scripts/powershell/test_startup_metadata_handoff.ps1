[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Exercise the real batch metadata prelude with local resolvers. No AWS, stack
# launch, installation or process cleanup is performed.
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_dev_turn.bat') -Raw
$end = $source.IndexOf('if /i "%SCALEWORLD_STREAMING_LANE%"=="prod" goto apply_streaming_lane_prod')
if ($end -lt 0) { throw 'Metadata prelude boundary missing.' }
$prelude = $source.Substring(0, $end)
$testParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\.review-tmp'))
$testRoot = Join-Path $testParent ('ScaleWorldMetadataTest-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$scriptPath = Join-Path $testRoot 'metadata-test.cmd'
$stub = @'
echo RESULT=%SCALEWORLD_STREAMING_LANE%,%SCALEWORLD_DEPLOYMENT_TRACK%,%SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA%
exit /b 0
:resolve_streaming_lane_from_instance_tag
echo LOOKUP_LANE
if "%TEST_FAIL_LOOKUP%"=="true" goto lookup_failure
set "RESOLVED_STREAMING_LANE=nonprod"
exit /b 0
:resolve_deployment_track_from_instance_tag
echo LOOKUP_TRACK
set "RESOLVED_DEPLOYMENT_TRACK=dev"
exit /b 0
:lookup_failure
exit /b 1
:startup_phase
exit /b %errorlevel%
'@
$cases = @(
    @{ Name='initial child'; Parent='true'; Lane='prod'; Track='prod'; Fail=''; Expected='RESULT=prod,prod,'; Lookups=0; Exit=0 },
    @{ Name='standalone ignores inherited settings'; Parent=''; Lane='prod'; Track='prod'; Fail=''; Expected='RESULT=nonprod,dev,'; Lookups=2; Exit=0 },
    @{ Name='incomplete parent context'; Parent='true'; Lane=''; Track='prod'; Fail=''; Expected='RESULT=nonprod,dev,'; Lookups=2; Exit=0 },
    @{ Name='standalone lookup failure'; Parent=''; Lane='prod'; Track='prod'; Fail='true'; Expected=''; Lookups=1; Exit=1 }
)
foreach ($case in $cases) {
    $fixture = @"
@echo off
set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA=$($case.Parent)"
set "SCALEWORLD_STREAMING_LANE=$($case.Lane)"
set "SCALEWORLD_DEPLOYMENT_TRACK=$($case.Track)"
set "TEST_FAIL_LOOKUP=$($case.Fail)"
"@
    [IO.File]::WriteAllText($scriptPath, ($fixture + "`r`n" + $prelude + "`r`n" + $stub).Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
    $output = & $env:ComSpec /d /c $scriptPath
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $case.Exit) { throw "$($case.Name): exit $exitCode; expected $($case.Exit). Output: $($output -join '; ') Fixture: $scriptPath" }
    if (@($output | Where-Object { $_ -like 'LOOKUP_*' }).Count -ne $case.Lookups) { throw "$($case.Name): unexpected lookup count." }
    if ($case.Expected -and $output -notcontains $case.Expected) { throw "$($case.Name): unexpected metadata result." }
    Write-Output "Passed: $($case.Name)"
}
# An operational launcher must clear the marker after handing off its child so
# watchdog recovery cannot inherit permission to reuse initial boot metadata.
$stack = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat') -Raw
if ($stack -notmatch 'start "ScaleWorld Wilbur"[^\r\n]+\r?\n\s*set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA="') { throw 'Parent metadata marker is not cleared after the child handoff.' }
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (!$resolvedTestRoot.StartsWith($testParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
Write-Output 'Startup metadata handoff tests passed.'
