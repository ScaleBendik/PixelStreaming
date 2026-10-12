# Read-only operation fencing for the full-stack recycler. The caller must hold
# its cross-process recycle/launch coordination gate while capturing and checking
# this intent. These functions do not stop processes or advance the marker.

function Get-ScaleWorldRecycleIntentProperty {
    param(
        [object]$Marker,
        [string]$Name
    )

    $property = $Marker.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Read-ScaleWorldRecycleIntent {
    [CmdletBinding()]
    param(
        [string]$MarkerPath,
        [string]$ExpectedRecycleId,
        [int]$ExpectedSourcePid,
        [string]$ExpectedHelperLaunchId,
        [string]$ExpectedLaunchGenerationId,
        [string]$ExpectedSourceCreationUtc
    )

    if ([string]::IsNullOrWhiteSpace($MarkerPath) -or
        [string]::IsNullOrWhiteSpace($ExpectedRecycleId) -or
        $ExpectedSourcePid -le 0 -or
        $ExpectedHelperLaunchId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' -or
        $ExpectedLaunchGenerationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $ExpectedLaunchGenerationId -ceq '00000000-0000-0000-0000-000000000000' -or
        $ExpectedSourceCreationUtc -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') {
        throw 'Explicit operation, source PID, helper dispatch, launch generation, and exact source birth are required before recycle work.'
    }
    $parsedSourceCreationUtc = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($ExpectedSourceCreationUtc, 'o', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedSourceCreationUtc)) {
        throw 'The expected source birth must be an exact UTC round-trip timestamp.'
    }

    $resolvedMarkerPath = [System.IO.Path]::GetFullPath($MarkerPath)
    $bytes = [System.IO.File]::ReadAllBytes($resolvedMarkerPath)
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $content = $utf8.GetString($bytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xfeff) {
        throw 'The recycle marker must use BOM-free UTF-8, matching the runtime marker reader.'
    }
    # Windows PowerShell can unwrap a one-element top-level JSON array. Reject
    # that shape before parsing so it cannot impersonate the runtime's object.
    if (-not $content.TrimStart().StartsWith('{', [System.StringComparison]::Ordinal)) {
        throw 'The recycle marker must contain one JSON object.'
    }
    $marker = $content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $marker -or $marker -isnot [pscustomobject]) {
        throw 'The recycle marker must contain one JSON object.'
    }

    $schemaVersion = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'schemaVersion'
    $phase = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'phase'
    $recycleId = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'recycleId'
    $sourcePid = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'sourcePid'
    $helperLaunchId = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'helperLaunchId'
    $sourceLaunchGenerationId = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'sourceLaunchGenerationId'
    $sourceCreationUtc = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'sourceCreationUtc'
    $reason = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'reason'
    $requestedAtUtc = Get-ScaleWorldRecycleIntentProperty -Marker $marker -Name 'requestedAtUtc'
    $sourcePidIsNumber = $sourcePid -is [int] -or $sourcePid -is [long] -or $sourcePid -is [double] -or $sourcePid -is [decimal]
    $schemaIsNumber = $schemaVersion -is [int] -or $schemaVersion -is [long] -or $schemaVersion -is [double] -or $schemaVersion -is [decimal]
    $parsedRequestedAtUtc = [DateTimeOffset]::MinValue
    $hasValidRequestedAtUtc = $requestedAtUtc -is [string] -and
        -not [string]::IsNullOrWhiteSpace($requestedAtUtc) -and
        [DateTimeOffset]::TryParse(
            $requestedAtUtc.Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsedRequestedAtUtc
        )
    if (-not $schemaIsNumber -or ($schemaVersion -ne 1 -and $schemaVersion -ne 2) -or
        $phase -isnot [string] -or $phase -cne 'intent' -or
        $recycleId -isnot [string] -or [string]::IsNullOrWhiteSpace($recycleId) -or
        $reason -isnot [string] -or [string]::IsNullOrWhiteSpace($reason) -or
        -not $hasValidRequestedAtUtc -or
        -not $sourcePidIsNumber -or $sourcePid -le 0 -or $sourcePid -gt [int]::MaxValue -or
        [Math]::Truncate([double]$sourcePid) -ne [double]$sourcePid -or
        $null -ne $marker.PSObject.Properties['replacementStartedAtUtc'] -or
        $null -ne $marker.PSObject.Properties['resetCompletedAtUtc']) {
        throw 'The recycle marker is not a valid schema 1 or 2 pre-launch intent.'
    }

    $normalizedExpectedRecycleId = $ExpectedRecycleId.Trim()
    if ($recycleId.Trim() -cne $normalizedExpectedRecycleId -or $sourcePid -ne $ExpectedSourcePid -or
        $helperLaunchId -isnot [string] -or $helperLaunchId -cne $ExpectedHelperLaunchId -or
        $sourceLaunchGenerationId -isnot [string] -or $sourceLaunchGenerationId -cne $ExpectedLaunchGenerationId -or
        $sourceCreationUtc -isnot [string] -or $sourceCreationUtc -cne $ExpectedSourceCreationUtc) {
        throw 'The durable recycle intent does not belong to the expected operation, helper dispatch, launch generation, and source birth.'
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $contentSha256 = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }

    # Keep the original marker, including token/session provenance and future
    # fields. The content hash makes every rewrite visible at the next check.
    return [pscustomobject]@{
        MarkerPath = $resolvedMarkerPath
        ExpectedRecycleId = $normalizedExpectedRecycleId
        ExpectedSourcePid = $ExpectedSourcePid
        ExpectedHelperLaunchId = $ExpectedHelperLaunchId
        ExpectedLaunchGenerationId = $ExpectedLaunchGenerationId
        ExpectedSourceCreationUtc = $ExpectedSourceCreationUtc
        ContentSha256 = $contentSha256
        Marker = $marker
    }
}

function Assert-ScaleWorldRecycleIntentUnchanged {
    [CmdletBinding()]
    param([object]$Intent)

    if ($null -eq $Intent -or
        $null -eq $Intent.PSObject.Properties['MarkerPath'] -or
        $null -eq $Intent.PSObject.Properties['ExpectedRecycleId'] -or
        $null -eq $Intent.PSObject.Properties['ExpectedSourcePid'] -or
        $null -eq $Intent.PSObject.Properties['ExpectedHelperLaunchId'] -or
        $null -eq $Intent.PSObject.Properties['ExpectedLaunchGenerationId'] -or
        $null -eq $Intent.PSObject.Properties['ExpectedSourceCreationUtc'] -or
        $null -eq $Intent.PSObject.Properties['ContentSha256'] -or
        [string]$Intent.ContentSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'A captured recycle intent is required before recycle work can continue.'
    }

    $currentIntent = Read-ScaleWorldRecycleIntent `
        -MarkerPath $Intent.MarkerPath `
        -ExpectedRecycleId $Intent.ExpectedRecycleId `
        -ExpectedSourcePid $Intent.ExpectedSourcePid `
        -ExpectedHelperLaunchId $Intent.ExpectedHelperLaunchId `
        -ExpectedLaunchGenerationId $Intent.ExpectedLaunchGenerationId `
        -ExpectedSourceCreationUtc $Intent.ExpectedSourceCreationUtc
    if ($currentIntent.ContentSha256 -cne $Intent.ContentSha256) {
        throw 'The durable recycle intent changed after this helper captured it. Refusing to continue recycle work.'
    }
    return $currentIntent.Marker
}
