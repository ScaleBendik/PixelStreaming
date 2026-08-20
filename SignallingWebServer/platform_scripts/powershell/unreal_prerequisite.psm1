Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BundledVcRedistRelativePath = 'Engine\Extras\Redist\en-us\vc_redist.x64.exe'
$script:PrerequisiteResultReasonDataKey = 'ScaleWorldUpdateResultReason'

function New-ScaleWorldPrerequisiteException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException("${Code}: $Message")
    $exception.Data[$script:PrerequisiteResultReasonDataKey] = $Code
    return $exception
}

function Throw-ScaleWorldPrerequisiteError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw (New-ScaleWorldPrerequisiteException -Code $Code -Message $Message)
}

function ConvertTo-ScaleWorldPrerequisiteVersion {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $match = [regex]::Match($text, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) {
        return $null
    }

    $revision = if ($match.Groups[4].Success) { $match.Groups[4].Value } else { '0' }
    try {
        return [System.Version]("{0}.{1}.{2}.{3}" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value, $revision)
    } catch {
        return $null
    }
}

function Assert-ScaleWorldPrerequisiteProcessArchitecture {
    param(
        [bool]$Is64BitProcess = [Environment]::Is64BitProcess
    )

    if (-not $Is64BitProcess) {
        Throw-ScaleWorldPrerequisiteError `
            -Code 'unreal_prerequisite_64bit_powershell_required' `
            -Message 'Unreal x64 prerequisite verification must run from 64-bit Windows PowerShell. Update the launcher to use the native System32 PowerShell host rather than SysWOW64.'
    }
}

function Resolve-ScaleWorldFileSystemDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_root_missing' -Message "Unreal root '$Path' was not found."
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop | Select-Object -First 1
    if ($resolved.Provider.Name -ne 'FileSystem' -or [string]::IsNullOrWhiteSpace($resolved.ProviderPath)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_root_missing' -Message "Unreal root '$Path' is not a filesystem directory."
    }

    return [System.IO.Path]::GetFullPath($resolved.ProviderPath)
}

function Test-ScaleWorldPathContained {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($RootPath)
    $candidateFullPath = [System.IO.Path]::GetFullPath($CandidatePath)
    $rootPrefix = $rootFullPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    return $candidateFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ScaleWorldPathHasNoReparsePointBelowRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [string]$FailureCode,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $current = $RootPath
    foreach ($segment in ($RelativePath -split '[\\/]')) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            return
        }

        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-ScaleWorldPrerequisiteError -Code $FailureCode -Message "$Label contains a reparse point below the Unreal root ('$segment')."
        }
    }
}

function Get-ScaleWorldBundledVcRedistPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UnrealRoot
    )

    $resolvedRoot = Resolve-ScaleWorldFileSystemDirectory -Path $UnrealRoot
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $script:BundledVcRedistRelativePath))
    if (-not (Test-ScaleWorldPathContained -RootPath $resolvedRoot -CandidatePath $candidate)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_installer_outside_root' -Message 'The bundled Visual C++ installer path escaped the Unreal root.'
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_installer_missing' -Message "The bundled Visual C++ installer '$script:BundledVcRedistRelativePath' was not found below the Unreal root."
    }

    Assert-ScaleWorldPathHasNoReparsePointBelowRoot `
        -RootPath $resolvedRoot `
        -RelativePath $script:BundledVcRedistRelativePath `
        -FailureCode 'unreal_prerequisite_installer_path_unsafe' `
        -Label 'The bundled Visual C++ installer path'

    $resolvedInstaller = Resolve-Path -LiteralPath $candidate -ErrorAction Stop | Select-Object -First 1
    $resolvedInstallerPath = [System.IO.Path]::GetFullPath($resolvedInstaller.ProviderPath)
    if (-not (Test-ScaleWorldPathContained -RootPath $resolvedRoot -CandidatePath $resolvedInstallerPath)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_installer_outside_root' -Message 'The resolved bundled Visual C++ installer path escaped the Unreal root.'
    }

    return [pscustomobject]@{
        UnrealRoot = $resolvedRoot
        InstallerPath = $resolvedInstallerPath
    }
}

function Get-ScaleWorldPackagedTargetDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UnrealRoot,
        [Parameter(Mandatory = $true)]
        [string]$LauncherExecutableName
    )

    $leafName = [System.IO.Path]::GetFileName($LauncherExecutableName)
    if ([string]::IsNullOrWhiteSpace($leafName) -or
        -not [string]::Equals($leafName, $LauncherExecutableName, [System.StringComparison]::Ordinal) -or
        -not $leafName.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_target_invalid' -Message "Launcher executable name '$LauncherExecutableName' is not a safe executable leaf name."
    }

    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($leafName)
    $relativeTargetPath = Join-Path (Join-Path (Join-Path $projectName 'Binaries') 'Win64') ("{0}-Win64-Shipping.exe" -f $projectName)
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $UnrealRoot $relativeTargetPath))
    if (-not (Test-ScaleWorldPathContained -RootPath $UnrealRoot -CandidatePath $targetPath)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_target_invalid' -Message 'The packaged Shipping executable path escaped the Unreal root.'
    }

    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        return ''
    }

    Assert-ScaleWorldPathHasNoReparsePointBelowRoot `
        -RootPath $UnrealRoot `
        -RelativePath $relativeTargetPath `
        -FailureCode 'unreal_prerequisite_target_invalid' `
        -Label 'The packaged Shipping executable path'

    $resolvedTarget = Resolve-Path -LiteralPath $targetPath -ErrorAction Stop | Select-Object -First 1
    $resolvedTargetPath = [System.IO.Path]::GetFullPath($resolvedTarget.ProviderPath)
    if (-not (Test-ScaleWorldPathContained -RootPath $UnrealRoot -CandidatePath $resolvedTargetPath)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_target_invalid' -Message 'The resolved packaged Shipping executable path escaped the Unreal root.'
    }

    return Split-Path -Parent $resolvedTargetPath
}

function Get-ScaleWorldBundledVcRedistMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    $signature = Get-AuthenticodeSignature -FilePath $InstallerPath -ErrorAction Stop
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_signature_invalid' -Message "The bundled Visual C++ installer does not have a valid Authenticode signature (status=$($signature.Status))."
    }

    if ($null -eq $signature.SignerCertificate) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_signer_invalid' -Message 'The bundled Visual C++ installer did not expose a signing certificate.'
    }

    $signer = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if (-not [string]::Equals($signer, 'Microsoft Corporation', [System.StringComparison]::Ordinal)) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_signer_invalid' -Message "The bundled Visual C++ installer signer '$signer' is not Microsoft Corporation."
    }

    $file = Get-Item -LiteralPath $InstallerPath -Force -ErrorAction Stop
    $requiredVersion = ConvertTo-ScaleWorldPrerequisiteVersion -Value $file.VersionInfo.ProductVersion
    if ($null -eq $requiredVersion) {
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_version_invalid' -Message 'The bundled Visual C++ installer ProductVersion could not be parsed.'
    }

    return [pscustomobject]@{
        InstallerPath = $InstallerPath
        RequiredVersion = $requiredVersion
        Signer = $signer
    }
}

function Get-ScaleWorldRegistryVcRuntimeVersion {
    $versions = New-Object System.Collections.Generic.List[System.Version]
    # The packaged bootstrap is a 64-bit executable and reads the native x64
    # runtime key. Query that registry view explicitly even if a caller happens
    # to launch this module from a 32-bit PowerShell host.
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64)) {
        $baseKey = $null
        $runtimeKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $runtimeKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', $false)
            if ($null -eq $runtimeKey) {
                continue
            }

            $installedValue = $runtimeKey.GetValue('Installed', 0)
            if ([int]$installedValue -ne 1) {
                continue
            }

            # Unreal reads these numeric values. Prefer them over the display
            # Version string so a stale/inconsistent string cannot false-pass.
            $major = $runtimeKey.GetValue('Major', $null)
            $minor = $runtimeKey.GetValue('Minor', $null)
            $build = $runtimeKey.GetValue('Bld', $null)
            $revision = $runtimeKey.GetValue('Rbld', 0)
            $version = $null
            if ($null -ne $major -and $null -ne $minor -and $null -ne $build) {
                $version = ConvertTo-ScaleWorldPrerequisiteVersion -Value ("{0}.{1}.{2}.{3}" -f $major, $minor, $build, $revision)
            }

            if ($null -ne $version) {
                $versions.Add($version)
            }
        } catch {
            # A missing registry view/key is an unsatisfied observation, not a fatal probe failure.
        } finally {
            if ($null -ne $runtimeKey) {
                $runtimeKey.Dispose()
            }
            if ($null -ne $baseKey) {
                $baseKey.Dispose()
            }
        }
    }

    if ($versions.Count -eq 0) {
        return $null
    }

    return $versions | Sort-Object -Descending | Select-Object -First 1
}

