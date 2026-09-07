[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $tempRoot ('sw-service-args-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$previousArgs = $env:SCALEWORLD_UNREAL_STARTUP_ARGS
$previousPremium = $env:SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS
$previousMarker = $env:SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG
try {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\cmd\start_streamer_stack.bat')
    $start = [Array]::IndexOf($source, ':apply_unreal_service_class_startup_args')
    $end = [Array]::IndexOf($source, ':resolve_maintenance_mode_from_instance_tag')
    if ($start -lt 0 -or $end -le $start) { throw 'Service-class subroutine was not found.' }
    $defaults = @($source | Where-Object { $_.StartsWith('if not defined SCALEWORLD_UNREAL_PREMIUM_') -or $_.StartsWith('if not defined SCALEWORLD_STANDARD_ENCODER_CODEC') -or $_.StartsWith('if not defined SCALEWORLD_PREMIUM_ENCODER_CODEC') })
    $resolver = Join-Path $fixture 'resolver.ps1'
    Set-Content -LiteralPath $resolver -Value 'Write-Output $env:TEST_SERVICE_CLASS' -Encoding ascii
    $scriptDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\cmd')) + '\'
    $probe = @('@echo off', 'setlocal EnableDelayedExpansion', ('set "SCRIPT_DIR={0}"' -f $scriptDir),
        ('set "RESOLVE_SERVICE_CLASS_SCRIPT={0}"' -f $resolver)) + $defaults + @(
        'set "TEST_SERVICE_CLASS=premium"',
        'call :apply_unreal_service_class_startup_args', 'if errorlevel 1 exit /b 1',
        ('>"{0}" echo(!SCALEWORLD_UNREAL_STARTUP_ARGS!' -f (Join-Path $fixture 'first.txt')),
        'call :apply_unreal_service_class_startup_args', 'if errorlevel 1 exit /b 1',
        ('>"{0}" echo(!SCALEWORLD_UNREAL_STARTUP_ARGS!' -f (Join-Path $fixture 'second.txt')),
        'set "TEST_SERVICE_CLASS=standard"',
        'call :apply_unreal_service_class_startup_args', 'if errorlevel 1 exit /b 1',
        ('>"{0}" echo(!SCALEWORLD_UNREAL_STARTUP_ARGS!' -f (Join-Path $fixture 'standard.txt')),
        'exit /b 0') + $source[$start..($end - 1)]
    $probePath = Join-Path $fixture 'probe.cmd'
    Set-Content -LiteralPath $probePath -Value $probe -Encoding ascii

    foreach ($premiumOverride in @('', '-ExecCmds="custom=value"')) {
        $env:SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS = $premiumOverride
        $env:SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG = ''
        $custom = '-Custom=one -CustomText="hello! world" -ScaleWorldPremiumBackup'
        $env:SCALEWORLD_UNREAL_STARTUP_ARGS = $custom
        & cmd.exe /d /c $probePath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Isolated service-class launcher failed.' }
        $first = (Get-Content -LiteralPath (Join-Path $fixture 'first.txt') -Raw).Trim()
        $second = (Get-Content -LiteralPath (Join-Path $fixture 'second.txt') -Raw).Trim()
        $standard = (Get-Content -LiteralPath (Join-Path $fixture 'standard.txt') -Raw).Trim()
        if ($first -cne $second) { throw 'Repeated Premium startup changed the command line.' }
        if ($standard -cne $custom) { throw "Standard startup did not preserve custom arguments: $standard" }
        if ([regex]::Matches($first, '(?<!\S)-ScaleWorldPremium(?=\s|$)').Count -ne 1) {
            throw 'Premium marker must occur exactly once.'
        }
        if ([regex]::Matches($first, '-ExecCmds=').Count -ne 1) {
            throw 'Premium scalability arguments must occur exactly once.'
        }
    }
    Write-Output 'Unreal service-class argument execution tests passed.'
} finally {
    $env:SCALEWORLD_UNREAL_STARTUP_ARGS = $previousArgs
    $env:SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS = $previousPremium
    $env:SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG = $previousMarker
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedFixture) -notmatch '^sw-service-args-[0-9a-f]{32}$') {
        throw 'Refusing to remove unexpected fixture path.'
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
