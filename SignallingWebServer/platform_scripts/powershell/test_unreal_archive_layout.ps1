[CmdletBinding()]
param([string]$PackageRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$updaterPath = Join-Path $PSScriptRoot '..\..\..\SWupdate.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($updaterPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw $parseErrors[0] }
# Import only these functions: never execute updater initialization or AWS work.
foreach ($name in @('Resolve-ReleaseArchiveContentRoot', 'Expand-ReleaseArchive', 'Assert-ExecutableExists', 'Get-ReleaseMetadataFilePath', 'Write-ReleaseMetadata')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $definition) { throw "Missing updater function $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:Passed = 0
function Assert-Layout {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action | Out-Null } catch { $script:Passed++; return }
    throw $Message
}
function Write-Fixture {
    param([string]$Root, [string[]]$Paths)
    foreach ($relative in $Paths) {
        $path = Join-Path $Root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'fixture')
    }
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempRoot ('scaleworld-archive-layout-' + [guid]::NewGuid().ToString('N'))
$script:ScratchRoot = Join-Path $testRoot 'scratch'
$ExecutableName = 'ScaleWorld.exe'
New-Item -ItemType Directory -Path $script:ScratchRoot -Force | Out-Null
try {
    $developmentPaths = @('ScaleWorld.exe', 'ScaleWorld\Binaries\Win64\ScaleWorld.exe', 'ScaleWorld\Binaries\Win64\ScaleWorld.pdb', 'Engine\Content\sentinel.txt', 'ScaleWorld\Content\sentinel.txt')
    foreach ($layout in @('flat-development', 'wrapped-development', 'wrapped-shipping')) {
        $source = Join-Path $testRoot $layout
        $content = if ($layout -eq 'flat-development') { $source } else { Join-Path $source 'ScaleWorld_20260908' }
        $paths = if ($layout -eq 'wrapped-shipping') { @('ScaleWorld.exe', 'ScaleWorld\Binaries\Win64\ScaleWorld-Win64-Shipping.exe', 'Engine\Content\sentinel.txt') } else { $developmentPaths }
        Write-Fixture -Root $content -Paths $paths
        $resolved = Resolve-ReleaseArchiveContentRoot -StagingRoot $source -ExecutableName $ExecutableName
        Assert-Layout ($resolved -eq $content) "$layout selected the wrong content root."
        $zip = Join-Path $testRoot ($layout + '.zip')
        Compress-Archive -Path (Join-Path $source '*') -DestinationPath $zip
        $destination = Join-Path $testRoot ('installed-' + $layout)
        $metadata = [pscustomobject]@{ BuildId = $layout }
        $installed = Expand-ReleaseArchive -ArchivePath $zip -DestinationPath $destination -Metadata $metadata
        Assert-Layout ($installed -eq $destination) "$layout installed into the wrong directory."
        foreach ($relative in $paths) {
            Assert-Layout (Test-Path -LiteralPath (Join-Path $destination $relative)) "$layout lost $relative during extraction."
        }
        $state = Get-Content -LiteralPath (Join-Path $destination 'scaleworld-release.json') -Raw | ConvertFrom-Json
        Assert-Layout ($state.BuildId -eq $layout) "$layout did not preserve release metadata."
    }

    $ambiguous = Join-Path $testRoot 'ambiguous'
    Write-Fixture -Root $ambiguous -Paths @('A\ScaleWorld.exe', 'B\ScaleWorld.exe')
    Assert-Rejected { Resolve-ReleaseArchiveContentRoot -StagingRoot $ambiguous -ExecutableName $ExecutableName } 'Two release roots must be rejected.'
    $unexpected = Join-Path $testRoot 'unexpected'
    Write-Fixture -Root $unexpected -Paths ($developmentPaths + 'Other\ScaleWorld.exe')
    Assert-Rejected { Resolve-ReleaseArchiveContentRoot -StagingRoot $unexpected -ExecutableName $ExecutableName } 'An unexpected extra executable must be rejected.'
    $nestedOnly = Join-Path $testRoot 'nested-only'
    Write-Fixture -Root $nestedOnly -Paths @('ScaleWorld\Binaries\Win64\ScaleWorld.exe')
    Assert-Rejected { Resolve-ReleaseArchiveContentRoot -StagingRoot $nestedOnly -ExecutableName $ExecutableName } 'A nested runtime without its bootstrap must be rejected.'
    $empty = Join-Path $testRoot 'missing'
    Write-Fixture -Root $empty -Paths @('readme.txt')
    Assert-Rejected { Resolve-ReleaseArchiveContentRoot -StagingRoot $empty -ExecutableName $ExecutableName } 'A package without an executable must be rejected.'

    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        $actualRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
        Assert-Layout ((Resolve-ReleaseArchiveContentRoot -StagingRoot $actualRoot -ExecutableName $ExecutableName) -eq $actualRoot) 'Actual packaged build selected the wrong root.'
    }
    Write-Output "Unreal archive layout tests passed: $script:Passed assertions."
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
    if (-not $resolvedRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
