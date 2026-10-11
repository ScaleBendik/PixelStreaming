[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'invoke-dev-startup-delay-experiment.ps1') -FunctionsOnly

function Assert-True { param([bool]$Condition,[string]$Message) if (!$Condition) { throw $Message } }
function Assert-Fails {
    param([scriptblock]$Action,[string]$Pattern)
    $message=$null
    try { & $Action | Out-Null } catch { $message=$_.Exception.Message }
    if (!$message -or ($Pattern -and $message -notmatch $Pattern)) { throw "Expected rejection matching '$Pattern'; received '$message'." }
    $script:checks++
}
$script:checks=0
$baseline=@'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>Bendik &#216;</Author><URI>\start_streamer_stack</URI></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT20S</Delay></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></LogonTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><IdleSettings><StopOnIdleEnd>true</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>15</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec><Command>C:\PixelStreaming\PixelStreaming\SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat</Command></Exec></Actions>
</Task>
'@
# Use literal non-ASCII XML text to exercise PS5.1's UTF8-without-BOM backup reads.
$baseline=$baseline.Replace('&#216;',([string][char]216))
Assert-StartupDelayTaskShape $baseline
$candidate=Get-StartupDelayCandidateXml $baseline
Assert-StartupDelayTaskShape $candidate 'PT15S'
Assert-StartupDelayDefinition $candidate ($baseline.Replace('PT20S','PT15S'))
$formatted=(Read-StartupDelayTaskXml $candidate)
foreach ($element in @($formatted.SelectNodes('//*'))) { $element.Prefix='t' }
Assert-StartupDelayDefinition $formatted.OuterXml $candidate
$script:checks+=4

foreach ($change in @(
    @('PT30S','PT10S'),@('S-1-5-18','S-1-5-19'),@('ServiceAccount','InteractiveToken'),
    @('HighestAvailable','LeastPrivilege'),@('IgnoreNew','Parallel'),@('<Count>15</Count>','<Count>30</Count>'),
    @('<Interval>PT1M</Interval>','<Interval>PT30S</Interval>'),@('<Priority>7</Priority>','<Priority>8</Priority>'),
    @('start_streamer_stack.bat','start_dev_turn.bat'),@('<RunOnlyIfNetworkAvailable>false','<RunOnlyIfNetworkAvailable>true')
)) { $modified=$candidate.Replace($change[0],$change[1]); Assert-Fails { Assert-StartupDelayDefinition $modified $candidate } 'beyond the permitted' }
Assert-Fails { Assert-StartupDelayTaskShape ($baseline.Replace('PT20S','PT5S')) } 'boot/logon'
Assert-Fails { Assert-StartupDelayTaskShape ($baseline.Replace('</Triggers>','<BootTrigger><Delay>PT20S</Delay></BootTrigger></Triggers>')) } 'exactly one'
Assert-Fails { Assert-StartupDelayTaskShape ($baseline.Replace('<Delay>PT30S</Delay>','<Delay>PT30S</Delay><UserId>S-1-5-18</UserId>')) } 'logon scope'
Assert-Fails { Read-StartupDelayTaskXml '<!DOCTYPE Task [<!ENTITY x "bad">]><Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">&x;</Task>' } 'DTD'

$instanceId='i-0123456789abcdef0'
$identity=[pscustomobject]@{instanceId=$instanceId;region='eu-north-1'}
$tags=@([pscustomobject]@{Key='Name';Value='ScaleWorld_d1'},[pscustomobject]@{Key='ScaleWorldDeploymentTrack';Value='dev'})
Assert-DevStartupDelayTargetValues $instanceId $identity $tags
$script:checks++
Assert-Fails { Assert-DevStartupDelayTargetValues '' $identity $tags } 'explicit EC2'
Assert-Fails { Assert-DevStartupDelayTargetValues 'i-0123456789abcdef1' $identity $tags } 'Host identity'
Assert-Fails { Assert-DevStartupDelayTargetValues $instanceId $identity @($tags[0],[pscustomobject]@{Key='ScaleWorldDeploymentTrack';Value='prod'}) } 'only Name'
Assert-Fails { Assert-DevStartupDelayTargetValues $instanceId $identity @([pscustomobject]@{Key='Name';Value='ScaleWorld_d2'},$tags[1]) } 'only Name'
Assert-Fails { Assert-DevStartupDelayTargetValues $instanceId $identity @($tags+$tags[1]) } 'only Name'

