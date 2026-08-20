[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not [object]::Equals($Expected, $Actual)) {
        throw "$Message Expected='$Expected' Actual='$Actual'."
    }
}

$modulePath = Join-Path $PSScriptRoot 'unreal_prerequisite.psm1'
$module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop

try {
    $parsed = & $module { param($Value) ConvertTo-ScaleWorldPrerequisiteVersion -Value $Value } 'v14.50.35719.0'
    Assert-Equal -Expected '14.50.35719.0' -Actual ([string]$parsed) -Message 'Installer version parsing must accept the Microsoft v-prefixed format.'

    $parsedThreePart = & $module { param($Value) ConvertTo-ScaleWorldPrerequisiteVersion -Value $Value } '14.44.35211'
    Assert-Equal -Expected '14.44.35211.0' -Actual ([string]$parsedThreePart) -Message 'Installer version parsing must normalize missing revision to zero.'

    $invalid = & $module { param($Value) ConvertTo-ScaleWorldPrerequisiteVersion -Value $Value } 'not-a-version'
    Assert-True -Condition ($null -eq $invalid) -Message 'Invalid installer versions must not be guessed.'

    $divergentDllVersion = & $module {
        param($VersionInfo)
        Get-ScaleWorldRuntimeDllVersionFromVersionInfo -VersionInfo $VersionInfo
    } ([pscustomobject]@{
        FileVersion = '14.44.35211.0'
        ProductVersion = '14.50.35719.0'
    })
    Assert-Equal `
        -Expected '14.44.35211.0' `
        -Actual ([string]$divergentDllVersion) `
        -Message 'DLL acceptance must use the fixed FileVersion read by BootstrapPackagedGame rather than a divergent ProductVersion.'

    $missingFixedDllVersion = & $module {
        param($VersionInfo)
        Get-ScaleWorldRuntimeDllVersionFromVersionInfo -VersionInfo $VersionInfo
    } ([pscustomobject]@{
        FileVersion = ''
        ProductVersion = '14.50.35719.0'
    })
    Assert-True `
        -Condition ($null -eq $missingFixedDllVersion) `
        -Message 'A ProductVersion without fixed FileVersion metadata must not satisfy the engine DLL check.'

    $architectureException = $null
    try {
        & $module { Assert-ScaleWorldPrerequisiteProcessArchitecture -Is64BitProcess $false }
    } catch {
        $architectureException = $_.Exception
    }
    Assert-True `
        -Condition ($null -ne $architectureException) `
        -Message 'A 32-bit PowerShell host must fail before attempting x64 prerequisite verification.'
    Assert-Equal `
        -Expected 'unreal_prerequisite_64bit_powershell_required' `
        -Actual ([string]$architectureException.Data['ScaleWorldUpdateResultReason']) `
        -Message 'The 32-bit PowerShell guard must carry its stable update result reason.'

    $required = [System.Version]'14.50.35719.0'
    $satisfied = & $module {
        param($Required)
        Test-ScaleWorldHostRuntimeState `
            -RequiredVersion $Required `
            -RegistryVersion ([System.Version]'14.50.35719.0') `
            -Msvcp1402Version ([System.Version]'14.50.35719.0') `
            -Vcruntime1401Version ([System.Version]'14.50.35719.0') `
            -Msvcp1402Loadable $true `
            -Vcruntime1401Loadable $true
    } $required
    Assert-True -Condition $satisfied.Satisfied -Message 'Registry and both runtime DLLs at the required version must satisfy the contract.'

    $oldRegistry = & $module {
        param($Required)
        Test-ScaleWorldHostRuntimeState `
            -RequiredVersion $Required `
            -RegistryVersion ([System.Version]'14.44.35211.0') `
            -Msvcp1402Version ([System.Version]'14.50.35719.0') `
            -Vcruntime1401Version ([System.Version]'14.50.35719.0') `
            -Msvcp1402Loadable $true `
            -Vcruntime1401Loadable $true
    } $required
    Assert-True -Condition (-not $oldRegistry.Satisfied) -Message 'An old x64 registry runtime must fail even when the DLLs are current.'
    Assert-True -Condition (@($oldRegistry.Missing) -contains 'system/registry_x64') -Message 'The host-state result must identify an old registry runtime.'

    $missingDll = & $module {
        param($Required)
        Test-ScaleWorldHostRuntimeState `
            -RequiredVersion $Required `
            -RegistryVersion ([System.Version]'14.50.35719.0') `
            -Msvcp1402Version $null `
            -Vcruntime1401Version ([System.Version]'14.50.35719.0') `
            -Msvcp1402Loadable $false `
            -Vcruntime1401Loadable $true
    } $required
    Assert-True -Condition (-not $missingDll.Satisfied) -Message 'A missing required runtime DLL must fail the host contract.'
    Assert-True -Condition (@($missingDll.Missing) -contains 'system/msvcp140_2.dll') -Message 'The host-state result must identify the missing runtime DLL.'

    $appLocalSatisfied = & $module {
        param($Required)
        Test-ScaleWorldHostRuntimeState `
            -RequiredVersion $Required `
            -RegistryVersion ([System.Version]'14.44.35211.0') `
            -Msvcp1402Version ([System.Version]'14.44.35211.0') `
            -Vcruntime1401Version ([System.Version]'14.44.35211.0') `
            -AppLocalMsvcp1402Version ([System.Version]'14.50.35719.0') `
            -AppLocalVcruntime1401Version ([System.Version]'14.50.35719.0') `
            -Msvcp1402Loadable $true `
            -Vcruntime1401Loadable $true `
            -AppLocalMsvcp1402Loadable $true `
            -AppLocalVcruntime1401Loadable $true
    } $required
    Assert-True -Condition $appLocalSatisfied.Satisfied -Message 'Current app-local DLLs beside the packaged target must satisfy the Unreal bootstrap contract without registry state.'
    Assert-True -Condition $appLocalSatisfied.AppLocalSatisfied -Message 'The host-state result must report that the app-local alternative was selected.'
    Assert-True -Condition (-not $appLocalSatisfied.SystemSatisfied) -Message 'The app-local alternative must stay distinct from an old system runtime.'

    $unloadableDll = & $module {
        param($Required)
        Test-ScaleWorldHostRuntimeState `
            -RequiredVersion $Required `
            -RegistryVersion ([System.Version]'14.50.35719.0') `
            -Msvcp1402Version ([System.Version]'14.50.35719.0') `
            -Vcruntime1401Version ([System.Version]'14.50.35719.0') `
            -Msvcp1402Loadable $false `
            -Vcruntime1401Loadable $true
    } $required
    Assert-True -Condition (-not $unloadableDll.Satisfied) -Message 'A current but unloadable runtime DLL must not satisfy the Unreal bootstrap contract.'
    Assert-True -Condition (@($unloadableDll.Missing) -contains 'system/msvcp140_2.dll_unloadable') -Message 'The host-state result must identify an unloadable runtime DLL.'

    $kernel32Path = Join-Path (Join-Path $env:WINDIR 'System32') 'kernel32.dll'
    $knownLibraryLoadable = & $module { param($Path) Test-ScaleWorldRuntimeDllLoadable -Path $Path } $kernel32Path
    Assert-True -Condition $knownLibraryLoadable -Message 'The safe native load probe must accept a known System32 x64 library.'

    $scriptIsNotLoadable = & $module { param($Path) Test-ScaleWorldRuntimeDllLoadable -Path $Path } $PSCommandPath
    Assert-True -Condition (-not $scriptIsNotLoadable) -Message 'The safe native load probe must reject a non-library file.'

    $lockHandle = & $module { Enter-ScaleWorldPrerequisiteInstallLock -TimeoutSeconds 1 }
    try {
        Assert-True -Condition $lockHandle.Acquired -Message 'The prerequisite installer mutex must be acquirable by the update process.'
    } finally {
        & $module { param($Handle) Exit-ScaleWorldPrerequisiteInstallLock -Handle $Handle } $lockHandle
    }

    foreach ($case in @(
        @{ ExitCode = 0; Expected = 'verify' },
        @{ ExitCode = 1618; Expected = 'retry' },
        @{ ExitCode = 1638; Expected = 'verify' },
        @{ ExitCode = 1641; Expected = 'initiated_reboot' },
        @{ ExitCode = 3010; Expected = 'reboot_required' },
        @{ ExitCode = 1603; Expected = 'failed' }
    )) {
        $disposition = & $module { param($ExitCode) Get-ScaleWorldInstallerExitDisposition -ExitCode $ExitCode } $case.ExitCode
        Assert-Equal -Expected $case.Expected -Actual $disposition -Message "Unexpected installer disposition for exit code $($case.ExitCode)."
    }

    $timedOutProcess = [pscustomobject]@{
        Id = 4242
        ExitCode = 0
        WaitTimeouts = New-Object System.Collections.ArrayList
    }
    $timedOutProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param($TimeoutMilliseconds)
        [void]$this.WaitTimeouts.Add([int]$TimeoutMilliseconds)
        return $false
    }
    $timedOutProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    $timeoutResult = & $module {
        param($Process)
        Wait-ScaleWorldInstallerProcess -Process $Process -TimeoutMilliseconds 1234
    } $timedOutProcess
    Assert-True -Condition $timeoutResult.TimedOut -Message 'A vendor installer that misses its deadline must return a deterministic timeout result.'
    Assert-Equal -Expected 4242 -Actual $timeoutResult.ProcessId -Message 'Timeout diagnostics must preserve the monitored installer PID.'
    Assert-Equal -Expected 1234 -Actual $timedOutProcess.WaitTimeouts[0] -Message 'The installer wait helper must honor the configured deadline.'

    $completedProcess = [pscustomobject]@{
        Id = 4343
        ExitCode = 1638
    }
    $completedProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMilliseconds) return $true }
    $completedProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    $completedResult = & $module {
        param($Process)
        Wait-ScaleWorldInstallerProcess -Process $Process -TimeoutMilliseconds 1234
    } $completedProcess
    Assert-True -Condition (-not $completedResult.TimedOut) -Message 'A vendor installer that exits before its deadline must report completion.'
    Assert-Equal -Expected 1638 -Actual $completedResult.ExitCode -Message 'Completed installer monitoring must preserve the vendor exit code.'

    $differentArtifactPathBusy = & $module {
        Test-ScaleWorldVcRedistProcessInventory `
            -Processes @([pscustomobject]@{
                Name = 'vc_redist.x64.exe'
                ExecutablePath = 'D:\another-runtime-staging-root\vc_redist.x64.exe'
            }) `
            -InstallerFileName 'vc_redist.x64.exe'
    }
    Assert-True `
        -Condition $differentArtifactPathBusy `
        -Message 'A timed-out VC++ bootstrap from a different artifact path must block a duplicate installer launch.'

    $unrelatedInstallerBusy = & $module {
        Test-ScaleWorldVcRedistProcessInventory `
            -Processes @([pscustomobject]@{ Name = 'another-installer.exe' }) `
            -InstallerFileName 'vc_redist.x64.exe'
    }
    Assert-True `
        -Condition (-not $unrelatedInstallerBusy) `
        -Message 'An unrelated installer process must not be mistaken for the bundled VC++ bootstrap.'

    $contained = & $module {
        Test-ScaleWorldPathContained -RootPath 'C:\ScaleWorld\release' -CandidatePath 'C:\ScaleWorld\release\Engine\Extras\Redist\en-us\vc_redist.x64.exe'
    }
    Assert-True -Condition $contained -Message 'The canonical bundled installer path must be accepted below the release root.'

    $outside = & $module {
        Test-ScaleWorldPathContained -RootPath 'C:\ScaleWorld\release' -CandidatePath 'C:\ScaleWorld\release-escape\vc_redist.x64.exe'
    }
    Assert-True -Condition (-not $outside) -Message 'Prefix-adjacent paths must not pass release-root containment.'

    $reasonException = & $module {
        New-ScaleWorldPrerequisiteException -Code 'unreal_prerequisite_reboot_required' -Message 'test'
    }
    Assert-Equal `
        -Expected 'unreal_prerequisite_reboot_required' `
        -Actual ([string]$reasonException.Data['ScaleWorldUpdateResultReason']) `
        -Message 'Prerequisite exceptions must carry a stable update result reason.'

    $timeoutReasonException = & $module {
        New-ScaleWorldPrerequisiteException -Code 'unreal_prerequisite_install_timeout' -Message 'test'
    }
    Assert-Equal `
        -Expected 'unreal_prerequisite_install_timeout' `
        -Actual ([string]$timeoutReasonException.Data['ScaleWorldUpdateResultReason']) `
        -Message 'Installer timeout exceptions must carry a stable update result reason.'

    $exported = @(Get-Command -Module $module.Name | Select-Object -ExpandProperty Name)
    Assert-True -Condition ($exported -contains 'Get-ScaleWorldUnrealPrerequisiteStatus') -Message 'The prerequisite status command must be exported.'
    Assert-True -Condition ($exported -contains 'Install-ScaleWorldUnrealPrerequisite') -Message 'The supported updater install command must be exported.'
    Assert-True -Condition ($exported -contains 'Assert-ScaleWorldUnrealPrerequisite') -Message 'The check-only startup guard must be exported.'

    Write-Host 'Unreal prerequisite tests passed.' -ForegroundColor Green
} finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
}
