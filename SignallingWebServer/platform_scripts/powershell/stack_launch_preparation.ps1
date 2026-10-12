# Optional launch-local preparation evidence. Hashes contain no secret values;
# this receipt never grants spawn, replacement proof, Ready or admission.
function Get-StackLaunchPreparationEnvironmentHash {
    $inputs = [ordered]@{}
    foreach ($name in @(
        'SCALEWORLD_STREAMING_LANE','SCALEWORLD_DEPLOYMENT_TRACK','SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE',
        'SCALEWORLD_AWS_REGION','AWS_REGION','AWS_DEFAULT_REGION','REGION','INSTANCE_ID',
        'INSTANCE_AGENT_INSTANCE_ID','INSTANCE_AGENT_API_BASE_URL','INSTANCE_AGENT_CONTROL_PLANE_ENV',
        'INSTANCE_AGENT_ROUTE_KEY','INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET','INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM',
        'INSTANCE_AGENT_ARTIFACT_BUCKET','INSTANCE_AGENT_ARTIFACT_BUCKET_PARAM',
        'TURN_USERNAME','TURN_CREDENTIAL','TURN_USER_PARAM','TURN_CREDENTIAL_PARAM',
        'CONNECT_TICKET_AUTH_MODE','CONNECT_TICKET_SIGNING_KEY','CONNECT_TICKET_SIGNING_KEY_PARAM'
    )) { $inputs[$name] = [Environment]::GetEnvironmentVariable($name) }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($inputs | ConvertTo-Json -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); [Array]::Clear($bytes,0,$bytes.Length) }
}

function Get-StackLaunchPreparationFiles {
    param($Scope)
    @(@(
        (Join-Path (Split-Path -Parent $Scope.RepoRoot) 'runtime-bundle-metadata.json'),
        [string]$env:SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT,
        [string]$env:CURRENT_RELEASE_STATE_PATH
    ) | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { throw 'A preparation input path is missing.' }
        $path = Get-StackLaunchCanonicalPath $_
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A preparation input file is missing.' }
        [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
    })
}

function New-StackLaunchPreparationReceipt {
    param($Scope,$Lease,$NodeIdentity)
    try {
        if ($env:SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED -ceq 'false' -or
            $env:SCALEWORLD_STACK_PREPARATION_COMPLETE -cne 'true' -or
            $env:SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED -ceq 'true' -or
            $env:STACK_MODE -cne 'normal' -or
            $env:SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE -cne 'runtime_artifact' -or
            $env:SCALEWORLD_STACK_RUNTIME_IDENTITY_PUBLISHED -cne 'true' -or
            $null -eq $Lease -or $Lease.phase -cne 'starting' -or
            -not (Test-StackLaunchIdentityEqual $Lease.activeNode $NodeIdentity)) { return $null }
        if ($env:SCALEWORLD_STREAMING_LANE -cnotin @('nonprod','prod') -or
            $env:SCALEWORLD_DEPLOYMENT_TRACK -cnotin @('dev','stage','prod') -or
            $env:INSTANCE_ID -cnotmatch '^i-[0-9a-f]{8,17}$' -or
            [string]::IsNullOrWhiteSpace($env:TURN_USERNAME) -or
            [string]::IsNullOrWhiteSpace($env:TURN_CREDENTIAL) -or
            ($env:CONNECT_TICKET_AUTH_MODE -cne 'off' -and [string]::IsNullOrWhiteSpace($env:CONNECT_TICKET_SIGNING_KEY))) { return $null }
        $boot = Get-StackLaunchOsBootUtc
        if ([DateTimeOffset]::Parse([string]$Lease.owner.creationUtc) -lt [DateTimeOffset]::Parse($boot)) { return $null }
        [pscustomobject]@{
            schemaVersion=1;generationId=$Lease.generationId;repoRoot=$Scope.RepoRoot
            nodeIdentity=$NodeIdentity;bootUtc=$boot;createdUtc=[DateTimeOffset]::UtcNow.ToString('o')
            environmentSha256=(Get-StackLaunchPreparationEnvironmentHash)
            files=@(Get-StackLaunchPreparationFiles $Scope)
        }
    } catch { return $null }
}

function Test-StackLaunchPreparationInputs {
    param($Scope,$Receipt,[int]$MaximumAgeSeconds=90)
    try {
        if ($null -eq $Receipt -or [int]$Receipt.schemaVersion -ne 1 -or
            [string]$Receipt.repoRoot -ine $Scope.RepoRoot -or
            [string]$Receipt.bootUtc -cne (Get-StackLaunchOsBootUtc) -or
            [string]$Receipt.environmentSha256 -cne (Get-StackLaunchPreparationEnvironmentHash)) { return $false }
        $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$Receipt.createdUtc)).TotalSeconds
        if ($age -lt 0 -or $age -gt $MaximumAgeSeconds) { return $false }
        $actual = @(Get-StackLaunchPreparationFiles $Scope); $expected = @($Receipt.files)
        if ($expected.Count -ne $actual.Count) { return $false }
        for ($i=0; $i -lt $actual.Count; $i++) {
            if ([string]$expected[$i].path -ine $actual[$i].path -or
                [string]$expected[$i].sha256 -cne $actual[$i].sha256) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-StackLaunchRecoveryPreparation {
    param($Scope,$SourceLease,$SourceIdentity,$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    try {
        if ($env:SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED -ceq 'false' -or
            $null -eq $SourceLease -or $SourceLease.phase -cne 'starting' -or
            $null -eq $SourceIdentity -or
            -not (Test-StackLaunchIdentityEqual $SourceLease.activeNode $SourceIdentity) -or
            $null -eq $SourceLease.PSObject.Properties['preparation']) { return $null }
        $receipt = $SourceLease.preparation
        if ([string]$receipt.generationId -cne $SourceLease.generationId -or
            -not (Test-StackLaunchIdentityEqual $receipt.nodeIdentity $SourceIdentity) -or
            -not (Test-StackLaunchProcessIdentity $SourceIdentity) -or
            -not (Test-StackLaunchPreparationInputs $Scope $receipt)) { return $null }
        return $receipt
    } catch { return $null }
}

function Test-StackLaunchReplacementPreparation {
    param($Scope,$Lease,$OwnerIdentity,$LockHandle)
    Assert-StackLaunchLeaseLock $Scope $LockHandle
    try {
        if ($env:SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED -ceq 'false' -or
            $null -eq $Lease -or $Lease.phase -cne 'starting' -or
            $null -eq $Lease.PSObject.Properties['recoveryPreparation'] -or
            -not (Test-StackLaunchIdentityEqual $Lease.owner $OwnerIdentity)) { return $false }
        $handoff = $Lease.recoveryPreparation; $monitor = Get-StackLaunchLeaseMonitor $Lease
        if ($null -eq $monitor -or
            [string]$handoff.generationId -cne $Lease.generationId -or
            [string]$handoff.recycleId -cne $monitor.recycleId -or
            [string]$handoff.helperLaunchId -cne $monitor.helperLaunchId -or
            -not (Test-StackLaunchProcessIdentity $Lease.recycler) -or
            -not (Test-StackLaunchProcessIdentity $monitor.identity)) { return $false }
        return Test-StackLaunchPreparationInputs $Scope $handoff.receipt
    } catch { return $false }
}
