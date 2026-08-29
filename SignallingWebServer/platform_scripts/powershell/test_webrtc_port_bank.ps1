[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-ThrowsLike {
    param(
        [scriptblock]$Action,
        [string]$Pattern,
        [string]$Message
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -like $Pattern) {
            return
        }
        throw "$Message Expected error '$Pattern', got '$($_.Exception.Message)'."
    }

    throw "$Message Expected error '$Pattern', but no error was raised."
}

$modulePath = Join-Path $PSScriptRoot 'webrtc_port_bank.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "WebRTC port-bank module '$modulePath' was not found."
}

Import-Module $modulePath -Force -ErrorAction Stop
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("scaleworld-webrtc-port-bank-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $fixedNow = [DateTimeOffset]::Parse('2026-08-29T12:00:00Z')
    $statePath = Join-Path $testRoot 'rotation.json'

    $first = Select-ScaleWorldWebRtcPortBank `
        -StatePath $statePath `
        -RangeMin 10000 `
        -RangeMax 10999 `
        -BankSize 100 `
        -ReuseCooldownSeconds 600 `
        -NowUtc $fixedNow
    Assert-Equal $first.Generation 1 'First selection must create generation one.'
    Assert-Equal $first.BankIndex 1 'First selection must skip bank zero reserved for the legacy generation.'
    Assert-Equal $first.MinPort 10100 'First selection minimum port is incorrect.'
    Assert-Equal $first.MaxPort 10199 'First selection maximum port is incorrect.'

    $second = Select-ScaleWorldWebRtcPortBank `
        -StatePath $statePath `
        -RangeMin 10000 `
        -RangeMax 10999 `
        -BankSize 100 `
        -ReuseCooldownSeconds 600 `
        -NowUtc $fixedNow.AddSeconds(1)
    Assert-Equal $second.Generation 2 'Second selection must advance the durable generation.'
    Assert-Equal $second.BankIndex 2 'Second selection must use the next available bank.'

    $persisted = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Equal ([int]$persisted.schemaVersion) 1 'Persisted schema version is incorrect.'
    Assert-Equal ([int]$persisted.lastBankIndex) 2 'Persisted last bank is incorrect.'
    Assert-Equal (@($persisted.history).Count) 3 'History must retain the legacy reservation and two runtime generations.'
    Assert-Equal (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp' -File).Count) 0 'Successful writes must not leave temporary files.'
    Assert-Equal (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.bak' -File).Count) 0 'Successful writes must not leave backup files.'

    $heldLock = [System.IO.FileStream]::new(
        "$statePath.lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Assert-ThrowsLike `
            -Action {
                Select-ScaleWorldWebRtcPortBank `
                    -StatePath $statePath `
                    -RangeMin 10000 `
                    -RangeMax 10999 `
                    -BankSize 100 `
                    -ReuseCooldownSeconds 600 `
                    -LockTimeoutSeconds 1 `
                    -NowUtc $fixedNow.AddSeconds(2)
            } `
            -Pattern 'webrtc_port_bank_lock_timeout:*' `
            -Message 'Concurrent allocators must serialize through the durable lock.'
    } finally {
        $heldLock.Dispose()
    }

    $missingStatePath = Join-Path $testRoot 'missing-after-initialization.json'
    $null = Select-ScaleWorldWebRtcPortBank `
        -StatePath $missingStatePath `
        -RangeMin 50000 `
        -RangeMax 50999 `
        -BankSize 100 `
        -ReuseCooldownSeconds 600 `
        -NowUtc $fixedNow
    Remove-Item -LiteralPath $missingStatePath -Force
    Assert-ThrowsLike `
        -Action {
            Select-ScaleWorldWebRtcPortBank `
                -StatePath $missingStatePath `
                -RangeMin 50000 `
                -RangeMax 50999 `
                -BankSize 100 `
                -ReuseCooldownSeconds 600 `
                -NowUtc $fixedNow.AddSeconds(1)
        } `
        -Pattern 'webrtc_port_bank_state_missing:*' `
        -Message 'Missing initialized state must fail closed instead of silently restarting rotation.'

    Assert-ThrowsLike `
        -Action {
            Select-ScaleWorldWebRtcPortBank `
                -StatePath $statePath `
                -RangeMin 10000 `
                -RangeMax 10999 `
                -BankSize 200 `
                -ReuseCooldownSeconds 600 `
                -NowUtc $fixedNow.AddSeconds(2)
        } `
        -Pattern 'webrtc_port_bank_state_configuration_mismatch:*' `
        -Message 'Changing the bank geometry over live durable state must fail closed.'

    $exhaustionStatePath = Join-Path $testRoot 'exhaustion.json'
    $onlyNewBank = Select-ScaleWorldWebRtcPortBank `
        -StatePath $exhaustionStatePath `
        -RangeMin 20000 `
        -RangeMax 20007 `
        -BankSize 4 `
        -ReuseCooldownSeconds 600 `
        -NowUtc $fixedNow
    Assert-Equal $onlyNewBank.BankIndex 1 'Two-bank initialization must reserve legacy bank zero and select bank one.'
    Assert-ThrowsLike `
        -Action {
            Select-ScaleWorldWebRtcPortBank `
                -StatePath $exhaustionStatePath `
                -RangeMin 20000 `
                -RangeMax 20007 `
                -BankSize 4 `
                -ReuseCooldownSeconds 600 `
                -NowUtc $fixedNow.AddSeconds(1)
        } `
        -Pattern 'webrtc_port_bank_exhausted:*' `
        -Message 'Allocator must fail closed instead of reusing a cooling bank.'

    $afterCooldown = Select-ScaleWorldWebRtcPortBank `
        -StatePath $exhaustionStatePath `
        -RangeMin 20000 `
        -RangeMax 20007 `
        -BankSize 4 `
        -ReuseCooldownSeconds 600 `
        -NowUtc $fixedNow.AddSeconds(601)
    Assert-Equal $afterCooldown.BankIndex 1 'The legacy/default bank must remain reserved when the runtime bank becomes reusable.'
    Assert-Equal $afterCooldown.Generation 2 'Generation must remain monotonic after history expiry.'

    $corruptStatePath = Join-Path $testRoot 'corrupt.json'
    Set-Content -LiteralPath $corruptStatePath -Value '{not-json' -Encoding ASCII
    Assert-ThrowsLike `
        -Action {
            Select-ScaleWorldWebRtcPortBank `
                -StatePath $corruptStatePath `
                -RangeMin 30000 `
                -RangeMax 30999 `
                -BankSize 100 `
                -ReuseCooldownSeconds 600 `
                -NowUtc $fixedNow
        } `
        -Pattern 'webrtc_port_bank_state_invalid:*' `
        -Message 'Corrupt durable state must fail closed.'

    Assert-ThrowsLike `
        -Action {
            Select-ScaleWorldWebRtcPortBank `
                -StatePath (Join-Path $testRoot 'unsafe-cooldown.json') `
                -RangeMin 40000 `
                -RangeMax 40999 `
                -BankSize 100 `
                -ReuseCooldownSeconds 599 `
                -NowUtc $fixedNow
        } `
        -Pattern 'webrtc_port_bank_configuration_invalid:*' `
        -Message 'A cooldown below the TURN allocation window must be rejected.'

    Write-Host 'WebRTC port-bank tests passed.' -ForegroundColor Green
} finally {
    Remove-Module webrtc_port_bank -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).ProviderPath)
        $expectedPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\scaleworld-webrtc-port-bank-'
        if ($resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
