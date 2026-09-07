[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Execute copied batch subroutines with tiny Node stand-ins and mocked downloads.
# No real Node install, server, network request, or host process is touched.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoot = Join-Path $tempRoot ('sw-platform-node-' + [guid]::NewGuid().ToString('N'))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The Windows .NET Framework C# compiler is required for the isolated executable fixture.'
}

function Assert-NodeTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-TestFile {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $stubSource = Join-Path $fixtureRoot 'NodeStub.cs'
    $stubExe = Join-Path $fixtureRoot 'node.exe'
    Write-TestFile $stubSource @'
using System;
using System.IO;
class NodeStub {
    static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "-v") {
            Console.WriteLine(File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "version.txt")).Trim());
            return 0;
        }
        File.WriteAllLines(Environment.GetEnvironmentVariable("NODE_TEST_ARGS_FILE"), args);
        File.WriteAllText(Environment.GetEnvironmentVariable("NODE_TEST_CWD_FILE"), Environment.CurrentDirectory);
        return 0;
    }
}
'@
    & $compiler /nologo /target:exe ("/out:{0}" -f $stubExe) $stubSource
    Assert-NodeTest ($LASTEXITCODE -eq 0) 'Could not build the isolated Node stand-in.'

    $common = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\cmd\common.bat'))
    $downloadLine = 'curl --fail -L -o ./node.zip "https://nodejs.org/dist/%NODE_VERSION%/%NODE_NAME%.zip"'
    Assert-NodeTest ($common.Contains($downloadLine)) 'Node download seam changed; review the isolation before updating this harness.'
    $common = $common.Replace($downloadLine, 'call :TestDownload') + @'

:TestDownload
if "%TEST_DOWNLOAD_FAILURE%"=="1" exit /b 1
type nul > node.zip
exit /b 0
:TestExtract
exit /b 0
'@
    foreach ($scenario in @('upgrade', 'matching', 'bad-version', 'download-failure')) {
        $scenarioRoot = Join-Path $fixtureRoot ($scenario + ' with spaces')
        $cmdDir = Join-Path $scenarioRoot 'SignallingWebServer\platform_scripts\cmd'
        $installedDir = Join-Path $cmdDir 'node'
        $extractedDir = Join-Path $cmdDir 'node-v22.23.2-win-x64'
        New-Item -ItemType Directory -Path $installedDir, $extractedDir, (Join-Path $scenarioRoot 'node_modules') -Force | Out-Null
        Copy-Item -LiteralPath $stubExe -Destination (Join-Path $installedDir 'node.exe')
        Copy-Item -LiteralPath $stubExe -Destination (Join-Path $extractedDir 'node.exe')
        $installedVersion = if ($scenario -eq 'matching') { 'v22.23.2' } else { 'v22.14.0' }
        $extractedVersion = if ($scenario -eq 'bad-version') { 'v22.14.0' } else { 'v22.23.2' }
        Write-TestFile (Join-Path $installedDir 'version.txt') $installedVersion
        Write-TestFile (Join-Path $extractedDir 'version.txt') $extractedVersion
        Write-TestFile (Join-Path $cmdDir 'common.bat') $common
        $wrapper = @'
@echo off
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
set "NODE_VERSION=v22.23.2"
set "TAR=call :TestExtract"
set "INSTALL_DEPS=0"
set "TEST_DOWNLOAD_FAILURE=%~1"
call :SetupNode
if errorlevel 1 exit /b 1
set "NODE_TEST_ARGS_FILE=%SCRIPT_DIR%arguments.txt"
set "NODE_TEST_CWD_FILE=%SCRIPT_DIR%cwd.txt"
set SERVER_ARGS=--auth_mode=enforce --quoted="a value with spaces"
call :StartWilbur
exit /b %errorlevel%
:SetupNode
:StartWilbur
"%~dp0common.bat" %*
'@
        $wrapperPath = Join-Path $cmdDir 'probe.bat'
        Write-TestFile $wrapperPath $wrapper
        # A matching install must succeed even when all downloads would fail.
        $downloadFailure = if ($scenario -in @('matching', 'download-failure')) { '1' } else { '0' }
        & $wrapperPath $downloadFailure | Out-Null
        $result = $LASTEXITCODE
        $backups = @(Get-ChildItem -LiteralPath $cmdDir -Directory -Filter 'node-backup-*')
        $versionAfter = (& (Join-Path $installedDir 'node.exe') -v).Trim()
        if ($scenario -in @('upgrade', 'matching')) {
            Assert-NodeTest ($result -eq 0) "$scenario failed."
            Assert-NodeTest ($versionAfter -eq 'v22.23.2') "$scenario selected the wrong Node version."
            $argsAfter = @(Get-Content -LiteralPath (Join-Path $cmdDir 'arguments.txt'))
            Assert-NodeTest (($argsAfter -join '|') -eq '.\dist\index.js|--auth_mode=enforce|--quoted=a value with spaces') 'Launch changed server arguments or used npm start.'
            $cwdAfter = [IO.File]::ReadAllText((Join-Path $cmdDir 'cwd.txt'))
            Assert-NodeTest ($cwdAfter -eq (Join-Path $scenarioRoot 'SignallingWebServer')) 'Launch lost its quoted working directory.'
            if ($scenario -eq 'upgrade') {
                Assert-NodeTest ($backups.Count -eq 1) 'Upgrade must retain exactly one prior runtime.'
                $oldVersion = (& (Join-Path $backups[0].FullName 'node.exe') -v).Trim()
                Assert-NodeTest ($oldVersion -eq 'v22.14.0') 'Upgrade did not preserve the old runtime.'
            } else {
                Assert-NodeTest ($backups.Count -eq 0) 'Matching runtime should not be moved.'
            }
        } else {
            Assert-NodeTest ($result -ne 0) "$scenario must reject startup."
            Assert-NodeTest ($versionAfter -eq 'v22.14.0' -and $backups.Count -eq 0) "$scenario moved or replaced the original runtime."
            Assert-NodeTest (-not (Test-Path -LiteralPath (Join-Path $cmdDir 'arguments.txt'))) "$scenario launched the server."
        }
    }
    Write-Output 'Platform Node setup tests passed: upgrade, matching pin, bad replacement, download failure, direct launch and spaced paths.'
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedFixture) -notmatch '^sw-platform-node-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unexpected fixture path.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
