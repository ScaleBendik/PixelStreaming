param()

$ErrorActionPreference = "Stop"

if ($args | Where-Object { $_ -match '^-{1,2}Force$' }) {
    throw "The prod launcher always requires manual confirmation. Use publish-target-ref.ps1 directly only for intentional automation."
}

$scriptPath = Join-Path $PSScriptRoot "publish-target-ref.ps1"
& $scriptPath -Track "prod" -CreateTag @args
