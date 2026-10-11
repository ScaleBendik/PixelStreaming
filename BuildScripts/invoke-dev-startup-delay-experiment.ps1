# Temporary operator experiment; this is not invoked by runtime startup or AMI preparation.
# Capture -EnableTaskHistory before the 20-second control. Apply only after its acceptance.
# Keep the returned receipt hash outside the host backup directory and supply it on later calls.
# Restore restores task + history; RestoreHistory keeps an accepted 15-second task definition.
[CmdletBinding()]
param(
    [ValidateSet('Capture','Apply','Restore','RestoreHistory')][string]$Mode='Capture',
    [string]$ExpectedInstanceId='',
    [string]$BackupDirectory='',
    [string]$ExpectedReceiptSha256='',
    [switch]$EnableTaskHistory,
    [switch]$FunctionsOnly
)
$ErrorActionPreference='Stop'

function Read-StartupDelayTaskXml {
    param([string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml) -or $Xml.Length -gt 65536) { throw 'Missing or oversized task XML.' }
    $settings=New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing=[System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $reader=[System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($Xml)), $settings)
    try {
        $document=New-Object System.Xml.XmlDocument
        $document.XmlResolver=$null
        $document.Load($reader)
    } finally { $reader.Dispose() }
    if ($document.DocumentElement.LocalName -ne 'Task' -or $document.DocumentElement.NamespaceURI -ne 'http://schemas.microsoft.com/windows/2004/02/mit/task') { throw 'Unexpected task XML namespace.' }
    return $document
}

function ConvertTo-StartupDelaySemanticXml {
    param([string]$Xml)
    $document=Read-StartupDelayTaskXml $Xml
    $builder=New-Object System.Text.StringBuilder
    function Add-TaskNode {
        param([System.Xml.XmlNode]$Node)
        if ($Node.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            [void]$builder.Append('E'+$Node.NamespaceURI.Length+':'+$Node.NamespaceURI+$Node.LocalName.Length+':'+$Node.LocalName)
            foreach ($attribute in @($Node.Attributes | Where-Object { $_.NamespaceURI -ne 'http://www.w3.org/2000/xmlns/' } | Sort-Object NamespaceURI,LocalName)) {
                [void]$builder.Append('A'+$attribute.NamespaceURI.Length+':'+$attribute.NamespaceURI+$attribute.LocalName.Length+':'+$attribute.LocalName+$attribute.Value.Length+':'+$attribute.Value)
            }
            foreach ($child in $Node.ChildNodes) { Add-TaskNode $child }
            [void]$builder.Append('Z')
        } elseif ($Node.NodeType -in @([System.Xml.XmlNodeType]::Text,[System.Xml.XmlNodeType]::CDATA)) {
            [void]$builder.Append('T'+$Node.Value.Length+':'+$Node.Value)
        }
    }
    Add-TaskNode $document.DocumentElement
    return $builder.ToString()
}

