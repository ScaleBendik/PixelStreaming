[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Value
)

$normalized = $Value.Trim().ToLowerInvariant()
switch ($normalized) {
    { $_ -in @('git_ref', 'git-ref', 'git') } {
        Write-Output 'git_ref'
        exit 0
    }
    { $_ -in @('runtime_artifact', 'runtime-artifact', 'artifact') } {
        Write-Output 'runtime_artifact'
        exit 0
    }
    'auto' {
        Write-Output 'auto'
        exit 0
    }
    default {
        Write-Error "Unsupported PixelStreaming delivery mode '$Value'. Use git_ref, runtime_artifact, or auto."
        exit 2
    }
}