function Get-ScaleWorldRuntimeDllVersionFromVersionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [object]$VersionInfo
    )

    # BootstrapPackagedGame reads VS_FIXEDFILEINFO (FileVersion), not the
    # localized ProductVersion string. Missing or malformed fixed metadata must
    # fail closed because ProductVersion cannot satisfy the engine's check.
    return ConvertTo-ScaleWorldPrerequisiteVersion -Value $VersionInfo.FileVersion
}

function Get-ScaleWorldRuntimeDllVersionAtPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return Get-ScaleWorldRuntimeDllVersionFromVersionInfo -VersionInfo $file.VersionInfo
    } catch {
        return $null
    }
}

function Initialize-ScaleWorldNativeLibraryProbe {
    if ('ScaleWorld.Runtime.NativeLibraryProbe' -as [type]) {
        return
    }

    $source = @'
using System;
using System.Runtime.InteropServices;

namespace ScaleWorld.Runtime
{
    public static class NativeLibraryProbe
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryExW(string fileName, IntPtr fileHandle, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FreeLibrary(IntPtr moduleHandle);
    }
}
'@

    [void](Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop)
}

function Test-ScaleWorldRuntimeDllLoadable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [Environment]::Is64BitProcess -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $handle = [IntPtr]::Zero
    try {
        Initialize-ScaleWorldNativeLibraryProbe
        # Resolve dependencies only beside the probed DLL or from System32. This
        # proves that the x64 PE can load without enabling the current-directory
        # or PATH search locations that the prerequisite check is meant to avoid.
        $loadLibrarySearchDllLoadDir = [uint32]0x00000100
        $loadLibrarySearchSystem32 = [uint32]0x00000800
        $flags = $loadLibrarySearchDllLoadDir -bor $loadLibrarySearchSystem32
        $handle = [ScaleWorld.Runtime.NativeLibraryProbe]::LoadLibraryExW($Path, [IntPtr]::Zero, $flags)
        return $handle -ne [IntPtr]::Zero
    } catch {
        return $false
    } finally {
        if ($handle -ne [IntPtr]::Zero) {
            [void][ScaleWorld.Runtime.NativeLibraryProbe]::FreeLibrary($handle)
        }
    }
}

function Get-ScaleWorldRuntimeDllObservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [pscustomobject]@{
        Path = $Path
        Version = Get-ScaleWorldRuntimeDllVersionAtPath -Path $Path
        Loadable = Test-ScaleWorldRuntimeDllLoadable -Path $Path
    }
}

function Get-ScaleWorldSystemRuntimeDllObservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $windowsRoot = [Environment]::GetEnvironmentVariable('WINDIR')
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
        $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    }

    if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
        return [pscustomobject]@{
            Path = ''
            Version = $null
            Loadable = $false
        }
    }

    return Get-ScaleWorldRuntimeDllObservation -Path (Join-Path (Join-Path $windowsRoot 'System32') $FileName)
}

