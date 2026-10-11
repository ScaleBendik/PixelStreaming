[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Tokens {
    param([object[]]$Rows, [string]$Expected, [string]$Name)
    $tokens = @(ConvertTo-StartupMetadataTokens -Rows $Rows)
    Assert-Equal ($tokens -join ',') $Expected $Name
    foreach ($token in $tokens) {
        if ($token -cnotmatch '^(LANE_(NONPROD|PROD|MISSING|INVALID)|TRACK_(DEV|STAGE|PROD|MISSING)|DELIVERY_(GIT_REF|RUNTIME_ARTIFACT|AUTO|MISSING|INVALID))$') {
            throw "$Name emitted a non-enum token."
        }
    }
}

$resolverPath = Join-Path $PSScriptRoot 'resolve_startup_metadata_from_instance_tags.ps1'
$source = [IO.File]::ReadAllText($resolverPath)
$parseTokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$parseTokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw $parseErrors[0].Message }
# Load the real pure parsing functions without executing the operational entry
# point. The transport tests below run that entry point in Windows PowerShell 5.1.
$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Extent.Text })
$parserModule = New-Module -ScriptBlock ([scriptblock]::Create(($definitions -join "`r`n`r`n")))
Import-Module $parserModule -DisableNameChecking

$testParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\.review-tmp'))
$testRoot = Join-Path $testParent ('ScaleWorldMetadataBatchTest-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell)) { throw 'Windows PowerShell 5.1 is required for startup metadata transport tests.' }

function Invoke-ResolverFixture {
    param(
        [string]$Resolver,
        [string]$CliOutput,
        [int]$CliExit = 0,
        [hashtable]$Config = @{},
        [string]$Field = ''
    )

    foreach ($name in @('cli-calls.txt', 'cli-arguments.txt', 'imds-calls.txt', 'stdout.txt', 'stderr.txt')) {
        $path = Join-Path $testRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'cli-output.txt'), $CliOutput, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $testRoot 'cli-exit.txt'), [string]$CliExit, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $testRoot 'fixture-config.json'), ($Config | ConvertTo-Json), [Text.Encoding]::ASCII)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ResolverPath "{1}"' -f (Join-Path $testRoot 'fixture.ps1'), $Resolver
    if ($Field) { $arguments += ' -Field ' + $Field }
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    $stdout = @(Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt') | Where-Object { $_ -ne '' })
    $cliCalls = @(if (Test-Path -LiteralPath (Join-Path $testRoot 'cli-calls.txt')) { Get-Content -LiteralPath (Join-Path $testRoot 'cli-calls.txt') })
    $imdsCalls = @(if (Test-Path -LiteralPath (Join-Path $testRoot 'imds-calls.txt')) { Get-Content -LiteralPath (Join-Path $testRoot 'imds-calls.txt') })
    $cliArguments = if (Test-Path -LiteralPath (Join-Path $testRoot 'cli-arguments.txt')) { [IO.File]::ReadAllText((Join-Path $testRoot 'cli-arguments.txt')) } else { '' }
    return [pscustomobject]@{ Exit = $process.ExitCode; Tokens = $stdout; CliCalls = $cliCalls.Count; ImdsCalls = $imdsCalls; Arguments = $cliArguments; Stderr = [IO.File]::ReadAllText((Join-Path $testRoot 'stderr.txt')) }
}

