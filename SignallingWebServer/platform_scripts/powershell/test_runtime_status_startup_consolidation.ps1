[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

$publisherPath = Join-Path $PSScriptRoot 'publish_runtime_status_tags.ps1'
$launcherSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\cmd\start_dev_turn.bat'))
$labelsStart = $launcherSource.IndexOf("`n:write_startup_status_state")
if ($labelsStart -lt 0) { throw 'Runtime status launcher labels missing.' }
$labels = $launcherSource.Substring($labelsStart)
# Load only the actual heartbeat reader, without starting its operational loop.
$readerTokens = $null
$readerErrors = $null
$readerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'runtime-status-heartbeat.ps1'), [ref]$readerTokens, [ref]$readerErrors)
$readerDefinition = $readerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-StateFile' }, $true)
if (@($readerErrors).Count -gt 0 -or $null -eq $readerDefinition) { throw 'Startup heartbeat state reader missing or invalid.' }
. ([scriptblock]::Create($readerDefinition.Extent.Text))
$testParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\.review-tmp'))
$testRoot = Join-Path $testParent ('ScaleWorldRuntimeStatusTest-' + [guid]::NewGuid().ToString('N'))
$helperRoot = Join-Path $testRoot 'platform_scripts\powershell'
$binRoot = Join-Path $testRoot 'bin'
[void][IO.Directory]::CreateDirectory($helperRoot)
[void][IO.Directory]::CreateDirectory($binRoot)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wrapperPath = Join-Path $helperRoot 'publish_runtime_status_tags.ps1'
$fixturePath = Join-Path $testRoot 'status-test.cmd'
$statePath = Join-Path $testRoot 'startup.state'
$capturePath = Join-Path $testRoot 'aws-captures.jsonl'

# Mock only the AWS process boundary. The real publisher still generates UTC,
# writes state, serializes its tag JSON, checks the exit code and cleans up files.
$publisherWrapper = @'
[CmdletBinding()]
param([string]$InstanceId, [string]$Region, [string]$Status, [string]$Source, [string]$Reason,
    [string]$Version='', [string]$StatusAtUtc='', [string]$AwsCliPath='fake-aws', [string]$StartupStateFilePath='', [switch]$PositionalLegacy)
