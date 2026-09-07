[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputPath)

$ErrorActionPreference = 'Stop'
$startupArgs = [string]$env:SCALEWORLD_UNREAL_STARTUP_ARGS
foreach ($inherited in @($env:SCALEWORLD_UNREAL_PREMIUM_STARTUP_ARGS, $env:SCALEWORLD_UNREAL_PREMIUM_INSTANCE_ARG)) {
    if (-not [string]::IsNullOrWhiteSpace($inherited)) {
        # Escape the entire configured value: CMD substitution cannot represent
        # a search string containing '=' (the default -ExecCmds argument does).
        $pattern = '(?<!\S)' + [regex]::Escape($inherited) + '(?=\s|$)'
        $startupArgs = [regex]::Replace($startupArgs, $pattern, '').Trim()
    }
}
if ($startupArgs.Contains("`r") -or $startupArgs.Contains("`n")) {
    throw 'Unreal startup arguments must fit on one command line.'
}
# The caller reads data with SET /P, never executes it as a batch script. Match
# CMD's console encoding and omit a BOM so custom arguments remain literal.
[IO.File]::WriteAllBytes($OutputPath, [Console]::InputEncoding.GetBytes($startupArgs))
