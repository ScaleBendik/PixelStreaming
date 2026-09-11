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
CUDA=false for AV1 startup and CUDA=true for other initial codecs, which may
negotiate H264 later. This is a process-wide choice: codec negotiation does not
change the CUDA flag. An AV1-started process negotiating H264 still uses its
native path and requires separate memory acceptance. Codec negotiation remains enabled.
Standard VP9, premium AV1 and explicit codec-selection precedence are unchanged.
The renderer is not switched. Because this is in the common Unreal launcher,
normal startup and Unreal-only watchdog recovery both apply the option without
depending on temporary stack arguments or saved Game.ini overrides.

The engine already contains this option; no Unreal rebuild is needed. Publish
and deploy the updated PixelStreaming runtime separately. The investigation did
not publish an artifact; the user will perform the artifact update manually.

## Validation and limits

On 2026-09-09 the user reported persistent tiled/shifted video after changing
2240x1260 to 2560x1440 through an in-game Blueprint command with the CUDA path
enabled. Reconnecting to the same session restores the image at the new size.
Live resolution changes remain a known limitation (accepted as non-blocking
for this release by the user on 2026-09-10); the prior
bounded-memory result does not establish correct resizing. The exact instance,
negotiated codec and resource-level cause have not yet been verified for this report.

Epic's [workaround guidance](https://github.com/EpicGames/PixelStreamingInfrastructure/issues/900#issuecomment-4764121992)
warns of artifacts with placed D3D12 resources. Texture-layout/mapping lifetime
and encoder resize state are investigation leads, not confirmed causes. The
inspected UE source already requests an IDR on encoding-dimension changes, so
adding keyframes alone is not an established fix. Until isolated, retain a fixed
output resolution or reconnect after changing it. Do not revert to the leaking
native D3D12 H264 path as a blanket workaround. Any engine-side fix must retain
D3D12, preserve the CUDA memory benefit and pass repeated resize/reconnect tests.

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

## GUI resolution controls

The Settings panel has a Resolution section with fixed 16:9 presets: 1920x1080,
2240x1260, 2560x1440 and 3840x2160. These use the built-in Resolution.Width and
Resolution.Height command, without r.setres or a fullscreen suffix. Selecting a
preset disables viewport matching. The UI reports a request, not confirmed
application; use the Information panel to verify received dimensions.

Match viewport resolution remains available in this section with a warning that
ultrawide/non-16:9 layouts may not display correctly. Viewport scale is clamped
to 0.1–1, including initial and URL settings. Scaling cannot upscale the viewport;
a wide viewport can still produce a non-16:9 image. Fixed presets avoid that.

Both preset and viewport commands emit resolutionRequested only after the data
channel accepts the command. The reference player leaves AV1/VP9 connected.
For H264 it waits for a presented frame at the requested dimensions, then performs
one existing reconnect and verifies a replacement-source frame. A 30-second
manual-Retry timeout bounds either phase; matching dimensions are not proof of
image correctness. Same-size viewport notifications do not trigger repeat refreshes.

In-game controls remain in place until the user validates this GUI path. Their
resolutionApplied messages remain supported with H264-only reconnect recovery.
Test all four exact presets, repeated up/down changes, ultrawide letterboxing,
viewport toggle/scale, direct/TURN, ticket expiry and H264 memory/reconnect behavior
on the final artifact. AV1 CUDA-off does not itself establish resize stability.

## Blueprint-driven resize recovery

The reference TypeScript player handles this Pixel Streaming 2 Send Response
Descriptor after the in-game resolution change:

```json
{"type":"resolutionApplied","width":2560,"height":1440}
```

Width/height must be integer dimensions between 1 and 8192. Unrelated, malformed
or oversized responses are ignored. The user-selected initial Blueprint sequence
is r.setres, a 0.2-second Delay, then Send Response. That delay is an experimental
settling interval, not proof that Unreal has completed the resize.

The player disables MatchViewportResolution for the explicit choice, shows
Applying resolution, and calls the existing reconnect path once for H264 only.
AV1 and VP9 responses do not initiate reconnects. It does not
request a new managed session, restart Unreal, change codec policy, or bypass
H264 single-viewer admission. Rapid notifications coalesce to the latest size.
Recovery completes only after a presented-frame callback from a replacement video
source reports the requested dimensions. Old sources/callbacks cannot complete
it. After 30 seconds it displays Retry connection instead of starting another
resize-driven retry; normal transport/ticket recovery remains independently owned
by the existing player. Explicit session-end, inactivity and ticket-expiry guidance
takes precedence. Page exit removes the handler and pending timers/callbacks.

This is a reconnect mitigation, not an encoder/resource fix. Frame dimensions do
not prove freedom from tiled/shifted output. Host-validate the exact player/runtime
and Blueprint build with repeated changes among 1920x1080, 2240x1260, 2560x1440 and
3840x2160, direct and forced TURN, mouse alignment, unchanged session/application
state, reconnect grace, H264 viewer removal, memory stability, rapid clicks and
expired tickets. Confirm that 0.2 seconds is sufficient; use applied-size
acknowledgement if it is not. Do not close the media gate on local tests alone.

Focused regression command (under the pinned Node):
`npm test --workspace Frontend/implementations/typescript`.

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
