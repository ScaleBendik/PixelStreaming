[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Enter','Complete')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [string]$InstallBase='C:\PixelStreaming',
    [string]$OutputFile='',
    [ValidateSet('normal','recovery','validation')][string]$LaunchMode='normal',
    [string]$GenerationId=$env:SCALEWORLD_STACK_LAUNCH_GENERATION,
    [string]$Grant=$env:SCALEWORLD_STACK_LAUNCH_GRANT
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_preparation.ps1')
$handle=$null
try{
    if($Mode -ieq 'Enter'){
        $outputParent=Get-StackLaunchCanonicalPath (Split-Path -Parent $OutputFile)
        $tempParent=Get-StackLaunchCanonicalPath ([IO.Path]::GetTempPath())
        if($outputParent -ine $tempParent -or [IO.Path]::GetFileName($OutputFile) -notmatch '^scaleworld-stack-launch-[A-Za-z0-9-]+\.env$'){throw 'Entry receipt must use the fixed temporary-file pattern.'}
        if(Test-Path -LiteralPath $OutputFile){throw 'Entry receipt already exists.'}
    }
    $scope=Get-StackLaunchLeaseScope $RepoRoot $InstallBase
    $owner=Get-StackLaunchOwnerIdentity $scope
    $handle=Enter-StackLaunchLeaseLock $scope
    if($Mode -ieq 'Enter'){
        $result=Enter-StackLaunchAttempt -Scope $scope -OwnerIdentity $owner -Mode $LaunchMode -InheritedGeneration $GenerationId -Grant $Grant -LockHandle $handle
        if($null -ne $result.PSObject.Properties['Reason'] -and $result.Reason -ceq 'NodeUnclassified'){
            [Console]::Error.WriteLine('A live unregistered runtime Node prevents stack entry; preserving the Node, lease, config and health state.')
        }
        $receipt=('set "SCALEWORLD_STACK_LAUNCH_GENERATION={0}"' -f $result.GenerationId)+"`r`n"+('set "SCALEWORLD_STACK_LAUNCH_DECISION={0}"' -f $result.Decision)+"`r`n"
        $reused = 'false'
        if ($LaunchMode -ceq 'recovery' -and $result.Decision -ceq 'Enter' -and
            (Test-StackLaunchReplacementPreparation $scope (Read-StackLaunchLease $scope) $owner $handle)) {
            $reused = 'true'
        }
        $receipt += ('set "SCALEWORLD_STACK_RECOVERY_PREPARATION_REUSED={0}"' -f $reused)+[Environment]::NewLine
        $bytes=[Text.Encoding]::ASCII.GetBytes($receipt);$stream=[IO.FileStream]::new($OutputFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if($result.Decision -ceq 'Skip'){exit 10}
    }elseif($Mode -ieq 'Complete'){
        # Discovery cannot establish a new pin here: completion must promote
        # the exact Node birth observed by the launch wrapper under its gate.
        $node=Get-StackLaunchNodeIdentity $scope $owner
        [void](Complete-StackLaunchAttempt -Scope $scope -GenerationId $GenerationId -OwnerIdentity $owner -NodeIdentity $node -LockHandle $handle)
    }
    exit 0
}catch{
    [Console]::Error.WriteLine('Stack launch lease operation failed: '+$_.Exception.Message)
    exit 1
}finally{if($null -ne $handle){Exit-StackLaunchLeaseLock $handle}}
