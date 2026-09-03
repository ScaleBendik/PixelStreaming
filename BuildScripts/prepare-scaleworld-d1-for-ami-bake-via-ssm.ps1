[CmdletBinding()]
param(
    [string]$Region = 'eu-north-1',
    [string]$RemoteBakePrepScriptPath = 'C:\PixelStreaming\PixelStreaming\BuildScripts\prepare-for-ami-bake.ps1',
    [int]$PollSeconds = 5,
    [int]$TimeoutMinutes = 30,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$instanceName = 'ScaleWorld_d1'
$expectedDeploymentTrack = 'dev'

function Write-SsmBakeLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "[$timestamp] [$Level] [ssm-bake-prep-d1] $Message"
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

function Resolve-ScaleWorldD1 {
    param([string]$AwsRegion)

    $instances = @(
        Invoke-AwsJson -Arguments @(
            'ec2', 'describe-instances',
            '--region', $AwsRegion,
            '--filters',
            "Name=tag:Name,Values=$instanceName",
            'Name=instance-state-name,Values=running',
            '--query',
            "Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,LaunchTime:LaunchTime,Name:Tags[?Key=='Name']|[0].Value,DeploymentTrack:Tags[?Key=='ScaleWorldDeploymentTrack']|[0].Value}",
            '--output', 'json'
        )
    )

    if ($instances.Count -eq 0) {
        throw "No running EC2 instance named '$instanceName' was found in region '$AwsRegion'."
    }

    if ($instances.Count -gt 1) {
        $summary = ($instances | ForEach-Object {
            "$($_.InstanceId) state=$($_.State) launch=$($_.LaunchTime) track=$($_.DeploymentTrack)"
        }) -join ', '
        throw "Expected exactly one running instance named '$instanceName' in '$AwsRegion', found $($instances.Count): $summary"
    }

    $instance = $instances[0]
    $deploymentTrack = [string]$instance.DeploymentTrack
    if (-not [string]::Equals(
        $deploymentTrack,
        $expectedDeploymentTrack,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing AMI bake preparation for '$instanceName' ($($instance.InstanceId)): expected ScaleWorldDeploymentTrack='$expectedDeploymentTrack', found '$deploymentTrack'."
    }

    return $instance
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

function Get-InstanceState {
    param(
        [string]$InstanceId,
        [string]$AwsRegion
    )

    return Invoke-AwsText -Arguments @(
        'ec2', 'describe-instances',
        '--region', $AwsRegion,
        '--instance-ids', $InstanceId,
        '--query', 'Reservations[0].Instances[0].State.Name',
        '--output', 'text'
    )
}

function New-RemoteBakePrepCommand {
    param(
        [string]$ScriptPath,
        [string]$ExpectedInstanceName
    )

    $scriptLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $ScriptPath
    $instanceNameLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $ExpectedInstanceName

    return @(
        '$ErrorActionPreference = ''Stop'''
        ('$scriptPath = {0}' -f $scriptLiteral)
        ('$expectedInstanceName = {0}' -f $instanceNameLiteral)
        ''
        'if (-not (Test-Path -LiteralPath $scriptPath)) {'
        '    throw "Remote AMI bake-prep script was not found at ''$scriptPath''. Activate a PixelStreaming runtime artifact that includes BuildScripts, or pass -RemoteBakePrepScriptPath."'
        '}'
        ''
        'Write-Host "Running $scriptPath for $expectedInstanceName on $env:COMPUTERNAME..."'
        '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ExpectedInstanceName $expectedInstanceName'
        'if ($LASTEXITCODE -ne 0) {'
        '    throw "Remote AMI bake-prep script exited with code $LASTEXITCODE."'
        '}'
        ''
        '$manifestPath = [Environment]::GetEnvironmentVariable(''SCALEWORLD_RUNTIME_ENTITLEMENT_MANIFEST_PATH'', ''Machine'')'
        'if ([string]::IsNullOrWhiteSpace($manifestPath)) {'
        '    $manifestPath = ''C:\ProgramData\ScaleWorld\runtime-entitlement-manifest.json'''
        '}'
        'Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue'
        '$manifestDirectory = Split-Path -Parent $manifestPath'
        '$manifestFileName = Split-Path -Leaf $manifestPath'
        'if (Test-Path -LiteralPath $manifestDirectory -PathType Container) {'
        '    Get-ChildItem -LiteralPath $manifestDirectory -File -Force -ErrorAction SilentlyContinue |'
        '        Where-Object { $_.Name -like ".$manifestFileName.*.tmp" } |'
        '        Remove-Item -Force -ErrorAction Stop'
        '}'
        'Write-Host "Cleared runtime entitlement projection state at $manifestPath."'
        ''
        '$nvidiaDevices = @('
        '    Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |'
        '        Where-Object {'
        '            ([string]$_.InstanceId).StartsWith(''PCI\VEN_10DE'', [System.StringComparison]::OrdinalIgnoreCase) -and'
        '            [string]::Equals([string]$_.Status, ''OK'', [System.StringComparison]::OrdinalIgnoreCase)'
        '        }'
        ')'
        'if ($nvidiaDevices.Count -eq 0) {'
        '    throw ''No healthy present NVIDIA display device was found. Refusing to bake a GPU image.'''
        '}'
        '$nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue'
        'if (-not $nvidiaSmi) {'
        '    throw ''nvidia-smi.exe was not found. Refusing to bake a GPU image.'''
        '}'
        '$gpuSummary = & $nvidiaSmi.Source ''--query-gpu=name,driver_version'' ''--format=csv,noheader'''
        'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace((($gpuSummary | Out-String).Trim()))) {'
        '    throw "nvidia-smi validation failed with exit code $LASTEXITCODE. Refusing to bake a GPU image."'
        '}'
        'Write-Host "Verified source GPU and NVIDIA driver: $((($gpuSummary | Out-String).Trim()))"'
        ''
        '$edgePackageName = ''Microsoft.MicrosoftEdge.Stable'''
        '$installedEdgePackages = @(Get-AppxPackage -AllUsers -Name $edgePackageName -ErrorAction SilentlyContinue)'
        '$provisionedEdgePackages = @('
        '    Get-AppxProvisionedPackage -Online -ErrorAction Stop |'
        '        Where-Object {'
        '            $_.DisplayName -eq $edgePackageName -or'
        '            $_.PackageName -like "$edgePackageName`_*"'
        '        }'
        ')'
        '$inconsistentEdgePackages = @('
        '    $installedEdgePackages |'
        '        Where-Object {'
        '            $installedFullName = $_.PackageFullName'
        '            -not ($provisionedEdgePackages | Where-Object { $_.PackageName -eq $installedFullName })'
        '        }'
        ')'
        'foreach ($package in $inconsistentEdgePackages) {'
        '    Write-Host "Removing Sysprep-blocking per-user Edge AppX registration $($package.PackageFullName)."'
        '    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop'
        '}'
        'foreach ($package in $provisionedEdgePackages) {'
        '    if ($inconsistentEdgePackages.Count -gt 0) {'
        '        Write-Host "Removing mismatched provisioned Edge AppX package $($package.PackageName)."'
        '        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null'
        '    }'
        '}'
        '$remainingEdgeFullNames = @('
        '    Get-AppxPackage -AllUsers -Name $edgePackageName -ErrorAction SilentlyContinue |'
        '        ForEach-Object { [string]$_.PackageFullName }'
        ')'
        'foreach ($package in $inconsistentEdgePackages) {'
        '    if ($remainingEdgeFullNames -contains [string]$package.PackageFullName) {'
        '        throw "Failed to remove Sysprep-blocking AppX package $($package.PackageFullName)."'
        '    }'
        '}'
        'if ($inconsistentEdgePackages.Count -eq 0) {'
        '    Write-Host ''No inconsistent per-user Microsoft Edge AppX registration was detected.'''
        '}'
        ''
        '$startupTaskName = ''start_streamer_stack'''
        '$startupTask = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction Stop'
        '$startupActionPath = @($startupTask.Actions | ForEach-Object { [string]$_.Execute }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1'
        'if ([string]::IsNullOrWhiteSpace($startupActionPath) -or -not (Test-Path -LiteralPath $startupActionPath -PathType Leaf)) {'
        '    throw "Scheduled task ''$startupTaskName'' does not point at an existing startup action. Refusing to bake an image that cannot start PixelStreaming."'
        '}'
        '$startupPrincipal = New-ScheduledTaskPrincipal -UserId ''SYSTEM'' -LogonType ServiceAccount -RunLevel Highest'
        'Set-ScheduledTask -TaskName $startupTaskName -TaskPath $startupTask.TaskPath -Principal $startupPrincipal -ErrorAction Stop | Out-Null'
        '$updatedStartupTask = Get-ScheduledTask -TaskName $startupTaskName -TaskPath $startupTask.TaskPath -ErrorAction Stop'
        'if (-not [string]::Equals([string]$updatedStartupTask.Principal.UserId, ''SYSTEM'', [System.StringComparison]::OrdinalIgnoreCase) -or'
        '    -not [string]::Equals([string]$updatedStartupTask.Principal.LogonType, ''ServiceAccount'', [System.StringComparison]::OrdinalIgnoreCase)) {'
        '    throw "Scheduled task ''$startupTaskName'' was not rebound to SYSTEM/ServiceAccount."'
        '}'
        'Write-Host "Verified startup task ''$startupTaskName'' runs as SYSTEM/ServiceAccount after Windows generalization."'
        ''
        '$ec2Launch = ''C:\Program Files\Amazon\EC2Launch\EC2Launch.exe'''
        'if (-not (Test-Path -LiteralPath $ec2Launch -PathType Leaf)) {'
        '    throw "EC2Launch v2 was not found at ''$ec2Launch''."'
        '}'
        '$ec2LaunchVersion = & $ec2Launch version'
        'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace((($ec2LaunchVersion | Out-String).Trim()))) {'
        '    throw "EC2Launch v2 version validation failed with exit code $LASTEXITCODE."'
        '}'
        'Write-Host "Verified EC2Launch v2 version $((($ec2LaunchVersion | Out-String).Trim()))."'
        'Write-Host ''SYSPREP_LAUNCHING: EC2Launch v2 will generalize Windows and shut down this instance.'''
        '& $ec2Launch sysprep ''--shutdown=true'''
        'if ($LASTEXITCODE -ne 0) {'
        '    throw "EC2Launch v2 Sysprep failed with exit code $LASTEXITCODE."'
        '}'
    ) -join [Environment]::NewLine
}

function Send-RemoteCommand {
    param(
        [string]$InstanceId,
        [string]$AwsRegion,
        [string]$Command,
        [int]$ExecutionTimeoutSeconds
    )

    $parametersPath = Join-Path $env:TEMP ('scaleworld-d1-bake-prep-ssm-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
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
            '--comment', 'Prepare ScaleWorld_d1 for AMI bake',
            '--parameters', "file://$parametersPath",
            '--query', 'Command.CommandId',
            '--output', 'text'
        )
    } finally {
        Remove-Item -LiteralPath $parametersPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-RemoteSysprepShutdown {
    param(
        [string]$CommandId,
        [string]$InstanceId,
        [string]$AwsRegion,
        [int]$PollIntervalSeconds,
        [int]$TimeoutMinutes
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastCommandStatus = ''
    $lastInstanceState = ''
    $sawCommand = $false
    $lastInvocation = $null
    while ((Get-Date) -lt $deadline) {
        $instanceState = Get-InstanceState -InstanceId $InstanceId -AwsRegion $AwsRegion
        if ($instanceState -ne $lastInstanceState) {
            Write-SsmBakeLog "Source instance state: $instanceState"
            $lastInstanceState = $instanceState
        }

        $invocation = $null
        try {
            $invocation = Invoke-AwsJson -Arguments @(
                'ssm', 'get-command-invocation',
                '--region', $AwsRegion,
                '--command-id', $CommandId,
                '--instance-id', $InstanceId,
                '--output', 'json'
            )
            $sawCommand = $true
            $lastInvocation = $invocation
        } catch {
            Write-SsmBakeLog "Command invocation is not available yet: $($_.Exception.Message)" 'WARN'
        }

        $commandStatus = if ($invocation) { [string]$invocation.Status } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($commandStatus) -and $commandStatus -ne $lastCommandStatus) {
            Write-SsmBakeLog "Remote command status: $commandStatus"
            $lastCommandStatus = $commandStatus
        }

        if ($instanceState -eq 'stopped') {
            if (-not $sawCommand) {
                throw "Source instance stopped before the SSM Sysprep command could be observed."
            }

            if ($lastInvocation -and -not [string]::IsNullOrWhiteSpace([string]$lastInvocation.StandardOutputContent)) {
                Write-Host ''
                Write-Host '--- Remote stdout ---'
                Write-Host ([string]$lastInvocation.StandardOutputContent)
            }

            if ($lastInvocation -and -not [string]::IsNullOrWhiteSpace([string]$lastInvocation.StandardErrorContent)) {
                Write-Host ''
                Write-Host '--- Remote stderr ---'
                Write-Host ([string]$lastInvocation.StandardErrorContent)
            }

            Write-SsmBakeLog 'Source instance is stopped after EC2Launch v2 Sysprep and is ready for AMI capture.'
            return
        }

        if ($instanceState -in @('shutting-down', 'terminated')) {
            throw "Source instance entered unexpected state '$instanceState'; Sysprep must stop, not terminate, the bake source."
        }

        if ($commandStatus -in @('Failed', 'Cancelled', 'TimedOut', 'Undeliverable', 'Terminated') -and
            $instanceState -notin @('stopping', 'stopped')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$invocation.StandardOutputContent)) {
                Write-Host ([string]$invocation.StandardOutputContent)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$invocation.StandardErrorContent)) {
                Write-Host ([string]$invocation.StandardErrorContent)
            }
            throw "Remote AMI bake preparation failed with SSM status '$commandStatus' while the source remained '$instanceState'."
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $TimeoutMinutes minutes waiting for EC2Launch v2 Sysprep to stop '$InstanceId' (last command status='$lastCommandStatus', instance state='$lastInstanceState')."
}

if ($TimeoutMinutes -le 0) {
    throw 'TimeoutMinutes must be greater than zero.'
}

if ($PollSeconds -le 0) {
    throw 'PollSeconds must be greater than zero.'
}

Write-SsmBakeLog "Resolving '$instanceName' in '$Region'."

$instance = Resolve-ScaleWorldD1 -AwsRegion $Region
$instanceId = [string]$instance.InstanceId
Write-SsmBakeLog "Resolved '$instanceName' to '$instanceId' (launch=$($instance.LaunchTime), track=$($instance.DeploymentTrack))."

Assert-SsmOnline -InstanceId $instanceId -AwsRegion $Region
Write-SsmBakeLog "SSM is online for '$instanceId'."

if (-not $Force) {
    Write-Host ''
    Write-Host "This will run AMI bake preparation on $instanceName ($instanceId) in $Region."
    Write-Host "Verified deployment track: $($instance.DeploymentTrack)."
    Write-Host "It expects the remote bake-prep script at $RemoteBakePrepScriptPath."
    Write-Host 'It will stop PixelStreaming, clear transient runtime/update/session state, verify the NVIDIA driver, run EC2Launch v2 Sysprep, and shut down the source instance.'
    Write-Host 'The SSM command is expected to disconnect while Windows generalizes; the workstation waits for EC2 state=stopped.'
    $confirmation = Read-Host 'Type SYSPREP to continue'
    if ($confirmation -ne 'SYSPREP') {
        throw 'Confirmation was not provided; no SSM command was sent.'
    }
}

$remoteCommand = New-RemoteBakePrepCommand -ScriptPath $RemoteBakePrepScriptPath -ExpectedInstanceName $instanceName
$executionTimeoutSeconds = [Math]::Max(60, $TimeoutMinutes * 60)
Write-SsmBakeLog "Sending remote bake-prep command to '$instanceId'."
$commandId = Send-RemoteCommand -InstanceId $instanceId -AwsRegion $Region -Command $remoteCommand -ExecutionTimeoutSeconds $executionTimeoutSeconds

Write-SsmBakeLog "SSM command id: $commandId"
Wait-RemoteSysprepShutdown -CommandId $commandId -InstanceId $instanceId -AwsRegion $Region -PollIntervalSeconds $PollSeconds -TimeoutMinutes $TimeoutMinutes

Write-SsmBakeLog 'Remote AMI bake preparation and EC2Launch v2 Sysprep completed successfully.'
