[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function New-Response {
    param([string[]]$Tokens = @(), [int]$Exit = 0)
    return @{ Tokens = $Tokens; Exit = $Exit }
}

$launcherPath = Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat'
$source = [IO.File]::ReadAllText($launcherPath)
$preludeEnd = $source.IndexOf('if not defined SCALEWORLD_GIT_SYNC_MODE (')
$labelsStart = $source.IndexOf("`n:read_startup_metadata_batch")
$labelsEnd = $source.IndexOf("`n:apply_unreal_provisioning_startup_args", $labelsStart + 1)
if ($preludeEnd -lt 0 -or $labelsStart -lt 0 -or $labelsEnd -le $labelsStart) { throw 'Startup metadata launcher boundaries missing.' }
# Execute the actual prelude and resolver labels, ending before any git,
# maintenance, provisioning, config, process cleanup or runtime work. The entry
# lease uses a fixed local receipt; concurrency is tested with the real module.
$prelude = $source.Substring(0, $preludeEnd)
$labels = $source.Substring($labelsStart, $labelsEnd - $labelsStart)
$testParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\.review-tmp'))
$testRoot = Join-Path $testParent ('ScaleWorldMetadataLauncherTest-' + [guid]::NewGuid().ToString('N'))
$cmdRoot = Join-Path $testRoot 'SignallingWebServer\platform_scripts\cmd'
$psRoot = Join-Path $testRoot 'SignallingWebServer\platform_scripts\powershell'
[void][IO.Directory]::CreateDirectory($cmdRoot)
[void][IO.Directory]::CreateDirectory($psRoot)
$fixturePath = Join-Path $cmdRoot 'metadata-launcher-test.cmd'
$responsePath = Join-Path $psRoot 'scenario.json'
$requestsPath = Join-Path $psRoot 'requests.txt'

function Invoke-LauncherCase {
    param(
        [string]$Name,
        [hashtable]$Responses,
        [string]$ExpectedRequests,
        [int]$ExpectedExit = 0,
        [string]$ExpectedResult = '',
        [string]$DeliveryOverride = '',
        [int]$DeliveryAttempts = 3,
        [string]$Inherited = ''
    )
    if (Test-Path -LiteralPath $requestsPath) { Remove-Item -LiteralPath $requestsPath -Force }
    [IO.File]::WriteAllText($responsePath, ($Responses | ConvertTo-Json -Depth 10), [Text.Encoding]::ASCII)
    # All inserted environment values are fixed test enums/numbers; tag payloads
    # and fake responses live in JSON and never become generated CMD source.
    $prefix = @"
@echo off
set "SCALEWORLD_INSTALL_BASE=$testRoot"
set "TEMP=$testRoot"
set "STREAMING_LANE_TAG_RETRY_COUNT=3"
set "DEPLOYMENT_TRACK_TAG_RETRY_COUNT=3"
set "DELIVERY_MODE_TAG_RETRY_COUNT=$DeliveryAttempts"
set "STREAMING_LANE_TAG_RETRY_DELAY_SECONDS=0"
set "DEPLOYMENT_TRACK_TAG_RETRY_DELAY_SECONDS=0"
set "DELIVERY_MODE_TAG_RETRY_DELAY_SECONDS=0"
set "SCALEWORLD_STREAMING_LANE="
set "SCALEWORLD_DEPLOYMENT_TRACK="
set "SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=$DeliveryOverride"
set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA="
set "RESOLVED_STREAMING_LANE="
set "RESOLVED_DEPLOYMENT_TRACK="
set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE="
set "STARTUP_BATCH_ENABLED="
set "STARTUP_BATCH_LANE="
set "STARTUP_BATCH_TRACK="
set "STARTUP_BATCH_DELIVERY="
set "STREAMING_LANE_TAG_ATTEMPT=0"
set "DEPLOYMENT_TRACK_TAG_ATTEMPT=0"
set "DELIVERY_MODE_TAG_ATTEMPT=0"
$Inherited
"@
    $result = @'
echo RESULT=%SCALEWORLD_STREAMING_LANE%,%SCALEWORLD_DEPLOYMENT_TRACK%,%SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE%,%STREAMING_LANE_TAG_ATTEMPT%,%DEPLOYMENT_TRACK_TAG_ATTEMPT%,%DELIVERY_MODE_TAG_ATTEMPT%
exit /b 0
:startup_phase
exit /b %~2
'@
    $fixture = ($prefix + "`r`n" + $prelude + "`r`n" + $result + "`r`n" + $labels).Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText($fixturePath, $fixture, [Text.Encoding]::ASCII)
    $stdoutPath = Join-Path $testRoot 'stdout.txt'
    $stderrPath = Join-Path $testRoot 'stderr.txt'
    $arguments = '/d /c ""{0}""' -f $fixturePath
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $output = [IO.File]::ReadAllText($stdoutPath)
    $requests = @(if (Test-Path -LiteralPath $requestsPath) { Get-Content -LiteralPath $requestsPath })
    Assert-Equal $process.ExitCode $ExpectedExit ("${Name}: exit. " + $output)
    Assert-Equal ($requests -join ',') $ExpectedRequests "${Name}: actual read order and attempt count."
    $resultLines = @($output -split '\r?\n' | Where-Object { $_ -like 'RESULT=*' })
    if ($ExpectedExit -eq 0) {
        Assert-Equal ($resultLines -join ',') ('RESULT=' + $ExpectedResult) "${Name}: actual prelude result."
    } else {
        Assert-Equal $resultLines.Count 0 "${Name}: failed lookup cannot reach defaults/result."
    }
    Write-Output "Passed: $Name"
}

try {
    $fakeEntry = @'
[CmdletBinding()]
param([ValidateSet('Enter')][string]$Mode, [string]$RepoRoot, [string]$InstallBase, [string]$LaunchMode, [string]$OutputFile)
$ErrorActionPreference = 'Stop'
$expectedParent = [IO.Path]::GetFullPath($InstallBase).TrimEnd('\')
if ([IO.Path]::GetFullPath((Split-Path -Parent $OutputFile)).TrimEnd('\') -ine $expectedParent) { throw 'Metadata fixture entry escaped its generated directory.' }
$receipt = 'set "SCALEWORLD_STACK_LAUNCH_GENERATION=11111111-1111-4111-8111-111111111111"' + "`r`n" + 'set "SCALEWORLD_STACK_LAUNCH_DECISION=Proceed"' + "`r`n"
[IO.File]::WriteAllText($OutputFile, $receipt, [Text.Encoding]::ASCII)
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $psRoot 'invoke_stack_launch_lease.ps1'), $fakeEntry, [Text.Encoding]::ASCII)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'normalize_pixelstreaming_delivery_mode.ps1') -Destination (Join-Path $psRoot 'normalize_pixelstreaming_delivery_mode.ps1')
    foreach ($file in @('resolve_streaming_lane_from_instance_tag.ps1', 'resolve_deployment_track_from_instance_tag.ps1', 'resolve_pixelstreaming_delivery_mode_from_instance_tag.ps1')) {
        [IO.File]::WriteAllText((Join-Path $psRoot $file), "throw 'Unexpected standalone lookup in batch launcher fixture.'", [Text.Encoding]::ASCII)
    }
    $fakeBatch = @'
[CmdletBinding()]
param([ValidateSet('all', 'lane', 'track', 'delivery')][string]$Field = 'all')
$ErrorActionPreference = 'Stop'
$requestsPath = Join-Path $PSScriptRoot 'requests.txt'
$prior = @(if (Test-Path -LiteralPath $requestsPath) { Get-Content -LiteralPath $requestsPath | Where-Object { $_ -eq $Field } })
[IO.File]::AppendAllText($requestsPath, "$Field`r`n")
$scenario = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scenario.json') -Raw | ConvertFrom-Json
$responses = @($scenario.$Field)
if ($responses.Count -eq 0 -or $null -eq $responses[0]) { throw "No fake response for $Field." }
$response = $responses[[Math]::Min($prior.Count, $responses.Count - 1)]
Write-Output @($response.Tokens)
exit [int]$response.Exit
'@
    [IO.File]::WriteAllText((Join-Path $psRoot 'resolve_startup_metadata_from_instance_tags.ps1'), $fakeBatch, [Text.Encoding]::ASCII)

    Invoke-LauncherCase -Name 'Resolved first batch' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_RUNTIME_ARTIFACT')))
    } -ExpectedRequests 'all' -ExpectedResult 'nonprod,dev,runtime_artifact,1,1,1'

    Invoke-LauncherCase -Name 'Missing lane and track preserve three attempts then defaults' -Responses @{
        all=@((New-Response @('LANE_MISSING', 'TRACK_MISSING', 'DELIVERY_MISSING')))
        lane=@((New-Response @('LANE_MISSING')))
        track=@((New-Response @('TRACK_MISSING')))
    } -ExpectedRequests 'all,lane,lane,track,track' -ExpectedResult 'nonprod,stage,auto,3,3,1'

    Invoke-LauncherCase -Name 'Missing prod track preserves prod default' -Responses @{
        all=@((New-Response @('LANE_PROD', 'TRACK_MISSING', 'DELIVERY_MISSING')))
        track=@((New-Response @('TRACK_MISSING')))
    } -ExpectedRequests 'all,track,track' -ExpectedResult 'prod,prod,auto,1,3,1'

    Invoke-LauncherCase -Name 'Transport failure preserves three attempts and fails closed' -Responses @{
        all=@((New-Response -Exit 2))
        lane=@((New-Response -Exit 2))
    } -ExpectedRequests 'all,lane,lane' -ExpectedExit 1

    Invoke-LauncherCase -Name 'Track transport failure cannot infer a default' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'DELIVERY_AUTO')))
        track=@((New-Response -Exit 2))
    } -ExpectedRequests 'all,track,track' -ExpectedExit 1

    Invoke-LauncherCase -Name 'Missing delivery uses dev default immediately' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_MISSING')))
    } -ExpectedRequests 'all' -ExpectedResult 'nonprod,dev,git_ref,1,1,1'

    Invoke-LauncherCase -Name 'Invalid delivery preserves two attempts and fails' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_INVALID')))
        delivery=@((New-Response @('DELIVERY_INVALID')))
    } -DeliveryAttempts 2 -ExpectedRequests 'all,delivery' -ExpectedExit 1

    Invoke-LauncherCase -Name 'Delivery transport failure preserves its retry budget' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV')))
        delivery=@((New-Response -Exit 2))
    } -ExpectedRequests 'all,delivery,delivery' -ExpectedExit 1

    Invoke-LauncherCase -Name 'Explicit delivery override ignores invalid delivery tag' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_INVALID')))
    } -DeliveryOverride 'git-ref' -ExpectedRequests 'all' -ExpectedResult 'nonprod,dev,git_ref,1,1,0'

    Invoke-LauncherCase -Name 'Invalid explicit delivery override is rejected by the real normalizer' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_RUNTIME_ARTIFACT')))
    } -DeliveryOverride 'unsupported' -ExpectedRequests 'all' -ExpectedExit 1

    Invoke-LauncherCase -Name 'Invalid lane fails closed without defaults' -Responses @{
        all=@((New-Response @('LANE_INVALID', 'TRACK_DEV', 'DELIVERY_AUTO')))
    } -ExpectedRequests 'all' -ExpectedExit 1

    $inherited = @'
