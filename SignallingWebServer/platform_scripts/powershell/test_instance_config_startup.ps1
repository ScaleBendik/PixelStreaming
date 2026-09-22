[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'instance_config.psm1') -Force
function Assert-True($Condition, $Message) { if (!$Condition) { throw $Message } }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sw-config-startup-test-'+[guid]::NewGuid().ToString('N'))
$snapshot=Join-Path $testRoot 'snapshot.json'
$initializer=Join-Path $PSScriptRoot 'initialize_instance_config.ps1'
function Write-Json($Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $testRoot $Name), ($Value | ConvertTo-Json -Depth 20 -Compress), (New-Object Text.UTF8Encoding($false)))
}
function Set-Revision([string]$Environment='dev', [int]$Fps=45) {
    $id=[guid]::NewGuid().ToString('N')
    $standard=@{values=@{resX=2240;resY=1260;fps=$Fps;maxBitrateKbps=30000;forceResolution=0};arguments=@()}
    $premium=@{values=@{resX=2240;resY=1260;fps=60;maxBitrateKbps=30000;forceResolution=0};arguments=@()}
    $doc=@{schemaVersion=1;revisionId=$id;environment=$Environment;standard=$standard;premium=$premium}
    Write-Json 'revision.json' $doc
    $json=[IO.File]::ReadAllText((Join-Path $testRoot 'revision.json'))
    [IO.File]::WriteAllText((Join-Path $testRoot ($id+'.json')), $json, (New-Object Text.UTF8Encoding($false)))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $reference=@{revisionId=$id;manifestKey="InstanceConfig/v1/$Environment/revisions/$id.json";sha256=$hash}
    Write-Json 'pointer.json' $reference
    return $reference
}
function Run-Startup([string]$Environment='dev', [string]$Mode='normal', [string]$Class='standard', [string]$Failure='', [bool]$Running=$false) {
    # Execute the unmodified production script. Cloud, process inspection and tag resolution are mocked.
    $ps=[PowerShell]::Create()
    try {
        [void]$ps.AddScript({
            param($Root,$Initializer,$Environment,$Mode,$Class,$Failure,$Running)
            $global:ConfigTestRoot=$Root
            $global:ConfigTestClass=$Class
            $global:ConfigTestFailure=$Failure
            $global:ConfigTestRunning=$Running
            function global:Get-Command { param($Name) [pscustomobject]@{Source=(Join-Path $global:ConfigTestRoot 'aws-mock.ps1')} }
            function global:Invoke-RestMethod {
                param($Method,$Uri,$Headers,$TimeoutSec)
                if ($Uri -like '*/api/token') { return 'token' }
                if ($Uri -like '*/instance-id') { return 'i-test' }
                return [pscustomobject]@{instanceId='i-test';region='eu-north-1'}
            }
            function global:Get-CimInstance {
                param($ClassName)
                if ($global:ConfigTestRunning) { [pscustomobject]@{Name='ScaleWorld.exe';CommandLine='mock'} }
            }
            & $Initializer -RuntimeRoot $Root -InstallBase $Root -Environment $Environment -Mode $Mode -SnapshotPath (Join-Path $Root 'snapshot.json')
        }).AddArgument($testRoot).AddArgument($initializer).AddArgument($Environment).AddArgument($Mode).AddArgument($Class).AddArgument($Failure).AddArgument($Running)
        $output=$ps.Invoke()
        if ($ps.HadErrors) { throw ($ps.Streams.Error | Out-String) }
        return $output
    } finally { $ps.Dispose() }
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $errorText=$null
    try { & $Action | Out-Null } catch { $errorText=$_.Exception.Message }
    Assert-True ($errorText -and $errorText -match $Pattern) "Expected failure '$Pattern', got '$errorText'."
}
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'state'))
    Write-Json 'runtime-bundle-metadata.json' @{bundleId='runtime-1'}
    Write-Json 'state/current-release.json' @{BuildId='s3-etag-not-the-build-name';ZipKey='scaleworldbuilds/ScaleWorld_test.zip'}
    [IO.File]::WriteAllText((Join-Path $testRoot 'aws-mock.ps1'), @'
$global:LASTEXITCODE=0
if ($args[0] -eq 'ec2') { return $global:ConfigTestClass }
if ($global:ConfigTestFailure -eq 'unavailable') { $global:LASTEXITCODE=1; return 'AccessDenied' }
if ($args[0] -eq 'ssm') {
    if ($global:ConfigTestFailure -eq 'missing') { $global:LASTEXITCODE=1; return 'ParameterNotFound' }
    return [IO.File]::ReadAllText((Join-Path $global:ConfigTestRoot 'candidate.json'))
}
if ($args[2] -like '*/current.json') {
    if ($global:ConfigTestFailure -eq 'missing') { $global:LASTEXITCODE=1; return '404 NoSuchKey' }
    return [IO.File]::ReadAllText((Join-Path $global:ConfigTestRoot 'pointer.json'))
}
return [IO.File]::ReadAllText((Join-Path $global:ConfigTestRoot (Split-Path -Leaf $args[2])))
'@)
    Run-Startup -Failure 'missing' | Out-Null
    Assert-True ($null -eq (Read-InstanceConfigSnapshot $snapshot).profile) 'Missing first Dev publication must preserve legacy startup.'
    $first=Set-Revision
    Run-Startup | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).profile.values.fps -eq 45) 'General/Standard profile was not loaded.'
    $before=[IO.File]::ReadAllText($snapshot)
    $second=Set-Revision -Fps 50
    Run-Startup -Mode recovery | Out-Null
    Assert-True ([IO.File]::ReadAllText($snapshot) -ceq $before) 'Recovery adopted a new revision.'
    Run-Startup -Running $true | Out-Null
    Assert-True ([IO.File]::ReadAllText($snapshot) -ceq $before) 'Repeated start changed a running stack.'
    Run-Startup | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $second.revisionId) 'Normal start did not adopt latest Dev revision.'
    Run-Startup -Failure unavailable | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).source -eq 'cached') 'Matching cached snapshot was not retained.'
    Expect-Failure { Run-Startup -Failure missing } 'Previously configured Dev pointer is missing'
    Expect-Failure { Run-Startup -Class premium -Failure unavailable } 'Unable to read configuration'
    Run-Startup -Class premium | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).profile.values.fps -eq 60) 'Serving Premium class was not used.'
    [IO.File]::AppendAllText((Join-Path $testRoot ($second.revisionId+'.json')),' ')
    Expect-Failure { Run-Startup -Class premium } 'checksum mismatch'
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $second.revisionId) 'Invalid data replaced the last good snapshot.'
    $stage=Set-Revision -Environment stage
    Write-Json 'candidate.json' @{candidateId='stage-test';runtimeArtifact=@{bundleId='runtime-1'};unrealBuildId='ScaleWorld_test.zip';instanceConfig=$stage}
    Run-Startup -Environment stage | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $stage.revisionId) 'Stage did not pin its candidate configuration.'
    $unused=Set-Revision -Environment stage -Fps 70
    Run-Startup -Environment stage | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $stage.revisionId) 'Stage followed the editor pointer instead of its candidate.'
    Write-Json 'candidate.json' @{candidateId='new-binaries';runtimeArtifact=@{bundleId='runtime-2'};unrealBuildId='ScaleWorld_test.zip';instanceConfig=$unused}
    Run-Startup -Environment stage | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $stage.revisionId) 'New candidate changed configuration on old binaries.'
    Run-Startup -Environment stage -Mode validation | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $unused.revisionId) 'Maintenance validation could not install new binaries before candidate capture.'
    Run-Startup -Environment prod -Mode validation | Out-Null
    Assert-True ((Read-InstanceConfigSnapshot $snapshot).reference.revisionId -eq $unused.revisionId) 'Prod did not read the Stage immutable revision.'
    Expect-Failure { Run-Startup -Environment dev } 'incorrect scope'
    Write-Json 'candidate.json' @{candidateId='legacy';runtimeArtifact=@{bundleId='runtime-1'};unrealBuildId='ScaleWorld_test.zip'}
    Run-Startup -Environment stage | Out-Null
    Assert-True ($null -eq (Read-InstanceConfigSnapshot $snapshot).profile) 'Legacy candidate rollback did not clear custom configuration.'
    Expect-Failure { Run-Startup -Environment prod -Mode recovery } 'matching startup configuration snapshot'
    Write-Output 'Instance config startup: legacy, served class, normal start, recovery, cache, checksum, environment and candidate tests passed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'sw-config-startup-test-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