function Test-ScaleWorldHostRuntimeState {
    param(
        [Parameter(Mandatory = $true)]
        [System.Version]$RequiredVersion,
        [AllowNull()][System.Version]$RegistryVersion,
        [AllowNull()][System.Version]$Msvcp1402Version,
        [AllowNull()][System.Version]$Vcruntime1401Version,
        [AllowNull()][System.Version]$AppLocalMsvcp1402Version,
        [AllowNull()][System.Version]$AppLocalVcruntime1401Version,
        [bool]$Msvcp1402Loadable = $false,
        [bool]$Vcruntime1401Loadable = $false,
        [bool]$AppLocalMsvcp1402Loadable = $false,
        [bool]$AppLocalVcruntime1401Loadable = $false
    )

    $systemMissing = New-Object System.Collections.Generic.List[string]
    $systemVersions = New-Object System.Collections.Generic.List[System.Version]

    foreach ($entry in @(
        [pscustomobject]@{ Name = 'registry_x64'; Version = $RegistryVersion; RequiresLoad = $false; Loadable = $true },
        [pscustomobject]@{ Name = 'msvcp140_2.dll'; Version = $Msvcp1402Version; RequiresLoad = $true; Loadable = $Msvcp1402Loadable },
        [pscustomobject]@{ Name = 'vcruntime140_1.dll'; Version = $Vcruntime1401Version; RequiresLoad = $true; Loadable = $Vcruntime1401Loadable }
    )) {
        if ($null -eq $entry.Version -or $entry.Version -lt $RequiredVersion) {
            $systemMissing.Add("system/$($entry.Name)")
        } elseif ($entry.RequiresLoad -and -not $entry.Loadable) {
            $systemMissing.Add("system/$($entry.Name)_unloadable")
        }
        if ($null -ne $entry.Version) {
            $systemVersions.Add($entry.Version)
        }
    }

    $appLocalMissing = New-Object System.Collections.Generic.List[string]
    $appLocalVersions = New-Object System.Collections.Generic.List[System.Version]
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'msvcp140_2.dll'; Version = $AppLocalMsvcp1402Version; Loadable = $AppLocalMsvcp1402Loadable },
        [pscustomobject]@{ Name = 'vcruntime140_1.dll'; Version = $AppLocalVcruntime1401Version; Loadable = $AppLocalVcruntime1401Loadable }
    )) {
        if ($null -eq $entry.Version -or $entry.Version -lt $RequiredVersion) {
            $appLocalMissing.Add("app_local/$($entry.Name)")
        } elseif (-not $entry.Loadable) {
            $appLocalMissing.Add("app_local/$($entry.Name)_unloadable")
        }
        if ($null -ne $entry.Version) {
            $appLocalVersions.Add($entry.Version)
        }
    }

    $systemSatisfied = ($systemMissing.Count -eq 0)
    $appLocalSatisfied = ($appLocalMissing.Count -eq 0)
    $systemEffectiveVersion = if ($systemVersions.Count -gt 0) {
        $systemVersions | Sort-Object | Select-Object -First 1
    } else {
        $null
    }
    $appLocalEffectiveVersion = if ($appLocalVersions.Count -gt 0) {
        $appLocalVersions | Sort-Object | Select-Object -First 1
    } else {
        $null
    }
    $effectiveVersion = if ($appLocalSatisfied) {
        $appLocalEffectiveVersion
    } elseif ($systemSatisfied) {
        $systemEffectiveVersion
    } else {
        @($appLocalEffectiveVersion, $systemEffectiveVersion) |
            Where-Object { $null -ne $_ } |
            Sort-Object -Descending |
            Select-Object -First 1
    }
    $missing = if ($appLocalSatisfied -or $systemSatisfied) {
        @()
    } else {
        @($appLocalMissing) + @($systemMissing)
    }

    return [pscustomobject]@{
        Satisfied = ($appLocalSatisfied -or $systemSatisfied)
        Missing = @($missing)
        InstalledVersion = $effectiveVersion
        AppLocalSatisfied = $appLocalSatisfied
        SystemSatisfied = $systemSatisfied
        AppLocalInstalledVersion = $appLocalEffectiveVersion
        SystemInstalledVersion = $systemEffectiveVersion
    }
}

