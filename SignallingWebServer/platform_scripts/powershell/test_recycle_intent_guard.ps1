[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'recycle_intent_guard.ps1')
$guardSourceParams = @{
    ExpectedLaunchGenerationId = '33333333-3333-4333-8333-333333333333'
    ExpectedSourceCreationUtc = '2026-10-12T09:59:00.1234560Z'
}

function Assert-GuardCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-GuardRejects {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-GuardCondition $rejected $Message
}

function New-GuardMarker {
    return [ordered]@{
        schemaVersion = 2
        phase = 'intent'
        requestedAtUtc = '2026-10-12T10:00:00.000Z'
        reason = 'post_session_cleanup'
        recycleId = 'original-operation'
        sourcePid = 1234
        helperLaunchId = '11111111-1111-4111-8111-111111111111'
        sourceLaunchGenerationId = $guardSourceParams.ExpectedLaunchGenerationId
        sourceCreationUtc = $guardSourceParams.ExpectedSourceCreationUtc
        recycleRequestedToken = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        sessionRequestId = 'original-request'
        userSessionId = 'original-user-session'
        sessionId = 'original-session'
    }
}

function Write-GuardMarker {
    param([object]$Marker)
    [System.IO.File]::WriteAllText(
        $script:GuardMarkerPath,
        ($Marker | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-GuardFixture {
    return Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath `
        -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 1234 `
        -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams
}

$testParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $testParent ('ScaleWorldRecycleIntentTest-' + [Guid]::NewGuid().ToString('N'))
$script:GuardMarkerPath = Join-Path $testRoot 'instance-agent-recycle-marker.json'
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    foreach ($schema in @(1, 2)) {
        $marker = New-GuardMarker
        $marker.schemaVersion = $schema
        Write-GuardMarker $marker
        $originalBytes = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:GuardMarkerPath))
        $intent = Read-GuardFixture
        Assert-GuardCondition ($intent.Marker.schemaVersion -eq $schema) 'Accepted schema must remain unchanged.'
        Assert-GuardCondition ($intent.Marker.recycleRequestedToken -ceq $marker.recycleRequestedToken) 'Captured token provenance must remain unchanged.'
        Assert-GuardCondition ($intent.Marker.sessionRequestId -ceq $marker.sessionRequestId) 'Captured request provenance must remain unchanged.'
        Assert-GuardCondition ($intent.Marker.userSessionId -ceq $marker.userSessionId) 'Captured user-session provenance must remain unchanged.'
        Assert-GuardCondition ($intent.Marker.sessionId -ceq $marker.sessionId) 'Captured session provenance must remain unchanged.'
        $currentMarker = Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent
        Assert-GuardCondition ($currentMarker.sourcePid -eq 1234) 'Unchanged intent must return its fresh marker.'
        Assert-GuardCondition (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:GuardMarkerPath))) -ceq $originalBytes) 'Capture/recheck must never rewrite the marker.'
    }
    Write-Host 'Passed: schema 1/2 capture and unchanged recheck preserve every marker field without writes.'

    $marker = New-GuardMarker
    $marker.Remove('recycleRequestedToken')
    $marker.Remove('sessionRequestId')
    $marker.Remove('userSessionId')
    $marker.Remove('sessionId')
    Write-GuardMarker $marker
    $null = Read-GuardFixture
    Write-Host 'Passed: passive/tokenless intent does not require or infer optional provenance.'

    $opaqueId = 'operation & "quoted" | < > ^ %PATH% ! (' + [char]0x03bb + [char]0x00f8 + ')'
    $marker = New-GuardMarker
    $marker.recycleId = $opaqueId
    Write-GuardMarker $marker
    $intent = Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId $opaqueId -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams
    Assert-GuardCondition ($intent.Marker.recycleId -ceq $opaqueId) 'Opaque operation identity must remain byte-for-byte unchanged.'
    $null = Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent
    Write-Host 'Passed: Unicode and command metacharacters remain opaque identity inside the read-only guard.'

    Write-GuardMarker (New-GuardMarker)
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams } 'Legacy invocation without an expected operation must reject.'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'new-operation' -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams } 'A stale helper must reject a different operation.'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'Original-operation' -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams } 'Operation identity must be ordinal and case sensitive.'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 5678 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams } 'A retry with changed source PID must fence the prior helper.'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @guardSourceParams } 'No source PID may be inferred from the mutable marker.'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 1234 @guardSourceParams } 'No helper dispatch may be inferred from the mutable marker.'
    $wrongSourceParams = $guardSourceParams.Clone()
    $wrongSourceParams.ExpectedSourceCreationUtc = '2026-10-12T09:59:00.1234570Z'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @wrongSourceParams } 'The same PID with a different exact birth must reject.'
    $wrongSourceParams = $guardSourceParams.Clone()
    $wrongSourceParams.ExpectedLaunchGenerationId = '44444444-4444-4444-8444-444444444444'
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @wrongSourceParams } 'The same PID and operation in a later launch generation must reject.'
    $wrongSourceParams = $guardSourceParams.Clone()
    $wrongSourceParams.Remove('ExpectedSourceCreationUtc')
    Assert-GuardRejects { Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 1234 -ExpectedHelperLaunchId '11111111-1111-4111-8111-111111111111' @wrongSourceParams } 'Exact source birth cannot be inferred from the mutable marker.'
    Write-Host 'Passed: missing caller ownership, stale operation and changed source reject before recycle work.'

    $intent = Read-GuardFixture
    $retriedMarker = New-GuardMarker
    $retriedMarker.helperLaunchId = '22222222-2222-4222-8222-222222222222'
    Write-GuardMarker $retriedMarker
    $originalBytes = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:GuardMarkerPath))
    $destructiveCalls = 0
    try {
        $null = Read-GuardFixture
        $destructiveCalls++
    } catch {}
    Assert-GuardCondition ($destructiveCalls -eq 0) 'A stale dispatch with reused source PID and same operation must reject before destructive work.'
    Assert-GuardCondition (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:GuardMarkerPath))) -ceq $originalBytes) 'Rejecting a stale dispatch must not mutate the newer intent.'
    Assert-GuardRejects { Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent } 'A captured dispatch cannot continue after a same-operation same-PID retry rewrites its nonce.'
    $null = Read-ScaleWorldRecycleIntent -MarkerPath $script:GuardMarkerPath -ExpectedRecycleId 'original-operation' -ExpectedSourcePid 1234 -ExpectedHelperLaunchId $retriedMarker.helperLaunchId @guardSourceParams
    Write-Host 'Passed: fresh dispatch nonce fences stale same-operation helpers even when source PID is reused, without writes.'

    $legacyMarker = New-GuardMarker
    $legacyMarker.Remove('helperLaunchId')
    Write-GuardMarker $legacyMarker
    Assert-GuardRejects { Read-GuardFixture } 'An old marker without dispatch proof must fail closed before destructive work.'

    foreach ($field in @('schemaVersion', 'phase', 'requestedAtUtc', 'reason', 'recycleId', 'sourcePid', 'helperLaunchId', 'sourceLaunchGenerationId', 'sourceCreationUtc', 'recycleRequestedToken', 'sessionRequestId', 'userSessionId', 'sessionId')) {
        Write-GuardMarker (New-GuardMarker)
        $intent = Read-GuardFixture
        $changed = New-GuardMarker
        switch ($field) {
            'schemaVersion' { $changed[$field] = 1 }
            'phase' { $changed[$field] = 'replacement_started'; $changed.replacementStartedAtUtc = '2026-10-12T10:00:01.000Z' }
            'requestedAtUtc' { $changed[$field] = '2026-10-12T10:00:00.001Z' }
            'sourcePid' { $changed[$field] = 5678 }
            default { $changed[$field] = [string]$changed[$field] + '-changed' }
        }
        Write-GuardMarker $changed
        Assert-GuardRejects { Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent } "A captured intent must reject changed $field."
    }
    Write-GuardMarker (New-GuardMarker)
    $intent = Read-GuardFixture
    $changed = New-GuardMarker
    $changed.futureProvenance = 'another-generation'
    Write-GuardMarker $changed
    Assert-GuardRejects { Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent } 'An unknown provenance field must also be fenced.'
    Write-GuardMarker (New-GuardMarker)
    $intent = Read-GuardFixture
    [System.IO.File]::Delete($script:GuardMarkerPath)
    Assert-GuardRejects { Assert-ScaleWorldRecycleIntentUnchanged -Intent $intent } 'Deleted intent must not be recreated or treated as permission to continue.'
    Write-Host 'Passed: source, operation, phase, timestamp, token, session and unknown-field changes fence captured work.'

    $invalidCases = @(
        @{ Field = 'schemaVersion'; Value = 3 },
        @{ Field = 'schemaVersion'; Value = '2' },
        @{ Field = 'sourcePid'; Value = '1234' },
        @{ Field = 'sourcePid'; Value = 1234.5 },
        @{ Field = 'sourcePid'; Value = 0 },
        @{ Field = 'requestedAtUtc'; Value = 'invalid' },
        @{ Field = 'reason'; Value = ' ' },
        @{ Field = 'reason'; Value = 12 },
        @{ Field = 'recycleId'; Value = ' ' },
        @{ Field = 'phase'; Value = 'Intent' },
        @{ Field = 'replacementStartedAtUtc'; Value = $null },
        @{ Field = 'resetCompletedAtUtc'; Value = $null }
    )
    foreach ($case in $invalidCases) {
        $invalid = New-GuardMarker
        $invalid[$case.Field] = $case.Value
        Write-GuardMarker $invalid
        Assert-GuardRejects { Read-GuardFixture } "Invalid marker field $($case.Field) must reject."
    }
    foreach ($content in @('null', '[]', '[{}]', '"not a marker"', '{broken')) {
        [System.IO.File]::WriteAllText($script:GuardMarkerPath, $content, [System.Text.UTF8Encoding]::new($false))
        Assert-GuardRejects { Read-GuardFixture } 'Malformed or non-object JSON must reject.'
    }
    [System.IO.File]::WriteAllText($script:GuardMarkerPath, ('[' + ((New-GuardMarker) | ConvertTo-Json) + ']'), [System.Text.UTF8Encoding]::new($false))
    Assert-GuardRejects { Read-GuardFixture } 'A valid marker inside a top-level array must not unwrap into permission.'
    [System.IO.File]::WriteAllText($script:GuardMarkerPath, ((New-GuardMarker) | ConvertTo-Json), [System.Text.UTF8Encoding]::new($true))
    Assert-GuardRejects { Read-GuardFixture } 'UTF-8 BOM must fail consistently with the runtime JSON reader.'
    Assert-GuardRejects { Assert-ScaleWorldRecycleIntentUnchanged -Intent $null } 'No captured guard may be inferred.'
    Write-Host 'Passed: invalid, malformed, missing and non-intent markers fail closed.'
    Write-Host 'Recycle intent guard tests passed (read-only marker checks; no process or hosted operations).'
} finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = (Join-Path $testParent 'ScaleWorldRecycleIntentTest-')
    if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the generated recycle-intent test directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
