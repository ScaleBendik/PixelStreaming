# H.264 encoding through CUDA with D3D12

The 2026-09-08 d1 investigation concluded with a working short-run mitigation
for UE5.8.2 on NVIDIA A10G / driver 595.59. Native D3D12 H.264 encoding retained
about 1.93 GiB in a 46-second allocation trace at `nvEncReconfigureEncoder`,
called by `FEncoderNVENC::ApplyConfig`. System commit exhaustion accompanied
the runtime failures. Active VP9 navigation did not show that retention.

With `-AVCodecs.NvEnc.D3D12UsesCUDA=true`, D3D12 rendering is retained and
frames reach NVENC through CUDA. During the connected H.264 test, Unreal private
memory stayed near 14 GiB: only +6.4 MiB over almost four minutes, with a decrease
of 2.2 MiB in the final 32-second sample. The runtime remained healthy without
restarting. This supports the mitigation; it does not establish indefinite
stability or complete resolution/reconnect/recovery acceptance.

The matching [NVIDIA report](https://forums.developer.nvidia.com/t/memory-leak-3-2-mib-call-in-nvencreconfigureencoder-with-h-264-d3d12-backend/371693)
is tracked as 6241525, on different hardware/driver. Our evidence isolates the
retaining call path but does not independently prove the vendor defect's exact
mechanism. Increasing RAM/pagefile would only postpone the observed exhaustion.

## Launcher behavior

`SignallingWebServer/platform_scripts/powershell/start_scaleworld.ps1` adds
the CUDA flag for every initial codec, because governed sessions can negotiate
H264 later. Codec negotiation is enabled in the same launcher.
Standard VP9, premium AV1 and explicit codec-selection precedence are unchanged.
The renderer is not switched. Because this is in the common Unreal launcher,
normal startup and Unreal-only watchdog recovery both apply the option without
depending on temporary stack arguments or saved Game.ini overrides.

The engine already contains this option; no Unreal rebuild is needed. Publish
and deploy the updated PixelStreaming runtime separately. The investigation did
not publish an artifact; the user will perform the artifact update manually.

## Validation and limits

From the repository root, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_unreal_encoder_args.ps1
```

It exercises real launcher argument construction with
mocked process/prerequisite boundaries, covering unchanged defaults and explicit
H264 selection without starting Unreal.

After artifact deployment, verify actual H264/CUDA arguments, D3D12 rendering,
presented frames, bounded private memory, resolution changes, reconnect and
Unreal-only recovery. CUDA texture sharing can have resource-layout compatibility
and synchronization costs; check image correctness and latency under GPU load.
Compression still uses NVENC hardware. Startup readiness alone is not media proof.

## d1 closeout

d1 was restored to its original scheduled launcher and VP9 configuration.
Temporary saved CUDA config, diagnostic task, launch flags and process-scoped
watchdog/log-cleanup overrides were removed through the recorded rollback.
The Development package remains installed until the user's manual update.
The independent `common.bat` empty-argument parser hotfix is retained.

Evidence and tools remain in `D:\ScaleWorldDiagnostics\h264-20260908` and
`C:\ProgramData\ScaleWorld\Diagnostics\h264-20260908`; nothing was uploaded
to scaleworlddepot. D: is ephemeral instance storage, lost on EC2 stop/termination.
Do not clear or reformat it during ordinary rollback. Detailed measurements and
backups are indexed by `../../diagnostics/d1-h264-20260908/FINDINGS.md` in the
shared workspace.