$global:RuntimeStatusTestStatePath = $StartupStateFilePath
function global:Start-Process {
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoNewWindow, [switch]$Wait,
        [switch]$PassThru, [string]$RedirectStandardOutput, [string]$RedirectStandardError)
    if ($FilePath -ne 'fake-aws' -or ($ArgumentList[0..1] -join ',') -ne 'ec2,create-tags') { throw 'Unexpected process in publisher fixture.' }
    $tagIndex = [Array]::IndexOf($ArgumentList, '--tags')
    $payloadPath = $ArgumentList[$tagIndex + 1].Substring(7)
    $tags = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json
    $stateExists = [IO.File]::Exists($global:RuntimeStatusTestStatePath)
    $stateText = if ($stateExists) { [IO.File]::ReadAllText($global:RuntimeStatusTestStatePath) } else { '' }
    $capture = @{ Tags=@($tags); StateExistsBeforeAws=$stateExists; StateTextBeforeAws=$stateText; Arguments=$ArgumentList }
    [IO.File]::AppendAllText((Join-Path $env:TEST_RECORD_DIR 'aws-captures.jsonl'), (($capture | ConvertTo-Json -Depth 5 -Compress) + "`r`n"))
    [IO.File]::WriteAllText($RedirectStandardOutput, '')
    [IO.File]::WriteAllText($RedirectStandardError, '')
    return [pscustomobject]@{ ExitCode=[int]$env:TEST_AWS_EXIT }
}
if ($PositionalLegacy) {
    & $env:TEST_REAL_PUBLISHER 'i-fixture' 'eu-north-1' 'booting' 'startup-script' 'startup_sequence' '' '' 'fake-aws'
} else {
    & $env:TEST_REAL_PUBLISHER @PSBoundParameters
}
exit $LASTEXITCODE
'@
$shim = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
public class RuntimeStatusPowerShellShim {
    static string Quote(string value) {
        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char ch in value) {
            if (ch == '\\') { backslashes++; continue; }
            if (ch == '"') {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
            } else {
                result.Append('\\', backslashes);
                result.Append(ch);
            }
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
    public static int Main(string[] args) {
        File.AppendAllText(Path.Combine(Environment.GetEnvironmentVariable("TEST_RECORD_DIR"), "powershell-calls.txt"), "call\r\n");
        if (Environment.GetEnvironmentVariable("TEST_SKIP_POWERSHELL") == "true") return 1;
        var quoted = new string[args.Length];
        for (int i = 0; i < args.Length; i++) quoted[i] = Quote(args[i]);
        var info = new ProcessStartInfo(Environment.GetEnvironmentVariable("TEST_REAL_POWERSHELL"), String.Join(" ", quoted));
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        using (var process = Process.Start(info)) {
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            Console.Out.Write(stdout.Result);
            Console.Error.Write(stderr.Result);
            return process.ExitCode;
        }
    }
}
'@
# A native shim preserves CMD's executable-call behavior; a .cmd shim would
# transfer batch control unless called explicitly and invalidate exit tests.
Add-Type -TypeDefinition $shim -OutputAssembly (Join-Path $binRoot 'powershell.exe') -OutputType ConsoleApplication

function Invoke-LauncherStatusCase {
    param([string]$Name, [string]$Calls, [int]$ExpectedProcesses, [int]$ExpectedAwsCalls,
        [string]$Enabled='true', [string]$InstanceId='i-fixture', [int]$AwsExit=0,
        [switch]$MissingPublisher, [switch]$StateFailure, [switch]$NoStatePath, [switch]$TimestampFailure)
    foreach ($file in @('powershell-calls.txt', 'aws-captures.jsonl', 'startup.state')) {
        $path = Join-Path $testRoot $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    if ($MissingPublisher) {
        if (Test-Path -LiteralPath $wrapperPath) { Remove-Item -LiteralPath $wrapperPath -Force }
    } else {
        [IO.File]::WriteAllText($wrapperPath, $publisherWrapper, [Text.Encoding]::ASCII)
    }
    $effectiveStatePath = if ($NoStatePath) { '' } elseif ($StateFailure) { $testRoot } else { $statePath }
    $skipPowerShell = if ($TimestampFailure) { 'true' } else { '' }
    $prefix = @"
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=$testRoot"
set "PATH=$binRoot;%PATH%"
set "REGION=eu-north-1"
set "AWS_EXE=fake-aws"
set "INSTANCE_ID=$InstanceId"
set "RUNTIME_STATUS_ENABLED=$Enabled"
set "STARTUP_HEARTBEAT_STATE_FILE=$effectiveStatePath"
set "TEST_RECORD_DIR=$testRoot"
set "TEST_REAL_PUBLISHER=$publisherPath"
set "TEST_REAL_POWERSHELL=$windowsPowerShell"
set "TEST_AWS_EXIT=$AwsExit"
set "TEST_SKIP_POWERSHELL=$skipPowerShell"
$Calls
echo RESULT=!errorlevel!
exit /b !errorlevel!
"@
    [IO.File]::WriteAllText($fixturePath, ($prefix + "`r`n" + $labels).Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""{0}""' -f $fixturePath) -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    $output = [IO.File]::ReadAllText((Join-Path $testRoot 'stdout.txt'))
    Assert-Equal $process.ExitCode 0 ("${Name}: CMD status caller remains best effort. " + $output + [IO.File]::ReadAllText((Join-Path $testRoot 'stderr.txt')))
    if (-not $output.Contains('RESULT=0')) { throw "${Name}: status call did not return zero. $output" }
    $processCalls = @(if (Test-Path -LiteralPath (Join-Path $testRoot 'powershell-calls.txt')) { Get-Content -LiteralPath (Join-Path $testRoot 'powershell-calls.txt') })
    $captures = @(if (Test-Path -LiteralPath $capturePath) { Get-Content -LiteralPath $capturePath | ForEach-Object { $_ | ConvertFrom-Json } })
    Assert-Equal $processCalls.Count $ExpectedProcesses "${Name}: PowerShell process count."
    Assert-Equal $captures.Count $ExpectedAwsCalls "${Name}: AWS publish count."
    Write-Host "Passed: $Name"
    return [pscustomobject]@{ Captures=$captures; Output=$output; ErrorOutput=[IO.File]::ReadAllText((Join-Path $testRoot 'stderr.txt')); StateExists=[IO.File]::Exists($statePath) }
}

function Get-TagMap {
    param($Capture)
    $tags = @{}
    foreach ($tag in @($Capture.Tags)) { $tags[$tag.Key] = [string]$tag.Value }
    Assert-Equal $tags.Count 6 'Runtime status tag payload stays six tags.'
    return $tags
}

function Assert-StateBeforeAws {
    param($Capture, [string]$Status, [string]$Reason)
    if (-not $Capture.StateExistsBeforeAws) { throw 'Startup state was not written before AWS.' }
    $tags = Get-TagMap $Capture
    $expected = "status=$Status`r`nsource=startup-script`r`nreason=$Reason`r`nversion=`r`nstatus_at_utc=$($tags.ScaleWorldRuntimeStatusAtUtc)`r`n"
    Assert-Equal $Capture.StateTextBeforeAws $expected 'Raw five-line ASCII/CRLF state and tag transition time.'
    Assert-Equal $tags.ScaleWorldRuntimeStatus $Status 'Runtime status value.'
    Assert-Equal $tags.ScaleWorldRuntimeStatusReason $Reason 'Runtime status reason.'
    Assert-Equal $tags.ScaleWorldRuntimeStatusSource 'startup-script' 'Runtime source/default.'
    $transition = [DateTime]::Parse($tags.ScaleWorldRuntimeStatusAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $heartbeat = [DateTime]::Parse($tags.ScaleWorldRuntimeStatusHeartbeatAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($transition.Kind -ne 'Utc' -or $heartbeat.Kind -ne 'Utc' -or $heartbeat -lt $transition) { throw 'Transition/heartbeat UTC ordering changed.' }
}

try {
    $calls = @'
call :set_runtime_status "booting" "" "startup_sequence" ""
call :set_runtime_status "waiting_for_streamer" "startup-script" "signalling_server_starting" ""
'@
    $result = Invoke-LauncherStatusCase -Name 'Two real startup transitions use two PowerShell processes' -Calls $calls -ExpectedProcesses 2 -ExpectedAwsCalls 2
    Assert-StateBeforeAws $result.Captures[0] 'booting' 'startup_sequence'
    Assert-StateBeforeAws $result.Captures[1] 'waiting_for_streamer' 'signalling_server_starting'
    Assert-Equal ([IO.File]::ReadAllText($statePath)) $result.Captures[1].StateTextBeforeAws 'Second transition replaces state.'
    Assert-Equal ([IO.File]::ReadAllBytes($statePath)[0]) 115 'New state is ASCII without a BOM.'
    $readState = Read-StateFile -Path $statePath
    Assert-Equal $readState.Status 'waiting_for_streamer' 'Actual heartbeat reader sees the new status.'
    Assert-Equal $readState.Version '' 'Actual heartbeat reader preserves empty version.'
    Assert-Equal $readState.StatusAtUtc (Get-TagMap $result.Captures[1]).ScaleWorldRuntimeStatusAtUtc 'Actual heartbeat reader retains transition time.'
    [IO.File]::WriteAllText($statePath, "status=booting`r`nsource=`r`nreason=`r`nversion=`r`nstatus_at_utc=legacy-timestamp`r`n", (New-Object Text.UTF8Encoding($true)))
    $readState = Read-StateFile -Path $statePath
    Assert-Equal $readState.Status 'booting' 'Existing UTF8/BOM state remains readable.'
    Assert-Equal ($readState.Source + $readState.Reason + $readState.Version) '' 'Existing empty state fields remain readable.'

    $oneCall = 'call :set_runtime_status "booting" "startup-script" "startup_sequence" ""'
    $result = Invoke-LauncherStatusCase -Name 'AWS failure retains pre-publish state and nonfatal CMD result' -Calls $oneCall -ExpectedProcesses 1 -ExpectedAwsCalls 1 -AwsExit 7
    Assert-StateBeforeAws $result.Captures[0] 'booting' 'startup_sequence'
    if (-not $result.Output.Contains('WARNING: Failed to publish runtime status')) { throw 'AWS failure warning was lost.' }

    $result = Invoke-LauncherStatusCase -Name 'State I/O failure still attempts tags' -Calls $oneCall -ExpectedProcesses 1 -ExpectedAwsCalls 1 -StateFailure
    if ($result.Captures[0].StateExistsBeforeAws) { throw 'I/O failure fixture unexpectedly wrote state.' }
    if (-not $result.ErrorOutput.Contains('WARNING: Failed to write startup status state. Runtime status tag publishing will continue.')) { throw 'State I/O warning was hidden from the CMD caller.' }

    $result = Invoke-LauncherStatusCase -Name 'Missing state path still publishes tags' -Calls $oneCall -ExpectedProcesses 1 -ExpectedAwsCalls 1 -NoStatePath
    $tags = Get-TagMap $result.Captures[0]
    Assert-Equal $tags.ScaleWorldRuntimeStatusAtUtc $tags.ScaleWorldRuntimeStatusHeartbeatAtUtc 'Legacy no-state timestamp equality.'

    $result = Invoke-LauncherStatusCase -Name 'Missing publisher keeps state-only timestamp fallback' -Calls $oneCall -ExpectedProcesses 1 -ExpectedAwsCalls 0 -MissingPublisher
    if (-not $result.StateExists -or -not $result.Output.Contains('Runtime status publish helper not found')) { throw 'Missing publisher fallback was lost.' }
    $fallbackLines = @(Get-Content -LiteralPath $statePath)
    Assert-Equal $fallbackLines.Count 5 'Fallback state line count.'
    Assert-Equal ($fallbackLines[0..3] -join ',') 'status=booting,source=startup-script,reason=startup_sequence,version=' 'Fallback state fields.'
    [void][DateTime]::Parse($fallbackLines[4].Substring('status_at_utc='.Length))

    $result = Invoke-LauncherStatusCase -Name 'Missing publisher and unavailable UTC leave no state' -Calls $oneCall -ExpectedProcesses 1 -ExpectedAwsCalls 0 -MissingPublisher -TimestampFailure
    if ($result.StateExists) { throw 'Failed UTC fallback wrote state.' }
    $result = Invoke-LauncherStatusCase -Name 'Disabled runtime status does no work' -Calls $oneCall -Enabled 'false' -ExpectedProcesses 0 -ExpectedAwsCalls 0
    if ($result.StateExists) { throw 'Disabled runtime status wrote state.' }
    $result = Invoke-LauncherStatusCase -Name 'Missing instance identity does no work' -Calls $oneCall -InstanceId '' -ExpectedProcesses 0 -ExpectedAwsCalls 0
    if ($result.StateExists) { throw 'Missing instance identity wrote state.' }

    # Exercise the actual publisher entry point directly for existing callers,
    # including explicit timestamps that have never required date validation.
    [IO.File]::WriteAllText($wrapperPath, $publisherWrapper, [Text.Encoding]::ASCII)
    $envNames = @('TEST_RECORD_DIR', 'TEST_REAL_PUBLISHER', 'TEST_AWS_EXIT')
    $savedEnv = @{}
    foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:TEST_RECORD_DIR = $testRoot
        $env:TEST_REAL_PUBLISHER = $publisherPath
        $env:TEST_AWS_EXIT = '0'
        foreach ($case in @(
            @{ Name='Legacy default'; Args=''; State=$false; Expected='' },
            @{ Name='Legacy positional parameters'; Args=' -PositionalLegacy'; State=$false; Expected='' },
            @{ Name='Explicit legacy timestamp'; Args=' -StatusAtUtc "legacy-unvalidated-timestamp"'; State=$false; Expected='legacy-unvalidated-timestamp' },
            @{ Name='Explicit state timestamp'; Args=(' -StartupStateFilePath "{0}" -StatusAtUtc "legacy-unvalidated-timestamp"' -f $statePath); State=$true; Expected='legacy-unvalidated-timestamp' },
            @{ Name='Raw state values retain whitespace and length'; Args=(' -StartupStateFilePath "{0}" -StatusAtUtc " legacy timestamp " -Version "{1}"' -f $statePath, ('v' * 300)); State=$true; Expected='legacy timestamp'; Reason='  reason   spacing  '; Raw=$true }
        )) {
            if (Test-Path -LiteralPath $capturePath) { Remove-Item -LiteralPath $capturePath -Force }
            $reason = if ($case.ContainsKey('Reason')) { $case.Reason } else { 'startup_sequence' }
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstanceId i-fixture -Region eu-north-1 -Status booting -Source startup-script -Reason "{1}" -AwsCliPath fake-aws' -f $wrapperPath, $reason
            $process = Start-Process -FilePath $windowsPowerShell -ArgumentList ($arguments + $case.Args) -WindowStyle Hidden -Wait -PassThru `
                -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
            Assert-Equal $process.ExitCode 0 ($case.Name + ': publisher exit.')
            $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
            Assert-Equal $capture.StateExistsBeforeAws $case.State ($case.Name + ': optional state behavior.')
            $tags = Get-TagMap $capture
            $expectedTimestamp = if ($case.Expected) { $case.Expected } else { $tags.ScaleWorldRuntimeStatusHeartbeatAtUtc }
            Assert-Equal $tags.ScaleWorldRuntimeStatusAtUtc $expectedTimestamp ($case.Name + ': exact status timestamp.')
            if ($case.ContainsKey('Raw')) {
                $rawExpected = "status=booting`r`nsource=startup-script`r`nreason=  reason   spacing  `r`nversion=$('v' * 300)`r`nstatus_at_utc= legacy timestamp `r`n"
                Assert-Equal $capture.StateTextBeforeAws $rawExpected 'State fields are not normalized or truncated.'
                Assert-Equal $tags.ScaleWorldRuntimeStatusReason 'reason spacing' 'Existing tag whitespace normalization.'
                Assert-Equal $tags.ScaleWorldRuntimeStatusVersion.Length 256 'Existing tag length limit.'
                $readState = Read-StateFile -Path $statePath
                Assert-Equal $readState.Version.Length 300 'Heartbeat reader retains the raw version length.'
            } elseif ($case.State -and -not $capture.StateTextBeforeAws.Contains('status_at_utc=' + $case.Expected + "`r`n")) { throw 'Explicit timestamp was altered in state.' }
            Write-Output ('Passed: ' + $case.Name)
        }
        $env:TEST_AWS_EXIT = '7'
        if (Test-Path -LiteralPath $capturePath) { Remove-Item -LiteralPath $capturePath -Force }
        $process = Start-Process -FilePath $windowsPowerShell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstanceId i-fixture -Region eu-north-1 -Status booting -Source startup-script -Reason startup_sequence -AwsCliPath fake-aws' -f $wrapperPath) `
            -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
        Assert-Equal $process.ExitCode 1 'Standalone publisher still exposes tag failure exit 1.'
        if (-not (Test-Path -LiteralPath $capturePath)) { throw 'Standalone tag failure did not reach the mocked AWS boundary.' }
    } finally {
        foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
    }
    Write-Output 'Runtime status startup consolidation tests passed (normal UTC/state/tag path: 4 -> 2 PowerShell processes; no AWS calls).'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($testParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected runtime status test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