try {
    Assert-Tokens @() 'LANE_MISSING,TRACK_MISSING,DELIVERY_MISSING' 'Empty tag response'
    Assert-Tokens @(
        @{ Key='ScaleWorldlane'; Value=' NONPROD ' },
        @{ Key='ScaleWorldDeploymenttrack'; Value=' DEV ' },
        @{ Key='ScaleWorldPixelStreamingDeliverymode'; Value=' RuNtImE ' }
    ) 'LANE_NONPROD,TRACK_DEV,DELIVERY_RUNTIME_ARTIFACT' 'Aliases and normalization'
    Assert-Tokens @(
        @{ Key='ScaleWorldLane'; Value='prod' },
        @{ Key='ScaleWorldDeploymentTrack'; Value='stage' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value='auto' }
    ) 'LANE_PROD,TRACK_STAGE,DELIVERY_AUTO' 'Other valid enums'
    Assert-Tokens @(
        @{ Key='ScaleWorldLane'; Value='None' },
        @{ Key='ScaleWorldlane'; Value='prod' },
        @{ Key='ScaleWorldDeploymentTrack'; Value='None' },
        @{ Key='ScaleWorldDeploymenttrack'; Value='prod' }
    ) 'LANE_MISSING,TRACK_MISSING,DELIVERY_MISSING' 'First alias row remains authoritative'
    Assert-Tokens @(
        @{ Key='ScaleWorldlane'; Value='nonprod' },
        @{ Key='ScaleWorldLane'; Value='prod' },
        @{ Key='ScaleWorldDeploymenttrack'; Value='dev' },
        @{ Key='ScaleWorldDeploymentTrack'; Value='prod' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value='git_ref' },
        @{ Key='ScaleWorldPixelStreamingDeliverymode'; Value='artifact' }
    ) 'LANE_NONPROD,TRACK_DEV,DELIVERY_RUNTIME_ARTIFACT' 'Lane/track first row and delivery last nonempty alias'
    Assert-Tokens @(
        @{ Key='ScaleWorldPixelStreamingDeliverymode'; Value='artifact' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value=' ' }
    ) 'LANE_MISSING,TRACK_MISSING,DELIVERY_RUNTIME_ARTIFACT' 'Empty delivery alias does not overwrite'
    Assert-Tokens @(
        @{ Key='ScaleWorldLane'; Value=' None ' },
        @{ Key='ScaleWorldDeploymentTrack'; Value=' None ' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value=' None ' },
        @{ Key='ScaleWorldPixelStreamingRuntimeBundleId'; Value='bundle' }
    ) 'LANE_INVALID,TRACK_MISSING,DELIVERY_RUNTIME_ARTIFACT' 'Legacy None trim order and artifact inference'
    Assert-Tokens @(
        @{ Key='ScaleWorldLane'; Value='dev' },
        @{ Key='ScaleWorldDeploymentTrack'; Value='unknown' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value='unknown' },
        @{ Key='ScaleWorldPixelStreamingRuntimeBundleId'; Value='bundle' }
    ) 'LANE_INVALID,TRACK_MISSING,DELIVERY_INVALID' 'Invalid values retain distinct field outcomes'
    $unsafeValue = 'prod&echo UNSAFE|set X=Y%!"<>'
    Assert-Tokens @(
        @{ Key='ScaleWorldLane'; Value=$unsafeValue },
        @{ Key='ScaleWorldDeploymentTrack'; Value=$unsafeValue },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value=$unsafeValue }
    ) 'LANE_INVALID,TRACK_MISSING,DELIVERY_INVALID' 'Untrusted values never enter CMD output'
    foreach ($alias in @('git_ref', 'git-ref', 'git', 'repo', 'repo_sync')) {
        Assert-Tokens @(@{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value=$alias }) 'LANE_MISSING,TRACK_MISSING,DELIVERY_GIT_REF' "Git alias $alias"
    }
    foreach ($alias in @('runtime_artifact', 'runtime-artifact', 'artifact', 'runtime')) {
        Assert-Tokens @(@{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value=$alias }) 'LANE_MISSING,TRACK_MISSING,DELIVERY_RUNTIME_ARTIFACT' "Artifact alias $alias"
    }
    foreach ($key in @('ScaleWorldPixelStreamingRuntimeBundleId', 'ScaleWorldPixelStreamingRuntimeManifestKey', 'ScaleWorldPixelStreamingRuntimeArtifactKey')) {
        Assert-Tokens @(@{ Key=$key; Value=' identity ' }) 'LANE_MISSING,TRACK_MISSING,DELIVERY_RUNTIME_ARTIFACT' "Artifact identity $key"
        Assert-Tokens @(@{ Key=$key; Value='None' }) 'LANE_MISSING,TRACK_MISSING,DELIVERY_MISSING' "Absent artifact identity $key"
    }
    Assert-Tokens @(@{ Key='ScaleWorldDeploymentTrack'; Value='prod' }) 'LANE_MISSING,TRACK_PROD,DELIVERY_MISSING' 'Prod track'

    $fakeCli = @'
@echo off
echo call>>"%~dp0cli-calls.txt"
echo %*>>"%~dp0cli-arguments.txt"
type "%~dp0cli-output.txt"
set /p FAKE_CLI_EXIT=<"%~dp0cli-exit.txt"
exit /b %FAKE_CLI_EXIT%
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'aws.cmd'), $fakeCli.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
    $fixture = @'
