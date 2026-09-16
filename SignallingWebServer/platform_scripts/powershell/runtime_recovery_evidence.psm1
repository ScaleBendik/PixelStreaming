$ErrorActionPreference = 'Stop'
$script:IncidentId = $null
$script:IncidentContext = $null

function Write-RecoveryJson {
    param([string]$Path, $Value)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString() + '.pending'
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 8 -Compress))
    $file = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    if ([IO.File]::Exists($Path)) {
        $backup = $Path + '.backup'
        [IO.File]::Replace($temporary, $Path, $backup)
        [IO.File]::Delete($backup)
    }
    else { [IO.File]::Move($temporary, $Path) }
}

function Write-RuntimeRecoveryEvidence {
    param([string]$DesiredStatePath, [string]$Reason, [string]$Phase, [string]$IncidentId, [switch]$Suppressed)
    if ($Suppressed -or $Reason -notmatch 'unreal_process_missing|streamer_') { return }
    $directory = $DesiredStatePath + '.recovery'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    if ($script:IncidentId -ne $IncidentId) {
        $context = $null
        try { $context = Get-Content -LiteralPath (Join-Path $directory 'context.json') -Raw | ConvertFrom-Json } catch {}
        $requestId = ''
        $generation = ''
        if ($context) {
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($context.updatedAtUtc)).TotalSeconds
            if ($age -ge 0 -and $age -le 30 -and -not $context.suppressed) {
                $requestId = [string]$context.sessionRequestId
                $generation = [string]$context.generation
            }
            if ($context.suppressed) { return }
        }
        # Check the immediate teardown fence too: context can lag a normal stop.
        try {
            $gatePath = Join-Path (Split-Path -Parent $DesiredStatePath) 'connect-ticket-runtime-state.json'
            $gate = Get-Content -LiteralPath $gatePath -Raw | ConvertFrom-Json
            if ($gate.commercialRecoveryRequired) { return }
            if ($gate.managedViewerSessionRequestId -ne $requestId) { $requestId = '' }
        } catch { $requestId = '' }
        $script:IncidentContext = @{ sessionRequestId = $requestId; runtimeGeneration = $generation }
        $script:IncidentId = $IncidentId
    }
    $evidenceId = [guid]::NewGuid().ToString()
    $event = @{
        eventType = 'runtime_fault'
        occurredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        metadata = @{
            runtimeFaultEvidenceVersion = '1'; evidenceId = $evidenceId; incidentId = $IncidentId
            sessionRequestId = $script:IncidentContext.sessionRequestId
            runtimeGeneration = $script:IncidentContext.runtimeGeneration
            source = 'watchdog'; reason = $Reason; phase = $Phase
            faultKind = $(if ($Reason -match 'unreal_process_missing') { 'unexpected_exit' } else { 'unresponsive' })
        }
    }
    # Commit before status publication or destructive recovery. These files have one writer.
    Write-RecoveryJson -Path (Join-Path $directory ($evidenceId + '.json')) -Value $event
    Write-RecoveryJson -Path (Join-Path $directory 'notice.json') -Value $event
}

Export-ModuleMember -Function Write-RuntimeRecoveryEvidence
