[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_preparation.ps1')
$script:Assertions=0
$script:BootUtc=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
$script:DeadPids=@{}
function Get-StackLaunchOsBootUtc { return $script:BootUtc }
function Test-StackLaunchProcessIdentity { param($Identity) return $null -ne $Identity -and -not $script:DeadPids.ContainsKey([int]$Identity.pid) }
function Assert-True { param([bool]$Value,[string]$Message) $script:Assertions++;if(-not $Value){throw $Message} }
function Clone-Fixture { param($Value) return ($Value|ConvertTo-Json -Depth 9 -Compress|ConvertFrom-Json) }
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp=Join-Path $tempBase ('scaleworld-preparation-'+[Guid]::NewGuid().ToString('N'))
$saved=@{}
$lock=$null
try {
    $repo=Join-Path $temp 'runtime\SignallingWebServer'
    [void](New-Item -ItemType Directory -Path $repo -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $temp 'install') -Force)
    $scope=Get-StackLaunchLeaseScope $repo (Join-Path $temp 'install')
    $files=@((Join-Path (Split-Path -Parent $repo) 'runtime-bundle-metadata.json'),(Join-Path $temp 'config.json'),(Join-Path $temp 'build.json'))
    foreach($file in $files){[IO.File]::WriteAllText($file,'fixture-v1')}
    $values=@{
        SCALEWORLD_STACK_PREPARATION_COMPLETE='true';SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED='false'
        STACK_MODE='normal';SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE='runtime_artifact'
        SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED='true'
        SCALEWORLD_STACK_RUNTIME_IDENTITY_PUBLISHED='true';SCALEWORLD_STREAMING_LANE='nonprod'
        SCALEWORLD_DEPLOYMENT_TRACK='dev';INSTANCE_ID='i-0123456789abcdef0'
        TURN_USERNAME='fixture-user';TURN_CREDENTIAL='fixture-secret';CONNECT_TICKET_AUTH_MODE='required'
        CONNECT_TICKET_SIGNING_KEY='fixture-signing-key';SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT=$files[1]
        CURRENT_RELEASE_STATE_PATH=$files[2]
    }
    foreach($key in $values.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$values[$key])}
    $generation=[Guid]::NewGuid().ToString('D')
    $owner=[pscustomobject]@{pid=4101;name='cmd.exe';creationUtc=[DateTimeOffset]::UtcNow.AddSeconds(-45).ToString('o');executablePath='C:\Windows\System32\cmd.exe'}
    $node=[pscustomobject]@{pid=4102;name='node.exe';creationUtc=[DateTimeOffset]::UtcNow.AddSeconds(-3).ToString('o');executablePath=$scope.NodePath}
    $source=[pscustomobject]@{phase='starting';generationId=$generation;owner=$owner;activeNode=$node}
    $lock=Enter-StackLaunchLeaseLock $scope
    $receipt=New-StackLaunchPreparationReceipt $scope $source $node
    Assert-True ($null -ne $receipt) 'Fresh artifact launch must capture preparation.'
    $env:SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED='false'
    Assert-True ($null -eq (New-StackLaunchPreparationReceipt $scope $source $node)) 'Disabled optimization must follow the original preparation path.'
    $env:SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED='true'
    Assert-True (Test-StackLaunchPreparationInputs $scope $receipt) 'Fresh matching inputs must validate.'
    $source|Add-Member -NotePropertyName preparation -NotePropertyValue $receipt
    Assert-True ($null -ne (Get-StackLaunchRecoveryPreparation $scope $source $node $lock)) 'Exact current source must offer preparation.'
    $serialized=$receipt|ConvertTo-Json -Depth 8
    Assert-True (-not $serialized.Contains('fixture-secret') -and -not $serialized.Contains('fixture-signing-key')) 'Receipt must not serialize secrets.'
    $env:TURN_CREDENTIAL='rotated-fixture-secret'
    Assert-True (-not(Test-StackLaunchPreparationInputs $scope $receipt)) 'Changed credential must reject reuse.'
    $env:TURN_CREDENTIAL=$values.TURN_CREDENTIAL
    $source.phase='completed'
    Assert-True ($null -eq (Get-StackLaunchRecoveryPreparation $scope $source $node $lock)) 'Later recycles must prepare normally.'
    $source.phase='starting'
    $script:DeadPids[$node.pid]=$true
    Assert-True ($null -eq (Get-StackLaunchRecoveryPreparation $scope $source $node $lock)) 'Dead source must not offer preparation.'
    $script:DeadPids.Clear()
    $wrongNode=Clone-Fixture $node;$wrongNode.creationUtc=[DateTimeOffset]::UtcNow.ToString('o')
    Assert-True ($null -eq (Get-StackLaunchRecoveryPreparation $scope $source $wrongNode $lock)) 'Reused PID with another birth must reject preparation.'
    foreach($index in 0,1,2){
        [IO.File]::WriteAllText($files[$index],'changed-v2')
        Assert-True (-not(Test-StackLaunchPreparationInputs $scope $receipt)) ('Changed input '+$index+' must reject reuse.')
        [IO.File]::WriteAllText($files[$index],'fixture-v1')
    }
    $old=Clone-Fixture $receipt;$old.createdUtc=[DateTimeOffset]::UtcNow.AddSeconds(-91).ToString('o')
    Assert-True (-not(Test-StackLaunchPreparationInputs $scope $old)) 'Expired preparation must reject reuse.'
    $future=Clone-Fixture $receipt;$future.createdUtc=[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')
    Assert-True (-not(Test-StackLaunchPreparationInputs $scope $future)) 'Clock rollback must reject reuse.'
    $originalBoot=$script:BootUtc;$script:BootUtc=[DateTimeOffset]::UtcNow.ToString('o')
    Assert-True (-not(Test-StackLaunchPreparationInputs $scope $receipt)) 'Another boot must reject reuse.'
    $script:BootUtc=$originalBoot
    $oldGeneration=Clone-Fixture $source;$oldGeneration.generationId=[Guid]::NewGuid().ToString('D')
    Assert-True ($null -eq (Get-StackLaunchRecoveryPreparation $scope $oldGeneration $node $lock)) 'Another source generation must reject reuse.'
    $replacementId=[Guid]::NewGuid().ToString('D')
    $monitor=[pscustomobject]@{identity=[pscustomobject]@{pid=4103};recycleId='fixture-operation';helperLaunchId='fixture-dispatch'}
    $replacement=[pscustomobject]@{phase='starting';generationId=$replacementId;owner=$owner;recycler=[pscustomobject]@{pid=4104};monitor=$monitor;recoveryPreparation=[pscustomobject]@{generationId=$replacementId;recycleId=$monitor.recycleId;helperLaunchId=$monitor.helperLaunchId;receipt=$receipt}}
    Assert-True (Test-StackLaunchReplacementPreparation $scope $replacement $owner $lock) 'Exact reserved operation and live monitor must permit reuse.'
    foreach($field in @('generationId','recycleId','helperLaunchId')){
        $changed=Clone-Fixture $replacement;$changed.recoveryPreparation.$field='another-operation'
        Assert-True (-not(Test-StackLaunchReplacementPreparation $scope $changed $owner $lock)) ('Changed '+$field+' must reject reuse.')
    }
    $script:DeadPids[$monitor.identity.pid]=$true
    Assert-True (-not(Test-StackLaunchReplacementPreparation $scope $replacement $owner $lock)) 'A lost monitor must reject reuse.'
    $script:DeadPids.Clear()
    $malformed=Clone-Fixture $replacement;$malformed.recoveryPreparation=[pscustomobject]@{schemaVersion=999}
    Assert-True (-not(Test-StackLaunchReplacementPreparation $scope $malformed $owner $lock)) 'Malformed optional receipt must use full preparation.'
    $env:SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED='true'
    Assert-True ($null -eq (New-StackLaunchPreparationReceipt $scope $source $node)) 'A replacement must not propagate another preparation fast path.'
    Write-Output ("Preparation reuse guards passed: "+$script:Assertions+" assertions.")
} finally {
    if($null -ne $lock){Exit-StackLaunchLeaseLock $lock}
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^scaleworld-preparation-[0-9a-f]{32}$'){throw 'Fixture cleanup escaped its temporary directory.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