param([string]$ResolverPath, [string]$Field)
$ErrorActionPreference = 'Stop'
$global:StartupMetadataTestRoot = $PSScriptRoot
$global:StartupMetadataTestConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixture-config.json') -Raw | ConvertFrom-Json
$env:PATH = $PSScriptRoot + ';' + $env:PATH
$env:SCALEWORLD_AWS_REGION = [string]$global:StartupMetadataTestConfig.ScaleWorldRegion
$env:AWS_REGION = [string]$global:StartupMetadataTestConfig.AwsRegion
$env:AWS_DEFAULT_REGION = [string]$global:StartupMetadataTestConfig.DefaultRegion
function global:Invoke-RestMethod {
    param([string]$Method, [string]$Uri, [hashtable]$Headers)
    [IO.File]::AppendAllText((Join-Path $global:StartupMetadataTestRoot 'imds-calls.txt'), "$Method|$Uri`r`n")
    if ($Uri.EndsWith('/api/token')) {
        if ($Headers['X-aws-ec2-metadata-token-ttl-seconds'] -ne '21600') { throw 'Unexpected token TTL.' }
        if ($global:StartupMetadataTestConfig.Failure -eq 'token') { throw 'Fixture token failure.' }
        return 'fixture-token'
    }
    if ($Headers['X-aws-ec2-metadata-token'] -ne 'fixture-token') { throw 'Unexpected IMDS token.' }
    if ($Uri.EndsWith('/meta-data/instance-id')) { return ' i-fixture ' }
    if ($Uri.EndsWith('/instance-identity/document')) {
        if ($global:StartupMetadataTestConfig.Failure -eq 'identity') { throw 'Fixture identity failure.' }
        if ($global:StartupMetadataTestConfig.Failure -eq 'region') { return @{ region='' } }
        return @{ region=' eu-north-1 ' }
    }
    throw 'Unexpected IMDS request.'
}
if ($Field) {
    & $ResolverPath -Field $Field
} else {
    & $ResolverPath
}
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'fixture.ps1'), $fixture, [Text.Encoding]::ASCII)
    $validRows = @(
        @{ Key='ScaleWorldLane'; Value='nonprod' },
        @{ Key='ScaleWorldDeploymentTrack'; Value='dev' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value='runtime_artifact' }
    ) | ConvertTo-Json
    $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $validRows
    Assert-Equal $result.Exit 0 'Successful combined lookup exit.'
    Assert-Equal ($result.Tokens -join ',') 'LANE_NONPROD,TRACK_DEV,DELIVERY_RUNTIME_ARTIFACT' 'Successful combined lookup tokens.'
    Assert-Equal $result.CliCalls 1 'Combined lookup AWS invocation count.'
    Assert-Equal $result.ImdsCalls.Count 3 'Combined lookup IMDS invocation count.'
    foreach ($expected in @('ec2 describe-tags', '--region eu-north-1', 'Name=resource-id,Values=i-fixture', '--output json', 'ScaleWorldlane', 'ScaleWorldDeploymenttrack', 'ScaleWorldPixelStreamingDeliverymode', 'ScaleWorldPixelStreamingRuntimeManifestKey', 'ScaleWorldPixelStreamingRuntimeArtifactKey')) {
        if (-not $result.Arguments.Contains($expected)) { throw "Combined lookup omitted argument $expected." }
    }
    foreach ($controlKey in @('ScaleWorldMaintenanceMode', 'ScaleWorldProvisioning', 'ScaleWorldUpdate')) {
        if ($result.Arguments.Contains($controlKey)) { throw "Combined lookup must not cache control key $controlKey." }
    }

    foreach ($case in @(
        @{ Field='lane'; Expected='LANE_NONPROD' },
        @{ Field='track'; Expected='TRACK_DEV' },
        @{ Field='delivery'; Expected='DELIVERY_RUNTIME_ARTIFACT' }
    )) {
        $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $validRows -Field $case.Field
        Assert-Equal $result.Exit 0 'Selected-field lookup exit.'
        Assert-Equal ($result.Tokens -join ',') $case.Expected 'Selected-field token.'
        Assert-Equal $result.CliCalls 1 'Selected-field retry performs one fresh AWS read.'
        $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $validRows -CliExit 7 -Field $case.Field
        Assert-Equal $result.Exit 2 'Selected-field transport failure exit.'
        Assert-Equal $result.Tokens.Count 0 'Selected-field failure emits no token.'
        Assert-Equal $result.CliCalls 1 'Selected-field transport failure does not retry internally.'
    }

    foreach ($case in @(
        @{ Config=@{ ScaleWorldRegion=' us-east-1 '; AwsRegion='us-west-2'; DefaultRegion='eu-west-1' }; Expected='us-east-1' },
        @{ Config=@{ ScaleWorldRegion=' '; AwsRegion=' us-west-2 '; DefaultRegion='eu-west-1' }; Expected='us-west-2' },
        @{ Config=@{ DefaultRegion=' eu-west-1 ' }; Expected='eu-west-1' }
    )) {
        $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $validRows -Config $case.Config
        Assert-Equal $result.Exit 0 ("Region override lookup exit. " + $result.Stderr)
        Assert-Equal $result.CliCalls 1 'Region override AWS invocation count.'
        Assert-Equal $result.ImdsCalls.Count 2 'Region override skips identity document.'
        if (-not $result.Arguments.Contains('--region ' + $case.Expected)) { throw 'Region precedence changed.' }
    }
    foreach ($missing in @('[]', 'null', '')) {
        $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $missing
        Assert-Equal $result.Exit 0 'Missing tag response is successful.'
        Assert-Equal ($result.Tokens -join ',') 'LANE_MISSING,TRACK_MISSING,DELIVERY_MISSING' 'Missing tag response tokens.'
        Assert-Equal $result.CliCalls 1 'Missing tags do not trigger hidden retries.'
    }
    foreach ($case in @(
        @{ Output=$validRows; Exit=7; Config=@{}; Calls=1 },
        @{ Output='{bad-json'; Exit=0; Config=@{}; Calls=1 },
        @{ Output=$validRows; Exit=0; Config=@{ Failure='token' }; Calls=0 },
        @{ Output=$validRows; Exit=0; Config=@{ Failure='identity' }; Calls=0 },
        @{ Output=$validRows; Exit=0; Config=@{ Failure='region' }; Calls=0 }
    )) {
        $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $case.Output -CliExit $case.Exit -Config $case.Config
        Assert-Equal $result.Exit 2 'Failed transport/parse exit.'
        Assert-Equal $result.Tokens.Count 0 'Failed transport/parse must emit no partial tokens.'
        Assert-Equal $result.CliCalls $case.Calls 'Failed lookup must not retry internally.'
    }
    $invalidRows = @(
        @{ Key='ScaleWorldLane'; Value='bad&echo UNSAFE' },
        @{ Key='ScaleWorldDeploymentTrack'; Value='unknown' },
        @{ Key='ScaleWorldPixelStreamingDeliveryMode'; Value='unsupported' }
    ) | ConvertTo-Json
    $result = Invoke-ResolverFixture -Resolver $resolverPath -CliOutput $invalidRows
    Assert-Equal $result.Exit 0 'Successful read retains per-field invalid states.'
    Assert-Equal ($result.Tokens -join ',') 'LANE_INVALID,TRACK_MISSING,DELIVERY_INVALID' 'Invalid values remain fixed CMD-safe tokens.'

    # Measure the unchanged standalone path under the same fake transport. Its
    # three resolver processes each acquire IMDS and call AWS independently.
    $baselineCliCalls = 0
    $baselineImdsCalls = 0
    foreach ($case in @(
        @{ File='resolve_streaming_lane_from_instance_tag.ps1'; Output='nonprod'; Expected='nonprod' },
        @{ File='resolve_deployment_track_from_instance_tag.ps1'; Output='dev'; Expected='dev' },
        @{ File='resolve_pixelstreaming_delivery_mode_from_instance_tag.ps1'; Output=$validRows; Expected='runtime_artifact' }
    )) {
        $result = Invoke-ResolverFixture -Resolver (Join-Path $PSScriptRoot $case.File) -CliOutput $case.Output
        Assert-Equal $result.Exit 0 'Standalone resolver behavior.'
        Assert-Equal ($result.Tokens -join ',') $case.Expected 'Standalone resolver value.'
        $baselineCliCalls += $result.CliCalls
        $baselineImdsCalls += $result.ImdsCalls.Count
    }
    Assert-Equal $baselineCliCalls 3 'Standalone AWS invocation baseline.'
    Assert-Equal $baselineImdsCalls 9 'Standalone IMDS invocation baseline.'
    Write-Output 'Startup metadata batch tests passed (Windows PowerShell 5.1; AWS calls 3 -> 1; IMDS calls 9 -> 3; no internal retries).'
} finally {
    Remove-Module $parserModule
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($testParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected metadata batch test cleanup path.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