function Get-ScaleWorldUnrealPrerequisiteStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UnrealRoot,
        [string]$LauncherExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' })
    )

    Assert-ScaleWorldPrerequisiteProcessArchitecture
    $pathInfo = Get-ScaleWorldBundledVcRedistPath -UnrealRoot $UnrealRoot
    $installer = Get-ScaleWorldBundledVcRedistMetadata -InstallerPath $pathInfo.InstallerPath
    $registryVersion = Get-ScaleWorldRegistryVcRuntimeVersion
    $msvcp1402 = Get-ScaleWorldSystemRuntimeDllObservation -FileName 'msvcp140_2.dll'
    $vcruntime1401 = Get-ScaleWorldSystemRuntimeDllObservation -FileName 'vcruntime140_1.dll'
    $packagedTargetDirectory = Get-ScaleWorldPackagedTargetDirectory -UnrealRoot $pathInfo.UnrealRoot -LauncherExecutableName $LauncherExecutableName
    $appLocalMsvcp1402 = if ([string]::IsNullOrWhiteSpace($packagedTargetDirectory)) {
        [pscustomobject]@{ Path = ''; Version = $null; Loadable = $false }
    } else {
        Get-ScaleWorldRuntimeDllObservation -Path (Join-Path $packagedTargetDirectory 'msvcp140_2.dll')
    }
    $appLocalVcruntime1401 = if ([string]::IsNullOrWhiteSpace($packagedTargetDirectory)) {
        [pscustomobject]@{ Path = ''; Version = $null; Loadable = $false }
    } else {
        Get-ScaleWorldRuntimeDllObservation -Path (Join-Path $packagedTargetDirectory 'vcruntime140_1.dll')
    }
    $hostState = Test-ScaleWorldHostRuntimeState `
        -RequiredVersion $installer.RequiredVersion `
        -RegistryVersion $registryVersion `
        -Msvcp1402Version $msvcp1402.Version `
        -Vcruntime1401Version $vcruntime1401.Version `
        -AppLocalMsvcp1402Version $appLocalMsvcp1402.Version `
        -AppLocalVcruntime1401Version $appLocalVcruntime1401.Version `
        -Msvcp1402Loadable $msvcp1402.Loadable `
        -Vcruntime1401Loadable $vcruntime1401.Loadable `
        -AppLocalMsvcp1402Loadable $appLocalMsvcp1402.Loadable `
        -AppLocalVcruntime1401Loadable $appLocalVcruntime1401.Loadable

    return [pscustomobject]@{
        Applicable = $true
        State = if ($hostState.Satisfied) { 'satisfied' } else { 'installation_required' }
        UnrealRoot = $pathInfo.UnrealRoot
        InstallerPath = $installer.InstallerPath
        RequiredVersion = $installer.RequiredVersion
        InstalledVersion = $hostState.InstalledVersion
        RegistryVersion = $registryVersion
        Msvcp1402Version = $msvcp1402.Version
        Vcruntime1401Version = $vcruntime1401.Version
        AppLocalMsvcp1402Version = $appLocalMsvcp1402.Version
        AppLocalVcruntime1401Version = $appLocalVcruntime1401.Version
        Msvcp1402Loadable = $msvcp1402.Loadable
        Vcruntime1401Loadable = $vcruntime1401.Loadable
        AppLocalMsvcp1402Loadable = $appLocalMsvcp1402.Loadable
        AppLocalVcruntime1401Loadable = $appLocalVcruntime1401.Loadable
        AppLocalSatisfied = $hostState.AppLocalSatisfied
        SystemSatisfied = $hostState.SystemSatisfied
        PackagedTargetDirectory = $packagedTargetDirectory
        Missing = @($hostState.Missing)
        Satisfied = $hostState.Satisfied
        Signer = $installer.Signer
    }
}

function Get-ScaleWorldInstallerExitDisposition {
    param([int]$ExitCode)

    switch ($ExitCode) {
        0 { return 'verify' }
        1618 { return 'retry' }
        1638 { return 'verify' }
        1641 { return 'initiated_reboot' }
        3010 { return 'reboot_required' }
        default { return 'failed' }
    }
}

function Enter-ScaleWorldPrerequisiteInstallLock {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, 'Global\ScaleWorldUnrealPrerequisiteInstall', [ref]$createdNew)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    } catch {
        $mutex.Dispose()
        throw
    }

    if (-not $acquired) {
        $mutex.Dispose()
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_install_lock_timeout' -Message "Timed out after $TimeoutSeconds seconds waiting for the prerequisite installation lock."
    }

    return [pscustomobject]@{
        Mutex = $mutex
        Acquired = $true
    }
}

function Exit-ScaleWorldPrerequisiteInstallLock {
    param([AllowNull()][object]$Handle)

    if ($null -eq $Handle -or $null -eq $Handle.Mutex) {
        return
    }

    try {
        if ($Handle.Acquired) {
            $Handle.Mutex.ReleaseMutex()
        }
    } catch {
        # Do not replace the prerequisite result with cleanup-only mutex errors.
    } finally {
        try {
            $Handle.Mutex.Dispose()
        } catch {
        }
    }
}

function Invoke-ScaleWorldVcRedistProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds
    )

    $process = $null
    try {
        $process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList @('/install', '/quiet', '/norestart') `
            -WorkingDirectory (Split-Path -Parent $InstallerPath) `
            -WindowStyle Hidden `
            -PassThru

        return Wait-ScaleWorldInstallerProcess -Process $process -TimeoutMilliseconds ($TimeoutSeconds * 1000)
    } finally {
        if ($null -ne $process) {
            try {
                # Disposing the monitoring handle does not terminate the vendor
                # bootstrap or any Windows Installer work it owns.
                $process.Dispose()
            } catch {
            }
        }
    }
}

function Wait-ScaleWorldInstallerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Process,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 7200000)]
        [int]$TimeoutMilliseconds
    )

    $processId = [int]$Process.Id
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        return [pscustomobject]@{
            TimedOut = $true
            ProcessId = $processId
            ExitCode = $null
        }
    }

    try {
        $Process.Refresh()
    } catch {
    }

    return [pscustomobject]@{
        TimedOut = $false
        ProcessId = $processId
        ExitCode = [int]$Process.ExitCode
    }
}

function Test-ScaleWorldVcRedistProcessRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    $fileName = [System.IO.Path]::GetFileName($InstallerPath)
    $escapedFileName = $fileName.Replace("'", "''")
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter ("Name = '{0}'" -f $escapedFileName) -ErrorAction Stop)
        return Test-ScaleWorldVcRedistProcessInventory `
            -Processes $processes `
            -InstallerFileName $fileName
    } catch {
        # Windows Installer remains the final serialization authority and will
        # return 1618 if process inspection is unavailable or incomplete.
    }

    return $false
}

function Test-ScaleWorldVcRedistProcessInventory {
    param(
        [AllowNull()][object[]]$Processes,
        [Parameter(Mandatory = $true)]
        [string]$InstallerFileName
    )

    foreach ($process in @($Processes)) {
        $nameProperty = $process.PSObject.Properties['Name']
        if ($null -ne $nameProperty -and
            [string]::Equals([string]$nameProperty.Value, $InstallerFileName, [System.StringComparison]::OrdinalIgnoreCase)) {
            # Deliberately ignore ExecutablePath: a previous timed-out update
            # can leave the same signed bootstrap running from another staged
            # artifact path. Starting a second copy would overlap it blindly.
            return $true
        }
    }

    return $false
}

function Test-ScaleWorldInstallerElevationFailure {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.UnauthorizedAccessException]) {
            return $true
        }

        $nativeErrorProperty = $exception.PSObject.Properties['NativeErrorCode']
        if ($nativeErrorProperty -and [int]$nativeErrorProperty.Value -in @(5, 740)) {
            return $true
        }

        $nativeHResult = ([int64]$exception.HResult) -band 0xFFFF
        if ($nativeHResult -in @(5, 740)) {
            return $true
        }

        $exception = $exception.InnerException
    }

    return $false
}

function Test-ScaleWorldProcessElevated {
    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    } finally {
        if ($null -ne $identity) {
            $identity.Dispose()
        }
    }
}

function Install-ScaleWorldUnrealPrerequisite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UnrealRoot,
        [string]$LauncherExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
        [ValidateRange(1, 3600)]
        [int]$LockTimeoutSeconds = 300,
        [ValidateRange(0, 10)]
        [int]$InstallBusyRetryCount = 3,
        [ValidateRange(1, 300)]
        [int]$InstallBusyRetryDelaySeconds = 15,
        [ValidateRange(1, 7200)]
        [int]$InstallProcessTimeoutSeconds = $(if ($env:SCALEWORLD_UNREAL_PREREQUISITE_INSTALL_TIMEOUT_SECONDS) { [int]$env:SCALEWORLD_UNREAL_PREREQUISITE_INSTALL_TIMEOUT_SECONDS } else { 900 })
    )

    $lockHandle = $null
    try {
        $lockHandle = Enter-ScaleWorldPrerequisiteInstallLock -TimeoutSeconds $LockTimeoutSeconds
        $status = Get-ScaleWorldUnrealPrerequisiteStatus -UnrealRoot $UnrealRoot -LauncherExecutableName $LauncherExecutableName
        if (-not $status.Applicable -or $status.Satisfied) {
            return [pscustomobject]@{
                Outcome = 'already_satisfied'
                InstallerExitCode = $null
                Status = $status
            }
        }

        if (-not (Test-ScaleWorldProcessElevated)) {
            Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_elevation_required' -Message 'The signed bundled Visual C++ installer requires an elevated update process; no installer was launched.'
        }

        $exitCode = $null
        $attempts = $InstallBusyRetryCount + 1
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            try {
                if (Test-ScaleWorldVcRedistProcessRunning -InstallerPath $status.InstallerPath) {
                    $exitCode = 1618
                } else {
                    $execution = Invoke-ScaleWorldVcRedistProcess `
                        -InstallerPath $status.InstallerPath `
                        -TimeoutSeconds $InstallProcessTimeoutSeconds
                    if ($execution.TimedOut) {
                        Throw-ScaleWorldPrerequisiteError `
                            -Code 'unreal_prerequisite_install_timeout' `
                            -Message "The signed bundled Visual C++ installer process $($execution.ProcessId) did not exit within $InstallProcessTimeoutSeconds seconds. It was left running; no overlapping installer was started."
                    }
                    $exitCode = [int]$execution.ExitCode
                }
            } catch {
                if ($_.Exception.Data.Contains($script:PrerequisiteResultReasonDataKey)) {
                    throw
                }
                if (Test-ScaleWorldInstallerElevationFailure -ErrorRecord $_) {
                    Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_elevation_required' -Message 'The signed bundled Visual C++ installer requires an elevated update process.'
                }

                Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_install_failed' -Message "The signed bundled Visual C++ installer could not be started or monitored. $($_.Exception.Message)"
            }
            $disposition = Get-ScaleWorldInstallerExitDisposition -ExitCode $exitCode
            if ($disposition -ne 'retry') {
                break
            }

            if ($attempt -lt $attempts) {
                Start-Sleep -Seconds $InstallBusyRetryDelaySeconds
            }
        }

        $disposition = Get-ScaleWorldInstallerExitDisposition -ExitCode $exitCode
        switch ($disposition) {
            'retry' {
                Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_install_busy' -Message "The Visual C++ installer remained busy after $attempts attempts (exit code 1618)."
            }
            'reboot_required' {
                Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_reboot_required' -Message 'The Visual C++ installer completed with exit code 3010 and requires a reboot; activation was not attempted.'
            }
            'initiated_reboot' {
                Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_installer_initiated_reboot' -Message 'The Visual C++ installer returned exit code 1641 despite /norestart; activation was not attempted.'
            }
            'failed' {
                Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_install_failed' -Message "The Visual C++ installer failed with exit code $exitCode."
            }
        }

        $verified = Get-ScaleWorldUnrealPrerequisiteStatus -UnrealRoot $UnrealRoot -LauncherExecutableName $LauncherExecutableName
        if (-not $verified.Applicable -or -not $verified.Satisfied) {
            $required = if ($verified.RequiredVersion) { [string]$verified.RequiredVersion } else { 'unknown' }
            $installed = if ($verified.InstalledVersion) { [string]$verified.InstalledVersion } else { 'missing' }
            Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_verification_failed' -Message "Visual C++ prerequisite verification failed after installer exit code $exitCode (required=$required, observed=$installed)."
        }

        return [pscustomobject]@{
            Outcome = if ($exitCode -eq 1638) { 'newer_runtime_verified' } else { 'installed_and_verified' }
            InstallerExitCode = $exitCode
            Status = $verified
        }
    } finally {
        Exit-ScaleWorldPrerequisiteInstallLock -Handle $lockHandle
    }
}

function Assert-ScaleWorldUnrealPrerequisite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UnrealRoot,
        [string]$LauncherExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' })
    )

    $status = Get-ScaleWorldUnrealPrerequisiteStatus -UnrealRoot $UnrealRoot -LauncherExecutableName $LauncherExecutableName
    if ($status.Applicable -and -not $status.Satisfied) {
        $required = [string]$status.RequiredVersion
        $installed = if ($status.InstalledVersion) { [string]$status.InstalledVersion } else { 'missing' }
        $missing = (@($status.Missing) -join ',')
        Throw-ScaleWorldPrerequisiteError -Code 'unreal_prerequisite_not_satisfied' -Message "Visual C++ runtime $required is required but the effective host version is $installed (missing_or_old=$missing). Run the supported update prerequisite preflight before startup."
    }

    return $status
}

Export-ModuleMember -Function @(
    'Get-ScaleWorldUnrealPrerequisiteStatus',
    'Install-ScaleWorldUnrealPrerequisite',
    'Assert-ScaleWorldUnrealPrerequisite'
)
