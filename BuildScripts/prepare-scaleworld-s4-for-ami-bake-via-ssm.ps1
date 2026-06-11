[CmdletBinding()]
param(
    [string]$Region = 'eu-north-1',
    [string]$InstanceName = 'ScaleWorld_s4',
    [string]$RemoteBootstrapRepoPath = 'C:\PixelStreaming\PixelStreaming',
    [string]$RemoteBatchPath = 'C:\PixelStreaming\PixelStreaming\BuildScripts\prepare-scaleworld-s4-for-ami-bake.bat',
    [int]$PollSeconds = 5,
    [int]$TimeoutMinutes = 30,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-SsmBakeLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [ssm-bake-prep] $Message"
}

function Invoke-AwsJson {
    param([string[]]$Arguments)

    $output = & aws @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "aws $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return (($output | Out-String).Trim() | ConvertFrom-Json)
}

function Invoke-AwsText {
    param([string[]]$Arguments)

    $output = & aws @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "aws $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return (($output | Out-String).Trim())
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string]$Value)

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-ScaleWorldInstance {
    param(
        [string]$Name,
        [string]$AwsRegion
    )

    $instances = @(
        Invoke-AwsJson -Arguments @(
            'ec2', 'describe-instances',
            '--region', $AwsRegion,
            '--filters',
            "Name=tag:Name,Values=$Name",
            'Name=instance-state-name,Values=running',
            '--query',
            "Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,LaunchTime:LaunchTime,Name:Tags[?Key=='Name']|[0].Value}",
            '--output', 'json'
        )
    )

    if ($instances.Count -eq 0) {
        throw "No running EC2 instance named '$Name' was found in region '$AwsRegion'."
    }

    if ($instances.Count -gt 1) {
        $summary = ($instances | ForEach-Object { "$($_.InstanceId) state=$($_.State) launch=$($_.LaunchTime)" }) -join ', '
        throw "Expected exactly one running instance named '$Name' in '$AwsRegion', found $($instances.Count): $summary"
    }

    return $instances[0]
}

function Assert-SsmOnline {
    param(
        [string]$InstanceId,
        [string]$AwsRegion
    )

    $status = Invoke-AwsText -Arguments @(
        'ssm', 'describe-instance-information',
        '--region', $AwsRegion,
        '--filters', "Key=InstanceIds,Values=$InstanceId",
        '--query', 'InstanceInformationList[0].PingStatus',
        '--output', 'text'
    )

    if ($status -ne 'Online') {
        throw "SSM is not online for instance '$InstanceId' in '$AwsRegion' (PingStatus=$status)."
    }
}

function New-RemoteBakePrepCommand {
    param(
        [string]$BootstrapRepoPath,
        [string]$BatchPath
    )

    $repoLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $BootstrapRepoPath
    $batchLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $BatchPath

    return @"
`$ErrorActionPreference = 'Stop'
`$repoPath = $repoLiteral
`$batchPath = $batchLiteral

if (-not (Test-Path -LiteralPath `$batchPath)) {
    throw "Remote AMI bake-prep batch was not found at '`$batchPath'. Artifact-mode bake prep no longer mutates '`$repoPath' with git. Activate a PixelStreaming runtime artifact that includes BuildScripts, or pass -RemoteBatchPath to the installed bake-prep batch."
}

Write-Host "Running `$batchPath on `$env:COMPUTERNAME..."
& `$batchPath
if (`$LASTEXITCODE -ne 0) {
    throw "Remote AMI bake-prep batch exited with code `$LASTEXITCODE."
}
"@
}

