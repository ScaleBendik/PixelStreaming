[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sw-encoder-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
try {
 Copy-Item (Join-Path $PSScriptRoot 'start_scaleworld.ps1') (Join-Path $fixture 'start_scaleworld.ps1')
 Set-Content (Join-Path $fixture 'ScaleWorld.exe') ''
 Set-Content (Join-Path $fixture 'scaleworld_process_helpers.ps1') @'
function Get-ScaleWorldRuntimeProcessMatcher { param($InstallRoot,$ExecutableName,$RuntimeProcessPattern,$IncludeLauncherExecutable) [pscustomobject]@{InstallRoot=$InstallRoot;NamePatterns=@('ScaleWorld')} }
function Get-ScaleWorldRuntimeProcesses { param($ExcludeProcessIds,$Matcher) [pscustomobject]@{Name='ScaleWorld';ProcessId=999} }
'@
 Set-Content (Join-Path $fixture 'unreal_prerequisite.psm1') @'
function Assert-ScaleWorldUnrealPrerequisite { param($UnrealRoot,$LauncherExecutableName) [pscustomobject]@{RequiredVersion='test';InstalledVersion='test'} }
'@
 Set-Content (Join-Path $fixture 'invoke.ps1') @'
param($SelectedCodec,$TierDefault,$ExpectedCodec)
$env:SCALEWORLD_ENCODER_CODEC=if($SelectedCodec -eq 'unset'){''}else{$SelectedCodec}
$env:SCALEWORLD_DEFAULT_ENCODER_CODEC=if($TierDefault -eq 'unset'){''}else{$TierDefault}
function Start-Process {
 param($FilePath,$ArgumentList,$WorkingDirectory,[switch]$PassThru)
 if($ArgumentList -notcontains "-PixelStreamingEncoderCodec=$ExpectedCodec"){throw 'Codec selection changed'}
 $cuda=@($ArgumentList|Where-Object {$_ -eq '-AVCodecs.NvEnc.D3D12UsesCUDA=true'})
 if($ExpectedCodec -ieq 'H264') {if($cuda.Count -ne 1){throw 'H264 must enable CUDA once'}}
 elseif($cuda.Count -ne 0){throw 'Non-H264 backend must remain unchanged'}
 if($ArgumentList -contains '-d3d11'){throw 'Renderer must not switch to D3D11'}
 [pscustomobject]@{Id=$PID}
}
& "$PSScriptRoot\start_scaleworld.ps1" -InstallRoot $PSScriptRoot -RuntimeProcessWaitSeconds 2
'@
 foreach($case in @(@('unset','unset','vp9'),@('unset','AV1','AV1'),@('H264','AV1','H264'),@('h264','unset','h264'),@('VP9','AV1','VP9'))) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'invoke.ps1') -SelectedCodec $case[0] -TierDefault $case[1] -ExpectedCodec $case[2]
  if($LASTEXITCODE -ne 0){throw "Encoder launch regression failed: $($case -join ',')"}
 }
 'Encoder launch regression passed (five codec/default combinations; no Unreal launched).'
} finally {
 $resolved=[IO.Path]::GetFullPath($fixture)
 $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'sw-encoder-test-*'){throw 'Unsafe test cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
