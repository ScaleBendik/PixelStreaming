Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ScaleWorldRequiredStateProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "webrtc_port_bank_state_invalid: Required property '$Name' is missing."
    }

    return $property.Value
}

function Open-ScaleWorldPortBankLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            return [System.IO.FileStream]::new(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 100
        }
    }

    throw "webrtc_port_bank_lock_timeout: Could not acquire '$LockPath' within $TimeoutSeconds seconds. Last error: $lastError"
}

function Move-ScaleWorldFileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if ($null -eq ('ScaleWorld.NativeFileOperations' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ScaleWorld
{
    public static class NativeFileOperations
    {
        private const int MoveFileReplaceExisting = 0x1;
        private const int MoveFileWriteThrough = 0x8;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(
            string existingFileName,
            string newFileName,
            int flags);

        public static void ReplaceAtomically(string sourcePath, string destinationPath)
        {
            if (!MoveFileEx(
                sourcePath,
                destinationPath,
                MoveFileReplaceExisting | MoveFileWriteThrough))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@ -ErrorAction Stop
    }

    [ScaleWorld.NativeFileOperations]::ReplaceAtomically($SourcePath, $DestinationPath)
}

function Write-ScaleWorldPortBankStateAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $serialized = $State | ConvertTo-Json -Depth 8
    $temporaryPath = '{0}.{1}.{2}.tmp' -f $StatePath, $PID, ([Guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $bytes = $utf8NoBom.GetBytes($serialized)
        $stream = [System.IO.FileStream]::new(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        Move-ScaleWorldFileAtomically -SourcePath $temporaryPath -DestinationPath $StatePath
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    $persisted = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (
        [int](Get-ScaleWorldRequiredStateProperty -State $persisted -Name 'schemaVersion') -ne 1 -or
        [long](Get-ScaleWorldRequiredStateProperty -State $persisted -Name 'generation') -ne [long]$State.generation -or
        [int](Get-ScaleWorldRequiredStateProperty -State $persisted -Name 'lastBankIndex') -ne [int]$State.lastBankIndex
    ) {
        throw "webrtc_port_bank_state_verification_failed: '$StatePath' did not pass post-write verification."
    }
}

function Read-ScaleWorldPortBankState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [Parameter(Mandatory = $true)]
        [int]$RangeMin,
        [Parameter(Mandatory = $true)]
        [int]$RangeMax,
        [Parameter(Mandatory = $true)]
        [int]$BankSize,
        [Parameter(Mandatory = $true)]
        [int]$BankCount
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'The state file is empty.'
        }
        $state = $raw | ConvertFrom-Json -ErrorAction Stop

        $schemaVersion = [int](Get-ScaleWorldRequiredStateProperty -State $state -Name 'schemaVersion')
        $storedRangeMin = [int](Get-ScaleWorldRequiredStateProperty -State $state -Name 'rangeMin')
        $storedRangeMax = [int](Get-ScaleWorldRequiredStateProperty -State $state -Name 'rangeMax')
        $storedBankSize = [int](Get-ScaleWorldRequiredStateProperty -State $state -Name 'bankSize')
        $storedBankCount = [int](Get-ScaleWorldRequiredStateProperty -State $state -Name 'bankCount')
        $generation = [long](Get-ScaleWorldRequiredStateProperty -State $state -Name 'generation')
        $lastBankIndex = [int](Get-ScaleWorldRequiredStateProperty -State $state -Name 'lastBankIndex')
        $historyProperty = $state.PSObject.Properties['history']

        if ($schemaVersion -ne 1) {
            throw "Unsupported schemaVersion '$schemaVersion'."
        }
        if (
            $storedRangeMin -ne $RangeMin -or
            $storedRangeMax -ne $RangeMax -or
            $storedBankSize -ne $BankSize -or
            $storedBankCount -ne $BankCount
        ) {
            throw "webrtc_port_bank_state_configuration_mismatch: Persisted range=$storedRangeMin-$storedRangeMax bankSize=$storedBankSize bankCount=$storedBankCount; requested range=$RangeMin-$RangeMax bankSize=$BankSize bankCount=$BankCount. Port-bank configuration changes require an explicit stopped-host state migration."
        }
        if ($generation -lt 0) {
            throw "Generation '$generation' is invalid."
        }
        if ($lastBankIndex -lt 0 -or $lastBankIndex -ge $BankCount) {
            throw "lastBankIndex '$lastBankIndex' is outside bank count '$BankCount'."
        }
        if ($null -eq $historyProperty -or $null -eq $historyProperty.Value) {
            throw 'Required property history is missing or null.'
        }

        return [pscustomobject]@{
            Generation = $generation
            LastBankIndex = $lastBankIndex
            History = @($historyProperty.Value)
        }
    } catch {
        if ($_.Exception.Message -like 'webrtc_port_bank_state_configuration_mismatch:*') {
            throw
        }
        throw "webrtc_port_bank_state_invalid: Could not use '$StatePath': $($_.Exception.Message)"
    }
}

function ConvertTo-ScaleWorldPortBankHistoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,
        [Parameter(Mandatory = $true)]
        [int]$BankCount
    )

    try {
        $bankIndex = [int](Get-ScaleWorldRequiredStateProperty -State $Entry -Name 'bankIndex')
        $generation = [long](Get-ScaleWorldRequiredStateProperty -State $Entry -Name 'generation')
        $selectedAtUnixSeconds = [long](Get-ScaleWorldRequiredStateProperty -State $Entry -Name 'selectedAtUnixSeconds')
        $selectedAtUtc = [DateTimeOffset]::FromUnixTimeSeconds($selectedAtUnixSeconds)

        if ($bankIndex -lt 0 -or $bankIndex -ge $BankCount) {
            throw "bankIndex '$bankIndex' is outside bank count '$BankCount'."
        }
        if ($generation -lt 0) {
            throw "generation '$generation' is invalid."
        }
        if ($selectedAtUnixSeconds -lt 1) {
            throw "selectedAtUnixSeconds '$selectedAtUnixSeconds' is invalid."
        }

        return [pscustomobject]@{
            bankIndex = $bankIndex
            generation = $generation
            selectedAtUnixSeconds = $selectedAtUnixSeconds
            selectedAtUtc = $selectedAtUtc
            reason = if ($null -ne $Entry.PSObject.Properties['reason']) { [string]$Entry.reason } else { 'runtime_generation' }
        }
    } catch {
        throw "webrtc_port_bank_state_invalid: Invalid history entry: $($_.Exception.Message)"
    }
}