function Send-RemoteCommand {
    param(
        [string]$InstanceId,
        [string]$AwsRegion,
        [string]$Command,
        [int]$ExecutionTimeoutSeconds
    )

    $parametersPath = Join-Path $env:TEMP ('scaleworld-s4-bake-prep-ssm-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
    $parameters = [ordered]@{
        commands = @($Command)
        executionTimeout = @([string]$ExecutionTimeoutSeconds)
    }

    try {
        $parameters | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $parametersPath -Encoding ASCII
        return Invoke-AwsText -Arguments @(
            'ssm', 'send-command',
            '--region', $AwsRegion,
            '--instance-ids', $InstanceId,
            '--document-name', 'AWS-RunPowerShellScript',
            '--comment', 'Prepare ScaleWorld_s4 for AMI bake',
            '--parameters', "file://$parametersPath",
            '--query', 'Command.CommandId',
            '--output', 'text'
        )
    } finally {
        Remove-Item -LiteralPath $parametersPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-RemoteCommand {
    param(
        [string]$CommandId,
        [string]$InstanceId,
        [string]$AwsRegion,
        [int]$PollIntervalSeconds,
        [int]$TimeoutMinutes
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastStatus = ''
    while ((Get-Date) -lt $deadline) {
        $invocation = $null
        try {
            $invocation = Invoke-AwsJson -Arguments @(
                'ssm', 'get-command-invocation',
                '--region', $AwsRegion,
                '--command-id', $CommandId,
                '--instance-id', $InstanceId,
                '--output', 'json'
            )
        } catch {
            Write-SsmBakeLog "Command invocation is not available yet: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }

        $status = [string]$invocation.Status
        if ($status -ne $lastStatus) {
            Write-SsmBakeLog "Remote command status: $status"
            $lastStatus = $status
        }

        if ($status -in @('Success', 'Failed', 'Cancelled', 'TimedOut', 'Undeliverable', 'Terminated')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$invocation.StandardOutputContent)) {
                Write-Host ''
                Write-Host '--- Remote stdout ---'
                Write-Host ([string]$invocation.StandardOutputContent)
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$invocation.StandardErrorContent)) {
                Write-Host ''
                Write-Host '--- Remote stderr ---'
                Write-Host ([string]$invocation.StandardErrorContent)
            }

            if ($status -ne 'Success') {
                throw "Remote AMI bake preparation failed with SSM status '$status'."
            }

            return
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $TimeoutMinutes minutes waiting for SSM command '$CommandId'."
}

if ($TimeoutMinutes -le 0) {
    throw 'TimeoutMinutes must be greater than zero.'
}

if ($PollSeconds -le 0) {
    throw 'PollSeconds must be greater than zero.'
}

Write-SsmBakeLog "Resolving '$InstanceName' in '$Region'."

$instance = Resolve-ScaleWorldInstance -Name $InstanceName -AwsRegion $Region
$instanceId = [string]$instance.InstanceId
Write-SsmBakeLog "Resolved '$InstanceName' to '$instanceId' (launch=$($instance.LaunchTime))."

Assert-SsmOnline -InstanceId $instanceId -AwsRegion $Region
Write-SsmBakeLog "SSM is online for '$instanceId'."

if (-not $Force) {
    Write-Host ''
    Write-Host "This will run AMI bake preparation on $InstanceName ($instanceId) in $Region."
    Write-Host "It expects the remote launch root at $RemoteBootstrapRepoPath to already contain the bake-prep batch."
    Write-Host 'It will stop PixelStreaming stack processes and clear transient runtime/update/session-artifact state on the remote instance.'
    $confirmation = Read-Host 'Type PREPARE to continue'
    if ($confirmation -ne 'PREPARE') {
        throw 'Confirmation was not provided; no SSM command was sent.'
    }
}

$remoteCommand = New-RemoteBakePrepCommand `
    -BootstrapRepoPath $RemoteBootstrapRepoPath `
    -BatchPath $RemoteBatchPath
$executionTimeoutSeconds = [Math]::Max(60, $TimeoutMinutes * 60)
Write-SsmBakeLog "Sending remote bake-prep command to '$instanceId'."
$commandId = Send-RemoteCommand `
    -InstanceId $instanceId `
    -AwsRegion $Region `
    -Command $remoteCommand `
    -ExecutionTimeoutSeconds $executionTimeoutSeconds

Write-SsmBakeLog "SSM command id: $commandId"
Wait-RemoteCommand `
    -CommandId $commandId `
    -InstanceId $instanceId `
    -AwsRegion $Region `
    -PollIntervalSeconds $PollSeconds `
    -TimeoutMinutes $TimeoutMinutes

Write-SsmBakeLog 'Remote AMI bake preparation completed successfully.'
