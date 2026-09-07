[CmdletBinding()]
param([string]$NodePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exercise only dependency-copy helpers and their staging block, using tiny fixtures.
# The packager's build, archive, metadata, and publication code is never evaluated.
$sourceRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $NodePath = Join-Path $sourceRepo 'SignallingWebServer\platform_scripts\cmd\node\node.exe'
    if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
        $NodePath = (Get-Command node.exe -ErrorAction Stop).Source
    }
}
$null = Get-Command robocopy.exe -ErrorAction Stop

function Assert-PackageTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-FixtureFile {
    param([string]$Path, [string]$Content)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-FixturePackage {
    param([string]$Root, [string]$Name, [string]$Version)
    Write-FixtureFile (Join-Path $Root 'package.json') (
        @{ name = $Name; version = $Version; main = 'dist/index.js' } | ConvertTo-Json -Compress)
}

$packager = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'package-runtime-artifact.ps1'))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($packager, [ref]$tokens, [ref]$parseErrors)
Assert-PackageTest (@($parseErrors).Count -eq 0) 'Could not parse the runtime packager.'

foreach ($functionName in @('Invoke-Robocopy', 'Copy-WorkspaceNodeModules', 'Copy-RuntimeWorkspacePackage')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert-PackageTest ($null -ne $definition) "Missing packaging helper: $functionName"
    . ([scriptblock]::Create($definition.Extent.Text))
}

$dependencyBlocks = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '-not $SkipNodeModules'
})
Assert-PackageTest ($dependencyBlocks.Count -eq 1) 'Could not isolate the dependency-only staging block.'
$stageDependencies = [scriptblock]::Create($dependencyBlocks[0].Extent.Text)

$fixtureTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoot = Join-Path $fixtureTempRoot ('sw-runtime-deps-' + [guid]::NewGuid().ToString('N'))
try {
    $repoRootPath = Join-Path $fixtureRoot 'source with spaces'
    $stageRoot = Join-Path $fixtureRoot 'staged with spaces'
    Write-FixturePackage (Join-Path $repoRootPath 'node_modules\commander') 'commander' '13.1.0'
    Write-FixturePackage (Join-Path $repoRootPath 'node_modules\fixture-dependency') 'fixture-dependency' '9.0.0'
    Write-FixturePackage (Join-Path $repoRootPath 'node_modules\@epicgames-ps\lib-pixelstreamingcommon-ue5.7') '@epicgames-ps/lib-pixelstreamingcommon-ue5.7' '0.0.0'
    Write-FixturePackage (Join-Path $repoRootPath 'SignallingWebServer\node_modules\commander') 'commander' '12.1.0'
    Write-FixtureFile (Join-Path $repoRootPath 'SignallingWebServer\node_modules\.cache\ignored.txt') 'cache'

    foreach ($workspace in @('Common', 'Signalling')) {
        $packageName = if ($workspace -eq 'Common') { 'lib-pixelstreamingcommon-ue5.8' } else { 'lib-pixelstreamingsignalling-ue5.8' }
        $localVersion = if ($workspace -eq 'Common') { '1.0.0' } else { '2.0.0' }
        $workspaceRoot = Join-Path $repoRootPath $workspace
        Write-FixturePackage $workspaceRoot "@epicgames-ps/$packageName" '0.1.0'
        Write-FixtureFile (Join-Path $workspaceRoot 'dist\index.js') "module.exports = require('fixture-dependency/package.json').version;"
        Write-FixturePackage (Join-Path $workspaceRoot 'node_modules\fixture-dependency') 'fixture-dependency' $localVersion
    }

    $SkipNodeModules = $false
    $containsNodeModules = $false
    . $stageDependencies
    Assert-PackageTest $containsNodeModules 'Dependency staging did not mark the payload complete.'
    Assert-PackageTest (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'SignallingWebServer\node_modules\.cache'))) 'Workspace cache leaked into the payload.'
    Assert-PackageTest (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'node_modules\@epicgames-ps\lib-pixelstreamingcommon-ue5.7'))) 'Stale Epic package was copied instead of materializing UE5.8.'

    $resolutionProbe = @"
const assert = require('node:assert/strict');
const path = require('node:path');
const { createRequire } = require('node:module');
const root = process.argv[1];
const fromRoot = createRequire(path.join(root, '__probe__.cjs'));
const fromWilbur = createRequire(path.join(root, 'SignallingWebServer', '__probe__.cjs'));
assert.equal(fromRoot('commander/package.json').version, '13.1.0');
assert.equal(fromWilbur('commander/package.json').version, '12.1.0');
assert.equal(fromRoot('fixture-dependency/package.json').version, '9.0.0');
for (const [workspace, packageName, version] of [
    ['Common', '@epicgames-ps/lib-pixelstreamingcommon-ue5.8', '1.0.0'],
    ['Signalling', '@epicgames-ps/lib-pixelstreamingsignalling-ue5.8', '2.0.0']
]) {
    const fromWorkspace = createRequire(path.join(root, workspace, '__probe__.cjs'));
    assert.equal(fromWorkspace('fixture-dependency/package.json').version, version);
    assert.equal(fromRoot(packageName), version);
}
"@
    & $NodePath -e $resolutionProbe $stageRoot
    Assert-PackageTest ($LASTEXITCODE -eq 0) 'Staged runtime dependency resolution changed.'

    $emptyDestination = Join-Path $fixtureRoot 'no local dependencies'
    Copy-WorkspaceNodeModules -WorkspaceRelativePath 'AbsentWorkspace' -DestinationRoot $emptyDestination
    Assert-PackageTest (-not (Test-Path -LiteralPath $emptyDestination)) 'Absent workspace dependencies should need no copy.'

    $stageRoot = Join-Path $fixtureRoot 'skipped dependencies'
    $SkipNodeModules = $true
    $containsNodeModules = $false
    . $stageDependencies
    Assert-PackageTest (-not $containsNodeModules -and -not (Test-Path -LiteralPath $stageRoot)) 'SkipNodeModules staged a dependency payload.'
    Write-Output 'Runtime packaging dependency tests passed: root/local version isolation, all runtime workspaces, materialized UE5.8 libraries, absent dependencies, and SkipNodeModules.'
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixture.StartsWith($fixtureTempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedFixture) -notmatch '^sw-runtime-deps-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unexpected fixture path.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
