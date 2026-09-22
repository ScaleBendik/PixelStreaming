[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'instance_config.psm1') -Force
function Assert-True($Condition, $Message) { if (!$Condition) { throw $Message } }
$profile='{"values":{"resX":2240,"resY":1260,"fps":60,"maxBitrateKbps":30000,"forceResolution":1,"sg.ShadowQuality":4},"arguments":[{"name":"Custom","value":"hello, world & 100% !","enabled":true},{"name":"List","value":"one,two)","enabled":true},{"name":"Disabled","value":null,"enabled":false}]}' | ConvertFrom-Json
Assert-InstanceConfigLayer $profile
$arguments=@(Get-InstanceConfigArguments $profile)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InstanceConfigArgv {
 [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CommandLineToArgvW(string cmd, out int count);
 [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr ptr);
}
'@
$count=0
$argv=[InstanceConfigArgv]::CommandLineToArgvW(('Unreal.exe '+($arguments -join ' ')),[ref]$count)
try {
    $tokens=@(for($i=1;$i -lt $count;$i++){[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($argv,$i*[IntPtr]::Size))})
    # Model the LaunchWindows argv reconstruction and FParse::Value used by Unreal.
    $engineTokens=@($tokens | ForEach-Object {
        if ($_.Contains(' ')) {
            $at=$_.IndexOf('=')+1
            $_.Substring(0,$at)+'"'+$_.Substring($at)+'"'
        } else { $_ }
    })
    foreach ($entry in @{Custom='hello, world & 100% !';List='one,two)';ExecCmds='sg.ShadowQuality 4'}.GetEnumerator()) {
        $matched=@($engineTokens | Where-Object { $_ -like "-$($entry.Key)=*" })
        Assert-True ($matched.Count -eq 1) "Missing or duplicate $($entry.Key)."
        $value=$matched[0].Substring($entry.Key.Length+2)
        $parsed=if($value.StartsWith('"')){($value.Substring(1) -split '"',2)[0]}else{($value -split '[,)\s]',2)[0]}
        Assert-True ($parsed -ceq $entry.Value) "Unreal value parsing failed for $($entry.Key): '$parsed'."
    }
    Assert-True ($tokens -contains '-ForceRes') 'Force resolution was lost.'
    Assert-True ($tokens.Count -eq 4) 'Disabled argument was emitted.'
} finally { [void][InstanceConfigArgv]::LocalFree($argv) }
foreach($name in @('ExecCmds','INI','PixelStreamingWebRTCFps','ScaleWorldPremium','sg.ShadowQuality','ResX')) {
    $bad=$profile | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $bad.arguments=@([pscustomobject]@{name=$name;value='1';enabled=$true})
    $rejected=$false
    try { Assert-InstanceConfigLayer $bad } catch { $rejected=$true }
    Assert-True $rejected "Protected argument accepted: $name"
}
$folder=Join-Path ([IO.Path]::GetTempPath()) ('sw-instance-config-test-'+[guid]::NewGuid().ToString('N'))
try {
    $path=Join-Path $folder 'snapshot.json'
    Write-InstanceConfigAtomic $path ([ordered]@{schemaVersion=1;profile=$profile;revision='first'})
    Write-InstanceConfigAtomic $path ([ordered]@{schemaVersion=1;profile=$profile;revision='second'})
    Assert-True ((Read-InstanceConfigSnapshot $path).revision -eq 'second') 'Atomic replacement failed.'
    $bad=$profile | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $bad.values.fps=0
    $rejected=$false
    try { Assert-InstanceConfigLayer $bad } catch { $rejected=$true }
    Assert-True $rejected 'Out-of-range FPS was accepted.'
} finally {
    $resolved=[IO.Path]::GetFullPath($folder)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'sw-instance-config-test-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output 'Instance config validation, native Windows quoting and atomic snapshot tests passed.'