set "SCALEWORLD_PARENT_RESOLVED_STARTUP_METADATA=true"
set "RESOLVED_STREAMING_LANE=prod"
set "RESOLVED_DEPLOYMENT_TRACK=prod"
set "RESOLVED_PIXELSTREAMING_DELIVERY_MODE=git_ref"
set "STARTUP_BATCH_ENABLED=true"
set "STARTUP_BATCH_LANE=LANE_PROD"
set "STARTUP_BATCH_TRACK=TRACK_PROD"
set "STARTUP_BATCH_DELIVERY=DELIVERY_GIT_REF"
'@
    Invoke-LauncherCase -Name 'Inherited cache and resolved values cannot bypass fresh first read' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_RUNTIME_ARTIFACT')))
    } -Inherited $inherited -ExpectedRequests 'all' -ExpectedResult 'nonprod,dev,runtime_artifact,1,1,1'

    Invoke-LauncherCase -Name 'Fresh lane retries preserve successful track and delivery' -Responses @{
        all=@((New-Response @('LANE_MISSING', 'TRACK_DEV', 'DELIVERY_AUTO')))
        lane=@((New-Response @('LANE_MISSING')), (New-Response @('LANE_PROD')))
    } -ExpectedRequests 'all,lane,lane' -ExpectedResult 'prod,dev,auto,3,1,1'

    Invoke-LauncherCase -Name 'Fresh track retry preserves successful lane and delivery' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_MISSING', 'DELIVERY_RUNTIME_ARTIFACT')))
        track=@((New-Response @('TRACK_STAGE')))
    } -ExpectedRequests 'all,track' -ExpectedResult 'nonprod,stage,runtime_artifact,1,2,1'

    Invoke-LauncherCase -Name 'Fresh delivery retry preserves successful lane and track' -Responses @{
        all=@((New-Response @('LANE_NONPROD', 'TRACK_DEV', 'DELIVERY_INVALID')))
        delivery=@((New-Response @('DELIVERY_GIT_REF')))
    } -ExpectedRequests 'all,delivery' -ExpectedResult 'nonprod,dev,git_ref,1,1,2'

    Write-Output 'Startup metadata batch launcher tests passed (real CMD prelude/labels; no hosted operations).'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($testParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected metadata launcher test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
