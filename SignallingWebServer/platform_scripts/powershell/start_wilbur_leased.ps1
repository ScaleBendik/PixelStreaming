[CmdletBinding()]
param([int]$NodeBirthTimeoutSeconds = 10)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack_launch_lease.ps1')
. (Join-Path $PSScriptRoot 'stack_launch_processes.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$installBase = if ($env:SCALEWORLD_INSTALL_BASE) { $env:SCALEWORLD_INSTALL_BASE } else { 'C:\PixelStreaming' }
$gate = $null
$child = $null
$nodePath = ''
$launchGeneration = [string]$env:SCALEWORLD_STACK_LAUNCH_GENERATION
$childBirth = [DateTime]::MinValue
function Stop-UncertifiedWilburChild {
    if ($null -eq $child) { return }
    if (-not $child.HasExited) { $child.Kill() }
    if (-not $child.WaitForExit(5000)) { throw 'Uncertified Wilbur native launcher did not terminate.' }
    $shellExited = $child.ExitTime.ToUniversalTime().AddTicks(9)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $nodes = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = {0}" -f $child.Id) -ErrorAction Stop | Where-Object {
            $birth = Get-ScaleWorldProcessCreationUtcDateTime $_
            $_.Name -ieq 'node.exe' -and $_.ExecutablePath -and
            (Get-StackLaunchCanonicalPath ([string]$_.ExecutablePath)) -ieq $nodePath -and
            $null -ne $birth -and $birth -ge $childBirth.AddTicks(-9) -and $birth -le $shellExited
        })
        if ($nodes.Count -eq 0) { return }
        foreach ($node in $nodes) { Stop-StackLaunchProcessIdentity (Get-StackLaunchCancellationIdentity $node) }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Uncertified direct-child Wilbur processes did not become absent.'
}
try {
    $gate = Enter-StackLaunchGate -RepoRoot $repoRoot -InstallBase $installBase -GenerationId $env:SCALEWORLD_STACK_LAUNCH_GENERATION
    if (-not $launchGeneration) {
        # An independent watchdog may repair a dead completed Wilbur. Resolve
        # its existing attempt before spawn, while the no-generation gate has
        # established that no live entry/recycler/reservation owns this work.
        $existingLease = Read-StackLaunchLease -Scope $gate.Scope
        if ($null -eq $existingLease -or $existingLease.repoRoot -ine $gate.Scope.RepoRoot -or
            $existingLease.phase -cne 'completed' -or
            (Test-StackLaunchProcessIdentity $existingLease.activeNode) -or
            (Test-StackLaunchProcessIdentity $existingLease.completedNode)) {
            throw 'Managed standalone Wilbur launch requires a dead completed lease; use start_streamer_stack.bat for a fresh or incomplete attempt.'
        }
        $launchGeneration = [string]$existingLease.generationId
    }
    if ([string]::IsNullOrWhiteSpace($env:NODE_EXE)) { throw 'Wilbur executable identity is missing.' }
    $nodePath = if ([IO.Path]::IsPathRooted($env:NODE_EXE)) { Get-StackLaunchCanonicalPath $env:NODE_EXE } else { Get-StackLaunchCanonicalPath (Get-Command $env:NODE_EXE -ErrorAction Stop).Source }
    $nativeLauncher = Join-Path $repoRoot 'platform_scripts\cmd\start_wilbur_native.bat'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c ""{0}""' -f $nativeLauncher
    $info.WorkingDirectory = $repoRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['SCALEWORLD_STACK_LAUNCH_GENERATION'] = $launchGeneration
    $child = [Diagnostics.Process]::Start($info)
    $null = $child.Handle
    $childBirth = $child.StartTime.ToUniversalTime()
    $deadline = [DateTime]::UtcNow.AddSeconds($NodeBirthTimeoutSeconds)
    $nodeBorn = $false
    do {
        $nodes = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = {0}" -f $child.Id) -ErrorAction Stop | Where-Object {
            $_.Name -ieq 'node.exe' -and $_.ExecutablePath -and
            (Get-StackLaunchCanonicalPath ([string]$_.ExecutablePath)) -ieq $nodePath -and
            (Get-ScaleWorldProcessCreationUtcDateTime $_) -ge $childBirth.AddTicks(-9)
        })
        if ($nodes.Count -gt 1) { throw 'Wilbur native launcher produced ambiguous Node identities.' }
        if ($nodes.Count -eq 1) {
            $nodeIdentity = Get-StackLaunchProcessIdentity -ProcessId ([int]$nodes[0].ProcessId) -Process $nodes[0]
            [void](Register-StackLaunchNode -Scope $gate.Scope -GenerationId $launchGeneration -NodeIdentity $nodeIdentity -LockHandle $gate)
            $nodeBorn = $true
            break
        }
        if ($child.HasExited) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $nodeBorn) {
        # Even an exited shell can have left an uncertified direct Node child.
        # Keep the gate until its pinned shell and exact children are absent.
        Stop-UncertifiedWilburChild
        throw ('Wilbur Node birth was not observed while the generation gate was held (native launcher exit {0}).' -f $child.ExitCode)
    }
} catch {
    # Do not leave the launch-producing shell alive on an observation/I/O error.
    $originalFailure = $_
    try { Stop-UncertifiedWilburChild }
    catch { throw "Wilbur launch failed and child absence could not be verified: $($_.Exception.Message)" }
    if ($null -ne $child) { $child.Dispose(); $child = $null }
    throw $originalFailure
} finally { if ($null -ne $gate) { Exit-StackLaunchGate -Handle $gate } }
try {
    $child.WaitForExit()
    exit $child.ExitCode
} finally { if ($null -ne $child) { $child.Dispose() } }