function Select-ScaleWorldWebRtcPortBank {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [int]$RangeMin = 49152,
        [int]$RangeMax = 65535,
        [int]$BankSize = 256,
        [int]$ReuseCooldownSeconds = 660,
        [int]$LockTimeoutSeconds = 30,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not [System.IO.Path]::IsPathRooted($StatePath)) {
        throw "webrtc_port_bank_configuration_invalid: StatePath must be an absolute path."
    }
    if ($RangeMin -lt 1 -or $RangeMin -gt 65535 -or $RangeMax -lt 1 -or $RangeMax -gt 65535 -or $RangeMax -lt $RangeMin) {
        throw "webrtc_port_bank_configuration_invalid: Port range '$RangeMin-$RangeMax' is invalid."
    }
    if ($BankSize -lt 4) {
        throw "webrtc_port_bank_configuration_invalid: BankSize must be at least 4 ports."
    }
    if ($ReuseCooldownSeconds -lt 600) {
        throw "webrtc_port_bank_configuration_invalid: ReuseCooldownSeconds must be at least 600 seconds."
    }
    if ($LockTimeoutSeconds -lt 1 -or $LockTimeoutSeconds -gt 300) {
        throw "webrtc_port_bank_configuration_invalid: LockTimeoutSeconds must be between 1 and 300 seconds."
    }

    $rangeSize = ([long]$RangeMax - [long]$RangeMin) + 1
    if (($rangeSize % $BankSize) -ne 0) {
        throw "webrtc_port_bank_configuration_invalid: Port range size '$rangeSize' must be exactly divisible by BankSize '$BankSize'."
    }
    $bankCount = [int]($rangeSize / $BankSize)
    if ($bankCount -lt 2) {
        throw "webrtc_port_bank_configuration_invalid: The configured range must provide at least two banks."
    }

    $resolvedStatePath = [System.IO.Path]::GetFullPath($StatePath)
    $stateDirectory = Split-Path -Parent $resolvedStatePath
    if ([string]::IsNullOrWhiteSpace($stateDirectory)) {
        throw "webrtc_port_bank_configuration_invalid: StatePath '$resolvedStatePath' has no parent directory."
    }
    if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $lockPath = "$resolvedStatePath.lock"
    $stateExistsBeforeLock = Test-Path -LiteralPath $resolvedStatePath -PathType Leaf
    $lockMarkerExistsBeforeLock = Test-Path -LiteralPath $lockPath -PathType Leaf
    if (-not $stateExistsBeforeLock -and $lockMarkerExistsBeforeLock) {
        throw "webrtc_port_bank_state_missing: State '$resolvedStatePath' is missing even though its durable lock marker exists. Restore the state or perform an explicit stopped-host migration."
    }

    $lockStream = $null
    try {
        $lockStream = Open-ScaleWorldPortBankLock -LockPath $lockPath -TimeoutSeconds $LockTimeoutSeconds
        $now = $NowUtc.ToUniversalTime()
        $persisted = Read-ScaleWorldPortBankState `
            -StatePath $resolvedStatePath `
            -RangeMin $RangeMin `
            -RangeMax $RangeMax `
            -BankSize $BankSize `
            -BankCount $bankCount

        $generation = 0L
        $lastBankIndex = 0
        $rawHistory = @()
        if ($null -ne $persisted) {
            $generation = [long]$persisted.Generation
            $lastBankIndex = [int]$persisted.LastBankIndex
            $rawHistory = @($persisted.History)
        }

        # Bank zero contains Unreal's legacy/default lowest ports. Reserve it on
        # every allocation so re-enabling this feature after a legacy rollback
        # cannot immediately collide with a just-stopped default-port process.
        $rawHistory += [pscustomobject]@{
            bankIndex = 0
            generation = 0L
            selectedAtUnixSeconds = $now.ToUnixTimeSeconds()
            reason = 'legacy_default_reservation'
        }

        $cutoff = $now.AddSeconds(-$ReuseCooldownSeconds)
        $latestActiveByBank = @{}
        foreach ($rawEntry in $rawHistory) {
            $entry = ConvertTo-ScaleWorldPortBankHistoryEntry -Entry $rawEntry -BankCount $bankCount
            if ($entry.selectedAtUtc -lt $cutoff) {
                continue
            }

            if (
                -not $latestActiveByBank.ContainsKey($entry.bankIndex) -or
                $entry.selectedAtUtc -gt $latestActiveByBank[$entry.bankIndex].selectedAtUtc
            ) {
                $latestActiveByBank[$entry.bankIndex] = $entry
            }
        }

        $selectedBankIndex = $null
        for ($offset = 1; $offset -le $bankCount; $offset++) {
            $candidate = ($lastBankIndex + $offset) % $bankCount
            if (-not $latestActiveByBank.ContainsKey($candidate)) {
                $selectedBankIndex = $candidate
                break
            }
        }

        if ($null -eq $selectedBankIndex) {
            $earliestReusableAt = @(
                $latestActiveByBank.Values |
                    ForEach-Object { $_.selectedAtUtc.AddSeconds($ReuseCooldownSeconds) } |
                    Sort-Object
            ) | Select-Object -First 1
            throw "webrtc_port_bank_exhausted: All $bankCount banks are inside the ${ReuseCooldownSeconds}s no-reuse window. Earliest reuse is '$($earliestReusableAt.ToString('o'))'."
        }

        $nextGeneration = $generation + 1
        $selectedAtText = $now.ToString('o')
        $selectedEntry = [pscustomobject]@{
            bankIndex = [int]$selectedBankIndex
            generation = [long]$nextGeneration
            selectedAtUnixSeconds = $now.ToUnixTimeSeconds()
            reason = 'runtime_generation'
        }
        $activeHistory = @(
            foreach ($activeEntry in $latestActiveByBank.Values) {
                [pscustomobject]@{
                    bankIndex = [int]$activeEntry.bankIndex
                    generation = [long]$activeEntry.generation
                    selectedAtUnixSeconds = [long]$activeEntry.selectedAtUnixSeconds
                    reason = [string]$activeEntry.reason
                }
            }
        )
        $activeHistory += $selectedEntry
        $activeHistory = @($activeHistory | Sort-Object -Property generation, bankIndex)
        $selectedMinPort = $RangeMin + ([int]$selectedBankIndex * $BankSize)
        $selectedMaxPort = $selectedMinPort + $BankSize - 1

        $nextState = [ordered]@{
            schemaVersion = 1
            rangeMin = $RangeMin
            rangeMax = $RangeMax
            bankSize = $BankSize
            bankCount = $bankCount
            reuseCooldownSeconds = $ReuseCooldownSeconds
            generation = [long]$nextGeneration
            lastBankIndex = [int]$selectedBankIndex
            lastSelectedAtUtc = $selectedAtText
            allocatorPid = $PID
            history = $activeHistory
        }
        Write-ScaleWorldPortBankStateAtomic -StatePath $resolvedStatePath -State $nextState

        return [pscustomobject]@{
            Generation = [long]$nextGeneration
            BankIndex = [int]$selectedBankIndex
            BankCount = $bankCount
            MinPort = $selectedMinPort
            MaxPort = $selectedMaxPort
            BankSize = $BankSize
            RangeMin = $RangeMin
            RangeMax = $RangeMax
            ReuseCooldownSeconds = $ReuseCooldownSeconds
            StatePath = $resolvedStatePath
        }
    } finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }
}

Export-ModuleMember -Function Select-ScaleWorldWebRtcPortBank