# Exercise the real target adapter with native multiline JSON stdout under PS5.1.
# Only IMDS and executable discovery are stubbed; native invocation/parsing/guards remain real.
$nativeRoot=Join-Path ([IO.Path]::GetTempPath()) ('startup-delay-native-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $nativeRoot | Out-Null
$nativeJson=Join-Path $nativeRoot 'tags.json'
$nativeAws=Join-Path $nativeRoot 'aws-fixture.cmd'
$nativeUtf8=New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($nativeAws,('@echo off'+"`r`n"+'type "'+$nativeJson+'"'+"`r`n"+'exit /b 0'+"`r`n"),$nativeUtf8)
function Invoke-RestMethod { param($Method,$Uri,$Headers,$TimeoutSec) if ($Uri -like '*/api/token') { 'fixture-token' } else { $identity } }
function Get-Command { param($Name,$ErrorAction) if ($Name -cne 'aws') { throw 'Unexpected fixture executable discovery' }; [pscustomobject]@{Source=$nativeAws} }
try {
    [IO.File]::WriteAllText($nativeJson,($tags | ConvertTo-Json -Depth 3),$nativeUtf8)
    $target=Get-DevStartupDelayTarget $instanceId
    Assert-True ($target.instanceId -ceq $instanceId -and $target.deploymentTrack -ceq 'dev') 'Native multiline tag JSON rejected the valid exact target.'
    [IO.File]::WriteAllText($nativeJson,(@($tags[0],[pscustomobject]@{Key='ScaleWorldDeploymentTrack';Value='prod'}) | ConvertTo-Json -Depth 3),$nativeUtf8)
    Assert-Fails { Get-DevStartupDelayTarget $instanceId } 'only Name'
    [IO.File]::WriteAllText($nativeJson,(@($tags+$tags[1]) | ConvertTo-Json -Depth 3),$nativeUtf8)
    Assert-Fails { Get-DevStartupDelayTarget $instanceId } 'only Name'
    $script:checks++
} finally {
    Remove-Item Function:\Invoke-RestMethod
    Remove-Item Function:\Get-Command
    $resolvedNativeRoot=[IO.Path]::GetFullPath($nativeRoot)
    $resolvedNativeTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (!$resolvedNativeRoot.StartsWith($resolvedNativeTemp,[StringComparison]::OrdinalIgnoreCase)) { throw 'Native fixture cleanup path escaped the temporary directory.' }
    Remove-Item -LiteralPath $resolvedNativeRoot -Recurse -Force
}

# Replace only host adapters. The experiment/backup/hash/drift/rollback implementation remains real.
function Get-DevStartupDelayTarget { param($ExpectedInstanceId) if ($ExpectedInstanceId -cne $instanceId) { throw 'Wrong mock host' }; [pscustomobject]@{instanceId=$instanceId;name='ScaleWorld_d1';deploymentTrack='dev'} }
function Get-StartupDelayHostTaskXml { return $script:hostXml }
function Get-StartupDelayHistoryState { [pscustomobject]@{enabled=$script:historyEnabled;recordCount=123} }
function Set-StartupDelayHistoryState {
    param([bool]$Enabled)
    $script:historyWrites++
    $script:historyEnabled=$Enabled
    if ($script:failHistoryEnable -and $Enabled) { throw 'Forced history enable failure' }
}
function Set-StartupDelayHostBootDelay {
    param($Delay,$ExpectedCurrentXml,[ref]$MutationAttempted)
    Assert-StartupDelayDefinition $script:hostXml $ExpectedCurrentXml
    $MutationAttempted.Value=$true
    $script:taskWrites++
    $script:hostXml=Get-StartupDelayCandidateXml $script:hostXml $Delay
    if ($script:postChangeDrift) { $script:hostXml=$script:hostXml.Replace('<Priority>7</Priority>','<Priority>8</Priority>') }
}
function Restore-StartupDelayHostXml {
    param($Xml)
    $script:xmlRestores++
    if ($script:failXmlRestore) { throw 'Forced exact XML restore failure' }
    $script:hostXml=$Xml
    Assert-StartupDelayDefinition $script:hostXml $Xml
}
function Reset-MockHost {
    $script:hostXml=$baseline; $script:historyEnabled=$false
    $script:taskWrites=0; $script:historyWrites=0; $script:xmlRestores=0
    $script:postChangeDrift=$false; $script:failXmlRestore=$false; $script:failHistoryEnable=$false
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('startup-delay-fixtures-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function New-CapturedCase {
    Reset-MockHost
    $directory=Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $result=Invoke-DevStartupDelayExperiment -Mode Capture -ExpectedInstanceId $instanceId -BackupDirectory $directory
    return @{directory=$directory;hash=$result.receiptSha256;capture=$result}
}
try {
    Reset-MockHost
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Capture -ExpectedInstanceId $instanceId -BackupDirectory 'C:relative' } 'drive-rooted'
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Capture -ExpectedInstanceId $instanceId -BackupDirectory '//server/share' } 'drive-rooted'
    Assert-True ($script:taskWrites -eq 0 -and $script:historyWrites -eq 0) 'Invalid backup paths changed host state.'
    $directory=Join-Path $testRoot 'complete-cycle'
    $capture=Invoke-DevStartupDelayExperiment -Mode Capture -ExpectedInstanceId $instanceId -BackupDirectory $directory -EnableTaskHistory $true
    Assert-True ($capture.historyEnabled -and !$capture.historyBaselineEnabled -and $capture.historyBaselineRecordCount -eq 123 -and $script:taskWrites -eq 0) 'Capture did not preserve the task/initial history evidence.'
    Assert-StartupDelayDefinition (Get-Content (Join-Path $directory 'startup-task.xml') -Raw -Encoding UTF8) $baseline
    $apply=Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $directory -ExpectedReceiptSha256 $capture.receiptSha256
    Assert-True ($apply.bootDelay -ceq 'PT15S' -and $script:taskWrites -eq 1 -and $script:historyEnabled) 'Apply did not perform the expected isolated edit.'
    Assert-StartupDelayDefinition $script:hostXml $candidate
    $historyRestore=Invoke-DevStartupDelayExperiment -Mode RestoreHistory -ExpectedInstanceId $instanceId -BackupDirectory $directory -ExpectedReceiptSha256 $capture.receiptSha256
    Assert-True (!$script:historyEnabled -and $historyRestore.bootDelay -ceq 'PT15S' -and $script:taskWrites -eq 1) 'History-only restore changed the accepted task.'
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $directory -ExpectedReceiptSha256 $capture.receiptSha256 } 'not the expected 20-second'
    $restore=Invoke-DevStartupDelayExperiment -Mode Restore -ExpectedInstanceId $instanceId -BackupDirectory $directory -ExpectedReceiptSha256 $capture.receiptSha256
    Assert-True ($restore.bootDelay -ceq 'PT20S' -and !$script:historyEnabled -and $script:taskWrites -eq 2) 'Restore did not restore the baseline task/history.'
    Assert-StartupDelayDefinition $script:hostXml $baseline
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Capture -ExpectedInstanceId $instanceId -BackupDirectory $directory } 'backup already exists'
    $script:checks+=7

    $case=New-CapturedCase
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 ('0'*64) } 'Receipt hash mismatch'
    Assert-True ($script:taskWrites -eq 0 -and $script:historyWrites -eq 0) 'Hash rejection mutated host settings.'
    Add-Content -LiteralPath (Join-Path $case.directory 'startup-task.xml') -Value '<!--changed-->' -Encoding UTF8
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 $case.hash } 'Task backup hash mismatch'

    $case=New-CapturedCase
    $script:hostXml=$candidate.Replace('PT30S','PT10S')
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Restore -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 $case.hash } 'unexpected drift'
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode RestoreHistory -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 $case.hash } 'unexpected drift'
    Assert-True ($script:taskWrites -eq 0 -and $script:historyWrites -eq 0 -and $script:xmlRestores -eq 0) 'Restore overwrote unknown drift.'

    $case=New-CapturedCase
    $script:postChangeDrift=$true
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 $case.hash -EnableTaskHistory $true } 'exact baseline task XML restored'
    Assert-StartupDelayDefinition $script:hostXml $baseline
    Assert-True ($script:xmlRestores -eq 1 -and !$script:historyEnabled) 'Unexpected post-change drift did not restore exact task + prior history state.'

    $case=New-CapturedCase
    $script:postChangeDrift=$true; $script:failXmlRestore=$true
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 $case.hash -EnableTaskHistory $true } 'ROLLBACK INCOMPLETE'
    Assert-True (!$script:historyEnabled) 'Failed task rollback prevented independent history rollback.'

    $case=New-CapturedCase
    $script:failHistoryEnable=$true
    Assert-Fails { Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $case.directory -ExpectedReceiptSha256 $case.hash -EnableTaskHistory $true } 'task was not modified'
    Assert-True ($script:taskWrites -eq 0 -and $script:xmlRestores -eq 0 -and !$script:historyEnabled) 'Pre-task history failure rewrote the task or left history enabled.'
    Reset-MockHost
    $script:historyEnabled=$true
    $directory=Join-Path $testRoot 'history-already-enabled'
    $capture=Invoke-DevStartupDelayExperiment -Mode Capture -ExpectedInstanceId $instanceId -BackupDirectory $directory -EnableTaskHistory $true
    Assert-True ($capture.historyBaselineEnabled -and $script:historyWrites -eq 0) 'Capture rewrote an already enabled history setting.'
    Invoke-DevStartupDelayExperiment -Mode Apply -ExpectedInstanceId $instanceId -BackupDirectory $directory -ExpectedReceiptSha256 $capture.receiptSha256 | Out-Null
    Invoke-DevStartupDelayExperiment -Mode Restore -ExpectedInstanceId $instanceId -BackupDirectory $directory -ExpectedReceiptSha256 $capture.receiptSha256 | Out-Null
    Assert-True $script:historyEnabled 'Restore did not preserve an initially enabled history setting.'
    $script:checks+=8
    Write-Output "Dev startup-delay harness passed ($script:checks assertions/scenarios; mocked host/task/history, real XML and backup I/O; no AWS or scheduled-task mutations)."
} finally {
    $resolvedTestRoot=[IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (!$resolvedTestRoot.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup path escaped the temporary directory.' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
