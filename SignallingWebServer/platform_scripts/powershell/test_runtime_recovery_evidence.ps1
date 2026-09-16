$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'runtime_recovery_evidence.psm1') -Force
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $tempRoot ('sw-recovery-' + [guid]::NewGuid().ToString())
$desired = Join-Path $fixture 'desired.json'
$directory = $desired + '.recovery'
[IO.Directory]::CreateDirectory($directory) | Out-Null
try {
    $requestId = [guid]::NewGuid().ToString()
    $context = @{sessionRequestId=$requestId; generation=[guid]::NewGuid().ToString(); updatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); suppressed=$false}
    $context | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'context.json')
    @{managedViewerSessionRequestId=$requestId; commercialRecoveryRequired=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'connect-ticket-runtime-state.json')
    $incident = [guid]::NewGuid().ToString()
    Write-RuntimeRecoveryEvidence -DesiredStatePath $desired -Reason 'unreal_process_missing' -Phase 'detected' -IncidentId $incident
    $notice = Get-Content -LiteralPath (Join-Path $directory 'notice.json') -Raw | ConvertFrom-Json
    if ($notice.metadata.sessionRequestId -ne $requestId -or $notice.metadata.faultKind -ne 'unexpected_exit') { throw 'Missing process must be correlated without claiming a confirmed crash.' }
    $context.sessionRequestId = [guid]::NewGuid().ToString()
    $context | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'context.json')
    Write-RuntimeRecoveryEvidence -DesiredStatePath $desired -Reason 'unreal_process_missing' -Phase 'restart_requested' -IncidentId $incident
    $notice = Get-Content -LiteralPath (Join-Path $directory 'notice.json') -Raw | ConvertFrom-Json
    if ($notice.metadata.sessionRequestId -ne $requestId) { throw 'Recovery phase changed incident ownership.' }
    $before = @(Get-ChildItem -LiteralPath $directory -Filter '*.json').Count
    @{commercialRecoveryRequired=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'connect-ticket-runtime-state.json')
    Write-RuntimeRecoveryEvidence -DesiredStatePath $desired -Reason 'unreal_process_missing' -Phase 'detected' -IncidentId ([guid]::NewGuid().ToString())
    if (@(Get-ChildItem -LiteralPath $directory -Filter '*.json').Count -ne $before) { throw 'Normal teardown was recorded as a fault.' }
    # Execute the watchdog's actual import guard with a missing module. Reporting
    # installation failures must be logged without aborting watchdog startup.
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'watchdog.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $guard = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $node.Extent.Text -match 'Recovery evidence reporting unavailable:'
    }, $false)
    if (-not $guard) { throw 'Watchdog recovery module import is not protected.' }
    $script:reportingWarning = $null
    function Write-WatchdogLog { param($Message, $Level) $script:reportingWarning = $Message }
    & ([scriptblock]::Create('param($PSScriptRoot)' + [Environment]::NewLine + $guard.Extent.Text)) $fixture
    if ($script:reportingWarning -notmatch 'Recovery evidence reporting unavailable:') { throw 'Missing module was not reported.' }
    Write-Output 'Runtime recovery evidence checks passed.'
} finally {
    if (-not [IO.Path]::GetFullPath($fixture).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