function Get-StartupDelayTextSha256 {
    param([string]$Text)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-StartupDelayTaskShape {
    param([string]$Xml, [ValidateSet('PT20S','PT15S')][string]$BootDelay='PT20S')
    $document=Read-StartupDelayTaskXml $Xml
    $ns=New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('t',$document.DocumentElement.NamespaceURI)
    $triggers=@($document.SelectNodes('/t:Task/t:Triggers/*',$ns))
    $boot=@($document.SelectNodes('/t:Task/t:Triggers/t:BootTrigger',$ns))
    $logon=@($document.SelectNodes('/t:Task/t:Triggers/t:LogonTrigger',$ns))
    if ($triggers.Count -ne 2 -or $boot.Count -ne 1 -or $logon.Count -ne 1) { throw 'Expected exactly one Boot and one Logon trigger.' }
    if ([string]$boot[0].Delay -cne $BootDelay -or [string]$logon[0].Delay -cne 'PT30S' -or $logon[0].SelectSingleNode('t:UserId',$ns)) { throw 'Unexpected boot/logon delay or logon scope.' }
    foreach ($trigger in $triggers) {
        $enabled=$trigger.SelectSingleNode('t:Enabled',$ns)
        if ($enabled -and $enabled.InnerText -cne 'true') { throw 'Disabled startup trigger.' }
    }
    $principals=@($document.SelectNodes('/t:Task/t:Principals/t:Principal',$ns))
    if ($principals.Count -ne 1) { throw 'Unexpected task principals.' }
    $principal=$principals[0]
    if ([string]$principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18') -or [string]$principal.RunLevel -cne 'HighestAvailable' -or $principal.SelectSingleNode('t:GroupId',$ns)) { throw 'Expected the highest-privilege SYSTEM principal.' }
    $logonType=$principal.SelectSingleNode('t:LogonType',$ns)
    if ($logonType -and $logonType.InnerText -cne 'ServiceAccount') { throw 'Expected a service-account task.' }
    $settings=$document.SelectSingleNode('/t:Task/t:Settings',$ns)
    if (!$settings -or [string]$settings.MultipleInstancesPolicy -cne 'IgnoreNew' -or [string]$settings.RestartOnFailure.Interval -cne 'PT1M' -or [string]$settings.RestartOnFailure.Count -cne '15') { throw 'Unexpected multiple-instance or failure-restart policy.' }
    $actions=@($document.SelectNodes('/t:Task/t:Actions/*',$ns))
    $expectedCommand='C:\PixelStreaming\PixelStreaming\SignallingWebServer\platform_scripts\cmd\start_streamer_stack.bat'
    if ($actions.Count -ne 1 -or $actions[0].LocalName -ne 'Exec' -or [string]$actions[0].Command -ine $expectedCommand -or ![string]::IsNullOrWhiteSpace([string]$actions[0].Arguments) -or ![string]::IsNullOrWhiteSpace([string]$actions[0].WorkingDirectory)) { throw 'Expected the unchanged canonical direct BAT action with no arguments/working directory.' }
}

function Get-StartupDelayCandidateXml {
    param([string]$BaselineXml, [ValidateSet('PT20S','PT15S')][string]$Delay='PT15S')
    $document=Read-StartupDelayTaskXml $BaselineXml
    $ns=New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('t',$document.DocumentElement.NamespaceURI)
    $nodes=@($document.SelectNodes('/t:Task/t:Triggers/t:BootTrigger/t:Delay',$ns))
    if ($nodes.Count -ne 1) { throw 'Expected exactly one existing BootTrigger.Delay.' }
    $nodes[0].InnerText=$Delay
    return $document.OuterXml
}

function Assert-StartupDelayDefinition {
    param([string]$ActualXml,[string]$ExpectedXml)
    if ((ConvertTo-StartupDelaySemanticXml $ActualXml) -cne (ConvertTo-StartupDelaySemanticXml $ExpectedXml)) { throw 'Task definition differs beyond the permitted BootTrigger.Delay change.' }
}

function Assert-DevStartupDelayTargetValues {
    param([string]$ExpectedInstanceId,$Identity,[object[]]$Tags)
    if ($ExpectedInstanceId -cnotmatch '^i-([a-f0-9]{8}|[a-f0-9]{17})$') { throw 'An explicit EC2 instance ID is required.' }
    if ($Identity.instanceId -cne $ExpectedInstanceId -or [string]$Identity.region -cnotmatch '^[a-z]{2}-[a-z]+-[0-9]$') { throw 'Host identity does not match the explicit target.' }
    $name=@($Tags | Where-Object { $_.Key -ceq 'Name' })
    $track=@($Tags | Where-Object { $_.Key -ceq 'ScaleWorldDeploymentTrack' })
    if ($name.Count -ne 1 -or $name[0].Value -cne 'ScaleWorld_d1' -or $track.Count -ne 1 -or $track[0].Value -cne 'dev') { throw 'This helper permits only Name=ScaleWorld_d1 and deployment track=dev.' }
}

function Get-DevStartupDelayTarget {
    param([string]$ExpectedInstanceId)
    if ($ExpectedInstanceId -cnotmatch '^i-([a-f0-9]{8}|[a-f0-9]{17})$') { throw 'An explicit EC2 instance ID is required.' }
    $token=Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='60'} -TimeoutSec 5
    $identity=Invoke-RestMethod -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers @{'X-aws-ec2-metadata-token'=$token} -TimeoutSec 5
    if ($identity.instanceId -cne $ExpectedInstanceId -or [string]$identity.region -cnotmatch '^[a-z]{2}-[a-z]+-[0-9]$') { throw 'Host identity does not match the explicit target.' }
    $aws=(Get-Command aws -ErrorAction Stop).Source
    $output=& $aws ec2 describe-tags --region $identity.region --filters "Name=resource-id,Values=$ExpectedInstanceId" --query "Tags[?Key=='Name' || Key=='ScaleWorldDeploymentTrack'].{Key:Key,Value:Value}" --output json --cli-connect-timeout 5 --cli-read-timeout 10 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Cannot validate the Dev d1 target tags.' }
    # PS5.1 returns a JSON array as one pipeline object. Do not wrap that pipeline
    # in @(...), which creates a nested array and rejects valid exact target tags.
    $tags=ConvertFrom-Json -InputObject ($output -join "`n")
    Assert-DevStartupDelayTargetValues $ExpectedInstanceId $identity $tags
    return [pscustomobject]@{instanceId=$ExpectedInstanceId;name='ScaleWorld_d1';deploymentTrack='dev'}
}

function Get-StartupDelayHostTaskXml {
    $task=Get-ScheduledTask -TaskName 'start_streamer_stack' -TaskPath '\' -ErrorAction Stop
    if ([string]$task.State -eq 'Running') { throw 'The task action is running; wait until it completes.' }
    return (Export-ScheduledTask -TaskName 'start_streamer_stack' -TaskPath '\' -ErrorAction Stop)
}

function Set-StartupDelayHostBootDelay {
    param([string]$Delay,[string]$ExpectedCurrentXml,[ref]$MutationAttempted)
    Assert-StartupDelayDefinition (Get-StartupDelayHostTaskXml) $ExpectedCurrentXml
    $task=Get-ScheduledTask -TaskName 'start_streamer_stack' -TaskPath '\' -ErrorAction Stop
    $boot=@($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
    if ($boot.Count -ne 1) { throw 'Expected exactly one live Boot trigger.' }
    $boot[0].Delay=$Delay
    $MutationAttempted.Value=$true
    Set-ScheduledTask -TaskName 'start_streamer_stack' -TaskPath '\' -Trigger $task.Triggers -ErrorAction Stop | Out-Null
}

function Restore-StartupDelayHostXml {
    param([string]$Xml)
    Register-ScheduledTask -TaskName 'start_streamer_stack' -TaskPath '\' -Xml $Xml -Force -ErrorAction Stop | Out-Null
    Assert-StartupDelayDefinition (Get-StartupDelayHostTaskXml) $Xml
}

function Get-StartupDelayHistoryState {
    $log=Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction Stop
    return [pscustomobject]@{enabled=[bool]$log.IsEnabled;recordCount=$log.RecordCount}
}

function Set-StartupDelayHistoryState {
    param([bool]$Enabled)
    $configuration=New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration('Microsoft-Windows-TaskScheduler/Operational')
    try { $configuration.IsEnabled=$Enabled; $configuration.SaveChanges() }
    finally { $configuration.Dispose() }
    if ((Get-StartupDelayHistoryState).enabled -ne $Enabled) { throw 'Task history enabled state did not match the requested value.' }
}

function Invoke-DevStartupDelayExperiment {
    param([string]$Mode,[string]$ExpectedInstanceId,[string]$BackupDirectory,[string]$ExpectedReceiptSha256,[bool]$EnableTaskHistory=$false)
    if ($Mode -notin @('Capture','Apply','Restore','RestoreHistory')) { throw 'Unknown experiment mode.' }
    if ($EnableTaskHistory -and $Mode -in @('Restore','RestoreHistory')) { throw 'EnableTaskHistory is permitted only for Capture/Apply.' }
    $target=Get-DevStartupDelayTarget $ExpectedInstanceId
    if ($BackupDirectory -notmatch '^[A-Za-z]:[\\/]') { throw 'A drive-rooted local absolute backup directory is required.' }
    $directory=[IO.Path]::GetFullPath($BackupDirectory)
    if ($directory.StartsWith('\\') -or $directory -notmatch '^[A-Za-z]:\\') { throw 'A local absolute backup directory is required.' }
    if (!(Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null }
    $lock=$null
    try {
        $lock=[IO.File]::Open((Join-Path $directory 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $xmlPath=Join-Path $directory 'startup-task.xml'
        $receiptPath=Join-Path $directory 'startup-delay-receipt.json'
        $currentXml=Get-StartupDelayHostTaskXml
        $expectedFinalXml=$currentXml
        $finalXml=$null
        $finalHistory=$null
        $historyBefore=Get-StartupDelayHistoryState
        $utf8=New-Object System.Text.UTF8Encoding($false)
        if ($Mode -eq 'Capture') {
            if ((Test-Path -LiteralPath $xmlPath) -or (Test-Path -LiteralPath $receiptPath)) { throw 'A backup already exists; use a new directory rather than replacing evidence.' }
            Assert-StartupDelayTaskShape $currentXml 'PT20S'
            [IO.File]::WriteAllText($xmlPath,$currentXml,$utf8)
            $receipt=[ordered]@{schemaVersion=1;scope='Dev-d1-startup-delay';capturedUtc=[DateTime]::UtcNow.ToString('o');instanceId=$target.instanceId;instanceName=$target.name;deploymentTrack=$target.deploymentTrack;taskName='start_streamer_stack';taskPath='\';baselineDelay='PT20S';candidateDelay='PT15S';taskXmlSha256=(Get-FileHash -LiteralPath $xmlPath -Algorithm SHA256).Hash.ToLowerInvariant();baselineSemanticSha256=Get-StartupDelayTextSha256 (ConvertTo-StartupDelaySemanticXml $currentXml);candidateSemanticSha256=Get-StartupDelayTextSha256 (ConvertTo-StartupDelaySemanticXml (Get-StartupDelayCandidateXml $currentXml));historyEnabled=$historyBefore.enabled;historyRecordCount=$historyBefore.recordCount}
            [IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 4),$utf8)
            # Verify retained evidence before changing even the history enabled state.
            if ((Get-FileHash -LiteralPath $xmlPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $receipt.taskXmlSha256) { throw 'Backup verification failed.' }
            if ($EnableTaskHistory -and !$historyBefore.enabled) {
                try { Set-StartupDelayHistoryState $true; Assert-StartupDelayDefinition (Get-StartupDelayHostTaskXml) $currentXml }
                catch { $cause=$_.Exception.Message; try { Set-StartupDelayHistoryState $historyBefore.enabled } catch { throw "History enable failed and history rollback failed: $cause" }; throw $cause }
            }
        } else {
            if ($ExpectedReceiptSha256 -cnotmatch '^[a-f0-9]{64}$' -or !(Test-Path -LiteralPath $receiptPath) -or !(Test-Path -LiteralPath $xmlPath)) { throw 'Existing backup and independently retained receipt SHA256 are required.' }
            if ((Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedReceiptSha256) { throw 'Receipt hash mismatch; no settings changed.' }
            $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($receipt.schemaVersion -ne 1 -or $receipt.scope -cne 'Dev-d1-startup-delay' -or $receipt.instanceId -cne $target.instanceId -or $receipt.instanceName -cne $target.name -or $receipt.deploymentTrack -cne 'dev' -or $receipt.taskName -cne 'start_streamer_stack' -or $receipt.taskPath -cne '\' -or $receipt.baselineDelay -cne 'PT20S' -or $receipt.candidateDelay -cne 'PT15S' -or $receipt.historyEnabled -isnot [bool]) { throw 'Receipt target or baseline contract mismatch.' }
            if ((Get-FileHash -LiteralPath $xmlPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $receipt.taskXmlSha256) { throw 'Task backup hash mismatch; no settings changed.' }
            $baselineXml=Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
            Assert-StartupDelayTaskShape $baselineXml 'PT20S'
            $candidateXml=Get-StartupDelayCandidateXml $baselineXml
            if ((Get-StartupDelayTextSha256 (ConvertTo-StartupDelaySemanticXml $baselineXml)) -cne $receipt.baselineSemanticSha256 -or (Get-StartupDelayTextSha256 (ConvertTo-StartupDelaySemanticXml $candidateXml)) -cne $receipt.candidateSemanticSha256) { throw 'Backup semantic hash mismatch.' }
            $currentSemantic=ConvertTo-StartupDelaySemanticXml $currentXml
            $isBaseline=$currentSemantic -ceq (ConvertTo-StartupDelaySemanticXml $baselineXml)
            $isCandidate=$currentSemantic -ceq (ConvertTo-StartupDelaySemanticXml $candidateXml)
            if ((!$isBaseline -and !$isCandidate) -or ($Mode -eq 'Apply' -and !$isBaseline)) { throw 'Current task has unexpected drift or is not the expected 20-second baseline; no settings changed.' }
            if ($Mode -eq 'Apply' -or ($Mode -eq 'Restore' -and $isCandidate)) {
                $delay=if ($Mode -eq 'Apply') { 'PT15S' } else { 'PT20S' }
                $expectedXml=if ($Mode -eq 'Apply') { $candidateXml } else { $baselineXml }
                $taskMutationAttempted=$false
                try {
                    if ($EnableTaskHistory -and !$historyBefore.enabled) { Set-StartupDelayHistoryState $true }
                    Set-StartupDelayHostBootDelay $delay $currentXml ([ref]$taskMutationAttempted)
                    $finalXml=Get-StartupDelayHostTaskXml
                    Assert-StartupDelayDefinition $finalXml $expectedXml
                    $expectedFinalXml=$expectedXml
                    if ($Mode -eq 'Apply') { $finalHistory=Get-StartupDelayHistoryState }
                } catch {
                    $cause=$_.Exception.Message
                    $rollbackErrors=New-Object 'System.Collections.Generic.List[string]'
                    if ($taskMutationAttempted) { try { Restore-StartupDelayHostXml $baselineXml } catch { $rollbackErrors.Add('task XML restore/verification failed') } }
                    try { Set-StartupDelayHistoryState $historyBefore.enabled } catch { $rollbackErrors.Add('history enabled-state restore failed') }
                    if ($rollbackErrors.Count -gt 0) { throw "Experiment failed: $cause. ROLLBACK INCOMPLETE: $($rollbackErrors -join '; '). Backup: $xmlPath" }
                    $taskResult=if ($taskMutationAttempted) { 'exact baseline task XML restored' } else { 'task was not modified' }
                    throw "Experiment failed; $taskResult; pre-operation history enabled state restored: $cause"
                }
            }
            if ($Mode -in @('Restore','RestoreHistory')) { Set-StartupDelayHistoryState ([bool]$receipt.historyEnabled) }
        }
        if (!$finalXml) { $finalXml=Get-StartupDelayHostTaskXml }
        Assert-StartupDelayDefinition $finalXml $expectedFinalXml
        if (!$finalHistory) { $finalHistory=Get-StartupDelayHistoryState }
        $finalDocument=Read-StartupDelayTaskXml $finalXml
        [pscustomobject]@{schemaVersion=1;mode=$Mode;status='verified';instanceId=$target.instanceId;instanceName=$target.name;deploymentTrack=$target.deploymentTrack;taskName='start_streamer_stack';bootDelay=[string]$finalDocument.Task.Triggers.BootTrigger.Delay;nonDelayDefinitionVerified=$true;backupDirectory=$directory;taskXmlSha256=$receipt.taskXmlSha256;receiptSha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();baselineSemanticSha256=$receipt.baselineSemanticSha256;candidateSemanticSha256=$receipt.candidateSemanticSha256;currentSemanticSha256=Get-StartupDelayTextSha256 (ConvertTo-StartupDelaySemanticXml $finalXml);historyBaselineEnabled=[bool]$receipt.historyEnabled;historyBaselineRecordCount=$receipt.historyRecordCount;historyEnabled=$finalHistory.enabled;historyRecordCount=$finalHistory.recordCount;taskStartedByHelper=$false}
    } finally { if ($lock) { $lock.Dispose() } }
}

if ($FunctionsOnly) { return }
Invoke-DevStartupDelayExperiment -Mode $Mode -ExpectedInstanceId $ExpectedInstanceId -BackupDirectory $BackupDirectory -ExpectedReceiptSha256 $ExpectedReceiptSha256 -EnableTaskHistory ([bool]$EnableTaskHistory) | ConvertTo-Json -Depth 5
