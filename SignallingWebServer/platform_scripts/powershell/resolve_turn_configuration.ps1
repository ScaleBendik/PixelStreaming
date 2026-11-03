[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Select', 'Validate')]
    [string]$Phase
)

# This helper never reads AWS or prints credential values. Select emits only
# validated, non-secret batch assignments; its final marker proves success.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $lane = $env:SCALEWORLD_STREAMING_LANE
    $track = $env:SCALEWORLD_DEPLOYMENT_TRACK
    if ($lane -notin @('prod', 'nonprod') -or
        ($lane -eq 'prod' -and $track -ne 'prod') -or
        ($lane -eq 'nonprod' -and $track -notin @('dev', 'stage'))) {
        throw 'TURN requires a matching streaming lane and deployment track.'
    }
    $lane = $lane.ToLowerInvariant()
    $mode = $env:SCALEWORLD_TURN_MODE
    if ([string]::IsNullOrEmpty($mode)) { $mode = 'legacy-shared' }
    if ($mode -notin @('legacy-shared', 'isolated', 'redundant')) {
        throw 'SCALEWORLD_TURN_MODE must be legacy-shared, isolated or redundant.'
    }
    $mode = $mode.ToLowerInvariant()
    if ($mode -eq 'redundant' -and $lane -ne 'prod') {
        throw 'Redundant TURN is Prod-only; nonprod primary and retained fallback are the same relay.'
    }

    if ($Phase -eq 'Select') {
        $prefix = '/pixelstreaming/turn'
        if ($mode -ne 'legacy-shared') { $prefix = "/pixelstreaming/$lane/turn" }
        $selection = [ordered]@{
            SCALEWORLD_TURN_MODE = $mode
            TURN_USER_PARAM = "$prefix/username"
            TURN_CREDENTIAL_PARAM = "$prefix/credential"
            TURN_PUBLIC_HOST_PARAM = ''
            TURN_PRIVATE_HOST_PARAM = ''
            TURN_PUBLIC_HOST = 'turn.scaleworld.net'
            TURN_PRIVATE_HOST = '172.31.32.124'
            TURN_FALLBACK_USER_PARAM = ''
            TURN_FALLBACK_CREDENTIAL_PARAM = ''
            TURN_FALLBACK_USERNAME = ''
            TURN_FALLBACK_CREDENTIAL = ''
        }

        foreach ($name in @('TURN_USER_PARAM', 'TURN_CREDENTIAL_PARAM')) {
            $override = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrEmpty($override)) { continue }
            # Existing emergency credential paths remain usable in compatibility
            # mode. Isolated mode cannot inherit a shared/other-lane override.
            if ($override -cnotmatch '^/[A-Za-z0-9_./-]+$' -or
                ($mode -ne 'legacy-shared' -and $override -cne $selection[$name]) -or
                ($lane -eq 'nonprod' -and $override.StartsWith('/pixelstreaming/prod/')) -or
                ($lane -eq 'prod' -and $override -cmatch '^/pixelstreaming/(nonprod|dev|stage)/')) {
                throw "Invalid or cross-boundary $name; clear the override before changing TURN mode."
            }
            $selection[$name] = $override
        }

        if ($mode -ne 'legacy-shared') {
            $selection.TURN_PUBLIC_HOST_PARAM = "$prefix/public-host"
            $selection.TURN_PRIVATE_HOST_PARAM = "$prefix/private-host"
            # Never retain hosts from the preceding configuration if SSM fails.
            $selection.TURN_PUBLIC_HOST = ''
            $selection.TURN_PRIVATE_HOST = ''
        }
        if ($mode -eq 'redundant') {
            # Separate credentials on the retained host; never read another
            # environment's namespace or copy the primary credential to it.
            $selection.TURN_FALLBACK_USER_PARAM = "/pixelstreaming/$lane/turn-fallback/username"
            $selection.TURN_FALLBACK_CREDENTIAL_PARAM = "/pixelstreaming/$lane/turn-fallback/credential"
        }
        foreach ($entry in $selection.GetEnumerator()) {
            Write-Output "$($entry.Key)=$($entry.Value)"
        }
        Write-Output 'TURN_CONFIGURATION_READY=1'
        exit 0
    }

    foreach ($name in @('TURN_USERNAME', 'TURN_CREDENTIAL', 'TURN_PUBLIC_HOST', 'TURN_PRIVATE_HOST')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Required $name was not loaded; TURN startup refused."
        }
    }
    if ($mode -ne 'legacy-shared') {
        if ($env:TURN_PUBLIC_HOST -cne "turn-$lane.scaleworld.net" -or
            $env:TURN_PRIVATE_HOST -cne "turn-$lane.internal.scaleworld.net") {
            throw 'Isolated TURN endpoints must match the selected lane public/private DNS names.'
        }
    } elseif ($env:TURN_PUBLIC_HOST -cne 'turn.scaleworld.net' -or $env:TURN_PRIVATE_HOST -cne '172.31.32.124') {
        throw 'Legacy TURN mode requires the retained shared endpoints.'
    }
    if ($mode -eq 'redundant') {
        foreach ($name in @('TURN_FALLBACK_USERNAME', 'TURN_FALLBACK_CREDENTIAL')) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
                throw "Required $name was not loaded; redundant TURN startup refused."
            }
        }
        if ($env:TURN_FALLBACK_USERNAME -ceq $env:TURN_USERNAME -or $env:TURN_FALLBACK_CREDENTIAL -ceq $env:TURN_CREDENTIAL) {
            throw 'Primary and fallback TURN must have separate credentials.'
        }
    }
    exit 0
} catch {
    # All thrown messages above are fixed text or contain allowlisted variable
    # names only. Never echo untrusted parameter values or credential material.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
