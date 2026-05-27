param()

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "publish-target-ref.ps1"
& $scriptPath -Track "dev" -CreateTag @args
