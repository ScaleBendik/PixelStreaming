$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'watchdog.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RecoveryPlan' }, $false)
. ([scriptblock]::Create($function.Extent.Text))
$primary = @(@{Name='unreal'}, @{Name='wilbur'})
$launchers = @(@{Name='unreal-launcher'}, @{Name='wilbur-launcher'})
$fault = @{Name='streamer-health'; FaultReason='streamer_negotiation_timeout'}
$plan = Get-RecoveryPlan -FailedRules @($fault) -PrimaryRules $primary -LauncherRules $launchers -DefaultCommand 'stack' -UnrealOnlyCommand 'unreal' -WilburOnlyCommand 'wilbur'
if ($plan.Command -ne 'unreal' -or ($plan.TerminationRules.Name -join ',') -ne 'unreal,unreal-launcher') { throw 'Negotiation recovery must preserve Wilbur and its reconnect deadline.' }
$plan = Get-RecoveryPlan -FailedRules @($fault, @{Name='wilbur'}) -PrimaryRules $primary -LauncherRules $launchers -DefaultCommand 'stack' -UnrealOnlyCommand 'unreal' -WilburOnlyCommand 'wilbur'
if ($plan.Command -ne 'stack') { throw 'A simultaneous Wilbur failure still requires full stack recovery.' }
$plan = Get-RecoveryPlan -FailedRules @(@{Name='streamer-health'; FaultReason='streamer_health_invalid'}) -PrimaryRules $primary -LauncherRules $launchers -DefaultCommand 'stack' -UnrealOnlyCommand 'unreal' -WilburOnlyCommand 'wilbur'
if ($plan.Command -ne 'stack') { throw 'An invalid health file is not an isolated Unreal negotiation fault.' }
Write-Output 'Watchdog negotiation recovery checks passed.'
