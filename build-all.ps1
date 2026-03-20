param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetScript = Join-Path $scriptRoot 'BuildScripts\build-all.ps1'

if (-not (Test-Path -LiteralPath $targetScript)) {
    throw "BuildScripts\build-all.ps1 was not found at '$targetScript'."
}

& $targetScript @PSBoundParameters
if ($LASTEXITCODE) {
    exit $LASTEXITCODE
}
