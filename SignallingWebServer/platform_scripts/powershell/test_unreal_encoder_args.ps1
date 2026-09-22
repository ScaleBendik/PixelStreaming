[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sw-encoder-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
try {
 Copy-Item (Join-Path $PSScriptRoot 'start_scaleworld.ps1') (Join-Path $fixture 'start_scaleworld.ps1')
 Copy-Item (Join-Path $PSScriptRoot 'instance_config.psm1') (Join-Path $fixture 'instance_config.psm1')
 Set-Content (Join-Path $fixture 'ScaleWorld.exe') ''
 Set-Content (Join-Path $fixture 'scaleworld_process_helpers.ps1') @'
function Get-ScaleWorldRuntimeProcessMatcher { param($InstallRoot,$ExecutableName,$RuntimeProcessPattern,$IncludeLauncherExecutable) [pscustomobject]@{InstallRoot=$InstallRoot;NamePatterns=@('ScaleWorld')} }
function Get-ScaleWorldRuntimeProcesses { param($ExcludeProcessIds,$Matcher) [pscustomobject]@{Name='ScaleWorld';ProcessId=999} }
'@
 Set-Content (Join-Path $fixture 'unreal_prerequisite.psm1') @'
function Assert-ScaleWorldUnrealPrerequisite { param($UnrealRoot,$LauncherExecutableName) [pscustomobject]@{RequiredVersion='test';InstalledVersion='test'} }
'@
 Set-Content (Join-Path $fixture 'invoke.ps1') @'
param($SelectedCodec,$TierDefault,$ExpectedCodec,$ConfiguredClass='unset')
$env:SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT=''
if($ConfiguredClass -ne 'unset') {
 $env:SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT=Join-Path $PSScriptRoot 'snapshot.json'
 $profile='{"values":{"resX":1920,"resY":1080,"fps":60,"maxBitrateKbps":40000,"forceResolution":1,"sg.ShadowQuality":3},"arguments":[{"name":"Custom","value":"two words,comma","enabled":true}]}' | ConvertFrom-Json
 @{schemaVersion=1;profile=$profile;serviceClass=$ConfiguredClass;reference=@{revisionId='test'};instanceId='i-fixture';region='eu-north-1';source='published'} | ConvertTo-Json -Depth 10 | Set-Content $env:SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT
}
function aws { $global:LASTEXITCODE=0 } # Never publish fixture observations to AWS.
$env:SCALEWORLD_ENCODER_CODEC=if($SelectedCodec -eq 'unset'){''}else{$SelectedCodec}
$env:SCALEWORLD_DEFAULT_ENCODER_CODEC=if($TierDefault -eq 'unset'){''}else{$TierDefault}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodecLaunchArgv {
 [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern IntPtr CommandLineToArgvW(string commandLine, out int argc);
 [DllImport("kernel32.dll")]
 public static extern IntPtr LocalFree(IntPtr pointer);
}
"@
function Start-Process {
 param($FilePath,$ArgumentList,$WorkingDirectory,[switch]$PassThru)
 if($ArgumentList -notcontains "-PixelStreamingEncoderCodec=$ExpectedCodec"){throw 'Codec selection changed'}
 $cuda=@($ArgumentList|Where-Object {$_ -eq '-AVCodecs.NvEnc.D3D12UsesCUDA=true'})
 if($cuda.Count -ne 1){throw 'Negotiated H264 must enable CUDA once for every initial codec'}
 # LaunchWindows.cpp decodes argv, then only restores ordinary quotes for
 # values with spaces. Literal escaped quotes must survive this first pass.
 $argc=0
 $argv=[CodecLaunchArgv]::CommandLineToArgvW(('ScaleWorld.exe '+($ArgumentList -join ' ')),[ref]$argc)
 if($argv -eq [IntPtr]::Zero){throw 'Windows command-line parsing failed'}
 try {
  $engineArguments=@(for($index=1;$index -lt $argc;$index++){
   $argument=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($argv,$index*[IntPtr]::Size))
   if($argument.Contains(' ')){
    $quoteAt=if($argument.StartsWith('-') -and $argument.Contains('=')){$argument.IndexOf('=')+1}else{0}
    $argument=$argument.Substring(0,$quoteAt)+'"'+$argument.Substring($quoteAt)+'"'
   }
   $argument
  })
 } finally {[void][CodecLaunchArgv]::LocalFree($argv)}
 # Model the engine's ConsoleVariableToCommandArgValue conversion, rather than
 # accepting a dotted CVar literal that appears on argv but is silently ignored.
 $expectedSettings=@{
  'PixelStreaming2.WebRTC.NegotiateCodecs'='true'
  'PixelStreaming2.WebRTC.CodecPreferences'='AV1,VP9,H264'
  'PixelStreaming2.Encoder.LatencyMode'='LOW_LATENCY'
  'PixelStreaming2.WebRTC.Fps'='30'
  'PixelStreaming2.WebRTC.MaxBitrate'='30000000'
 }
 if($ConfiguredClass -ne 'unset') {
  $expectedSettings['PixelStreaming2.WebRTC.Fps']='60'
  $expectedSettings['PixelStreaming2.WebRTC.MaxBitrate']='40000000'
  $expectedSettings['ExecCmds']='sg.ShadowQuality 3'
  $expectedSettings['Custom']='two words,comma'
  if($ArgumentList -notcontains '-ResX=1920' -or $ArgumentList -notcontains '-ResY=1080' -or $ArgumentList -notcontains '-ForceRes'){throw 'Structured graphics settings were not applied'}
  $premium=@($ArgumentList | Where-Object {$_ -eq '-ScaleWorldPremium'})
  $expectedPremium=if($ConfiguredClass -eq 'premium'){1}else{0}
  if($premium.Count -ne $expectedPremium){throw 'Premium marker did not follow the snapshot serving class'}
 }
 foreach($cvar in $expectedSettings.Keys){
  $argumentName=$cvar.Replace('.','').Replace('PixelStreaming2','PixelStreaming')
  $matched=@($engineArguments|Where-Object {$_ -like "-$argumentName=*"})
  if($matched.Count -ne 1){throw "Engine setting not parsed: $cvar"}
  # FParse::Value stops unquoted values at comma, closing parenthesis or whitespace.
  $value=$matched[0].Substring($argumentName.Length+2)
  $parsed=if($value.StartsWith('"')){($value.Substring(1) -split '"',2)[0]}else{($value -split '[,)\s]',2)[0]}
  if($parsed -ne $expectedSettings[$cvar]){throw "Engine setting not parsed: $cvar (parsed $parsed)"}
 }
 if(@($ArgumentList|Where-Object {$_ -like '-PixelStreaming2.*'}).Count){throw 'Dotted Pixel Streaming CVars are not startup arguments'}
 if($ArgumentList -contains '-d3d11'){throw 'Renderer must not switch to D3D11'}
 [pscustomobject]@{Id=$PID}
}
$extra=if($ConfiguredClass -ne 'unset'){@('-ExecCmds=sg.ShadowQuality 4','-ScaleWorldPremium')}else{@()}
& "$PSScriptRoot\start_scaleworld.ps1" -InstallRoot $PSScriptRoot -RuntimeProcessWaitSeconds 2 -AdditionalArgs $extra
'@
 foreach($case in @(@('unset','unset','vp9'),@('unset','AV1','AV1'),@('H264','AV1','H264'),@('h264','unset','h264'),@('VP9','AV1','VP9'))) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'invoke.ps1') -SelectedCodec $case[0] -TierDefault $case[1] -ExpectedCodec $case[2]
  if($LASTEXITCODE -ne 0){throw "Encoder launch regression failed: $($case -join ',')"}
 }
 foreach($class in @('standard','premium')) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'invoke.ps1') -SelectedCodec H264 -TierDefault AV1 -ExpectedCodec H264 -ConfiguredClass $class
  if($LASTEXITCODE -ne 0){throw "Configured launcher regression failed: $class"}
 }
 'Encoder launch regression passed (five legacy combinations and two configured classes; no Unreal launched).'
} finally {
 $resolved=[IO.Path]::GetFullPath($fixture)
 $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'sw-encoder-test-*'){throw 'Unsafe test cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
