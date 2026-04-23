function Add-ScaleWorldUniqueString {
    param(
        [System.Collections.Generic.List[string]]$Values,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not ($Values -contains $Value)) {
        $Values.Add($Value) | Out-Null
    }
}

function Get-ScaleWorldProcessCreationUtcDateTime {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Process
    )

    $creationDate = [string]$Process.CreationDate
    if ([string]::IsNullOrWhiteSpace($creationDate)) {
        return $null
    }

    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($creationDate).ToUniversalTime()
    } catch {
        return $null
    }
}

function Normalize-ScaleWorldLikePattern {
    param([string]$Pattern)

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return $null
    }

    $trimmed = $Pattern.Trim()
    if ($trimmed.IndexOf('*') -ge 0 -or $trimmed.IndexOf('?') -ge 0 -or $trimmed.IndexOf('[') -ge 0) {
        return $trimmed
    }

    return ($trimmed + '*')
}

function Get-ScaleWorldRuntimeProcessMatcher {
    param(
        [string]$InstallRoot = $(if ($env:SCALEWORLD_INSTALL_ROOT) { $env:SCALEWORLD_INSTALL_ROOT } else { 'C:\PixelStreaming\WindowsNoEditor' }),
        [string]$ExecutableName = $(if ($env:SCALEWORLD_EXECUTABLE_NAME) { $env:SCALEWORLD_EXECUTABLE_NAME } else { 'ScaleWorld.exe' }),
        [string]$RuntimeProcessPattern = $(if ($env:SCALEWORLD_RUNTIME_PROCESS_PATTERN) { $env:SCALEWORLD_RUNTIME_PROCESS_PATTERN } else { '' }),
        [bool]$IncludeLauncherExecutable = $true
    )

    $resolvedInstallRoot = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        'C:\PixelStreaming\WindowsNoEditor'
    } else {
        $InstallRoot.Trim()
    }

    try {
        $resolvedInstallRoot = [System.IO.Path]::GetFullPath($resolvedInstallRoot)
    } catch {
        # Keep the raw install root when it cannot be normalized.
    }

    $installRootPrefix = $resolvedInstallRoot.TrimEnd('\')
    if ($installRootPrefix.Length -gt 0) {
        $installRootPrefix += '\'
    }

    $resolvedExecutableName = if ([string]::IsNullOrWhiteSpace($ExecutableName)) {
        'ScaleWorld.exe'
    } else {
        [System.IO.Path]::GetFileName($ExecutableName.Trim())
    }
    $resolvedBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedExecutableName)

    $namePatterns = [System.Collections.Generic.List[string]]::new()
    Add-ScaleWorldUniqueString -Values $namePatterns -Value (Normalize-ScaleWorldLikePattern -Pattern $RuntimeProcessPattern)
    if ($IncludeLauncherExecutable) {
        Add-ScaleWorldUniqueString -Values $namePatterns -Value (Normalize-ScaleWorldLikePattern -Pattern $resolvedBaseName)
    }
    Add-ScaleWorldUniqueString -Values $namePatterns -Value (Normalize-ScaleWorldLikePattern -Pattern ($resolvedBaseName + '-Win64-*'))
    Add-ScaleWorldUniqueString -Values $namePatterns -Value (Normalize-ScaleWorldLikePattern -Pattern ($resolvedBaseName + '-Win64-Shipping'))

    $commandLinePatterns = [System.Collections.Generic.List[string]]::new()
    if ($IncludeLauncherExecutable) {
        Add-ScaleWorldUniqueString -Values $commandLinePatterns -Value ('*' + $resolvedExecutableName + '*')
    }
    Add-ScaleWorldUniqueString -Values $commandLinePatterns -Value ('*' + $resolvedBaseName + '-Win64-*')
    Add-ScaleWorldUniqueString -Values $commandLinePatterns -Value ('*' + $resolvedBaseName + '-Win64-Shipping*')

    return [pscustomobject]@{
        InstallRoot         = $resolvedInstallRoot
        InstallRootPrefix   = $installRootPrefix
        ExecutableName      = $resolvedExecutableName
        BaseName            = $resolvedBaseName
        NamePatterns        = $namePatterns.ToArray()
        CommandLinePatterns = $commandLinePatterns.ToArray()
    }
}

function Test-ScaleWorldRuntimeProcessMatch {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Process,
        [Parameter(Mandatory = $true)]
        [object]$Matcher,
        [string[]]$AdditionalCommandLinePatterns = @()
    )

    $processName = [string]$Process.Name
    foreach ($pattern in @($Matcher.NamePatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $processName -like $pattern) {
            return $true
        }
    }

    $commandLine = [string]$Process.CommandLine
    foreach ($pattern in @($Matcher.CommandLinePatterns) + @($AdditionalCommandLinePatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $commandLine -like $pattern) {
            return $true
        }
    }

    $executablePath = [string]$Process.ExecutablePath
    if (
        -not [string]::IsNullOrWhiteSpace($Matcher.InstallRootPrefix) -and
        -not [string]::IsNullOrWhiteSpace($executablePath) -and
        $executablePath.StartsWith($Matcher.InstallRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        $executableBaseName = [System.IO.Path]::GetFileNameWithoutExtension($executablePath)
        foreach ($pattern in @($Matcher.NamePatterns)) {
            if (-not [string]::IsNullOrWhiteSpace($pattern) -and $executableBaseName -like $pattern) {
                return $true
            }
        }
    }

    return $false
}

function Get-ScaleWorldRuntimeProcesses {
    param(
        [int[]]$ExcludeProcessIds = @(),
        [string[]]$AdditionalCommandLinePatterns = @(),
        [object]$Matcher = $(Get-ScaleWorldRuntimeProcessMatcher)
    )

    $excludeLookup = @{}
    foreach ($processId in @($ExcludeProcessIds)) {
        if ($processId -gt 0) {
            $excludeLookup[[int]$processId] = $true
        }
    }

    return @(
        Get-CimInstance Win32_Process | Where-Object {
            if ($excludeLookup.ContainsKey([int]$_.ProcessId)) {
                return $false
            }

            return Test-ScaleWorldRuntimeProcessMatch -Process $_ -Matcher $Matcher -AdditionalCommandLinePatterns $AdditionalCommandLinePatterns
        }
    )
}
