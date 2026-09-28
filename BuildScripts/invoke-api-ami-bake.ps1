[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Launch', 'Run')][string]$Mode = 'Launch',
    [Parameter(Mandatory = $true)][string]$RequestBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runnerPath = $PSCommandPath
$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RequestBase64)) | ConvertFrom-Json
$jobId = ([Guid]$request.jobId).ToString('N')
if ($jobId -eq [Guid]::Empty.ToString('N')) { throw 'A job ID is required.' }
$cleanupPath = Join-Path $PSScriptRoot 'prepare-for-ami-bake.ps1'
foreach ($entry in @(@($runnerPath, $request.prepScriptSha256), @($cleanupPath, $request.cleanupScriptSha256))) {
    if ([string]$entry[1] -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash -ne [string]$entry[1]) {
        throw 'The installed bake scripts do not match this job.'
    }
}
$taskName = "ScaleWorld-AmiBake-$jobId"
$journalRoot = 'C:\ProgramData\ScaleWorld\ami-bake'
New-Item -ItemType Directory -Path $journalRoot -Force | Out-Null
$markerPath = Join-Path $journalRoot "$jobId.started"
$receiptPath = Join-Path $journalRoot "$jobId.receipt.json"

if ($Mode -eq 'Launch') {
    # Duplicate SSM delivery is safe, including a lost SendCommand response. Never
    # re-run a previously started job, even when its task ended or Windows rebooted.
    if (Test-Path -LiteralPath $markerPath) { Write-Output "Bake $jobId already started; inspect its receipt."; return }
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`" -Mode Run -RequestBase64 $RequestBase64"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    }
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Output "Bake $jobId launched as SYSTEM. Completion is recorded in S3."
    return
}

$mutex = New-Object Threading.Mutex($false, 'Global\ScaleWorldAmiBake')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another bake runner owns this instance.' }
    if (Test-Path -LiteralPath $markerPath) { return }
    $stream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    . $cleanupPath -FunctionsOnly
    $awsCli = Get-AwsCliPath
    $identity = Get-InstanceIdentityDocument
    if ($identity.instanceId -ne $request.instanceId -or $identity.region -ne $request.region) {
        throw 'Bake request does not target this instance and region.'
    }
    $root = 'C:\PixelStreaming\PixelStreaming'
    $metadata = Get-RuntimeBundleMetadata -RuntimeRoot $root
    $release = Get-Content -LiteralPath 'C:\PixelStreaming\state\current-release.json' -Raw | ConvertFrom-Json
    $actualBuild = [IO.Path]::GetFileName([string]$release.ZipKey) -replace '(?i)\.zip$', ''
    $expectedBuild = [IO.Path]::GetFileName([string]$request.unrealBuildId) -replace '(?i)\.zip$', ''
    if ($metadata.bundleId -ne $request.runtimeBundleId -or $actualBuild -ne $expectedBuild) {
        throw 'Installed runtime/Unreal identity differs from the frozen candidate.'
    }

    function Write-Receipt {
        param([string]$Phase, [string]$ImageState = '', [string]$Failure = '')
        $receipt = [ordered]@{
            version = 1; jobId = [string]$request.jobId; instanceId = [string]$request.instanceId
            phase = $Phase; runtimeBundleId = [string]$request.runtimeBundleId; unrealBuildId = [string]$request.unrealBuildId
            prepScriptSha256 = [string]$request.prepScriptSha256; cleanupScriptSha256 = [string]$request.cleanupScriptSha256
            completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); sysprepState = $ImageState; error = $Failure
        }
        [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        & $awsCli s3api put-object --region $request.region --bucket $request.evidenceBucket --key $request.evidenceKey --body $receiptPath --content-type application/json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not persist the bake receipt to S3. Source will remain held.' }
    }

    # Verify receipt storage before touching runtime or Windows state.
    Write-Receipt -Phase 'preflight'
    Test-RuntimeLaunchRoot -RuntimeRoot $root -RuntimeMetadata $metadata
    Import-Module (Join-Path $root 'SignallingWebServer\platform_scripts\powershell\unreal_prerequisite.psm1') -Force
    Assert-ScaleWorldUnrealPrerequisite -UnrealRoot 'C:\PixelStreaming\WindowsNoEditor' | Out-Null
    Test-SourceGpuAndDriver
    $ec2Launch = Test-Ec2LaunchV2
    Set-StreamerStartupTaskPrincipalForImage
    Repair-SysprepBlockingEdgeAppx
    Stop-StreamerStackProcesses
    # Unlike the legacy interactive summary, API preparation fails on survivors.
    $remaining = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and ($_.Name -like 'ScaleWorld*.exe' -or
        ($_.Name -eq 'node.exe' -and $_.CommandLine -like '*SignallingWebServer*') -or
        ($_.Name -eq 'cmd.exe' -and ($_.CommandLine -like '*start_dev_turn.bat*' -or
            $_.CommandLine -like '*start_watchdog.bat*' -or $_.CommandLine -like '*start_streamer_stack.bat*' -or
            $_.CommandLine -like '*start_unreal.bat*')) -or
        ($_.Name -eq 'powershell.exe' -and ($_.CommandLine -like '*watchdog.ps1*' -or
            $_.CommandLine -like '*start_scaleworld.ps1*' -or $_.CommandLine -like '*start_watchdog.bat*' -or
            $_.CommandLine -like '*invoke_update_mode.ps1*' -or $_.CommandLine -like '*invoke_provisioning_mode.ps1*')))
    })
    if ($remaining.Count -gt 0) { throw 'Runtime processes survived bake cleanup.' }
    Clear-TransientBakeState -InstallRoot 'C:\PixelStreaming' -BootstrapRoot $root -RuntimeRoot $root
    Reset-InstanceAgentDesiredStateForBake -InstallRoot 'C:\PixelStreaming'
    Clear-BakeCaches -InstallRoot 'C:\PixelStreaming'
    Write-Receipt -Phase 'generalizing'
    # EC2Launch handles AWS-specific generalization. Suppress its shutdown so we
    # can verify Windows state and durably export evidence before powering off.
    Complete-VerifiedAmiGeneralization -Generalize {
        & $ec2Launch sysprep '--shutdown=false'
        if ($LASTEXITCODE -ne 0) { throw "EC2Launch Sysprep failed with exit code $LASTEXITCODE." }
    } -ReadImageState {
        [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState).ImageState
    } -SysprepIsRunning {
        [bool](Get-Process sysprep -ErrorAction SilentlyContinue)
    } -PublishReceipt {
        param($imageState)
        Write-Receipt -Phase 'generalized' -ImageState $imageState
    } -Shutdown {
        & shutdown.exe /s /t 5 /d p:4:1 /c "ScaleWorld AMI bake $jobId"
        if ($LASTEXITCODE -ne 0) { throw 'Windows shutdown request failed.' }
    }
} catch {
    $failure = $_.Exception.Message
    if (Get-Command Write-Receipt -ErrorAction SilentlyContinue) {
        try { Write-Receipt -Phase 'failed' -Failure $failure } catch { Write-Error "Receipt upload failed: $($_.Exception.Message)" -ErrorAction Continue }
    }
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
