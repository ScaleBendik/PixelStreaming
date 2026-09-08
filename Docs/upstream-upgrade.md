# Upstream integration and custom compatibility

The fork integrates Epic's UE5.8 branch at commit
`ce2235f0d5a78ef7e4c6c1f4a6539154173000e5`, fetched on 2026-09-07
from https://github.com/EpicGames/PixelStreamingInfrastructure.
The local starting point was `99b122632b9797c56193a719f1b4104f178d638f`
on `work/runtime-entitlement-handoff`; the integration branch is
`work/pixelstreaming-ue5.8-upgrade`. A merge retains both histories and the
original branch as a local rollback reference.

The Unreal application target is UE 5.8.2. Upstream's development branch is
`master`, not `main`. Its head `6e42bce25567e1cf30a6338db7166a3dbf28e5e6`
was compared using patch equivalence. The substantive frontend, SFU and dependency
fixes were already on UE5.8. The remaining shared player-token feature was not
adopted because it competes with ScaleWorld's signed-ticket verifier. Its useful
interactive-config redaction idea is implemented through the same sanitizer used
by our startup logs, including the custom authentication fields.

## Preserved integration contracts

### Unreal startup codec arguments

Pixel Streaming 2 command-line names omit CVar dots and replace `PixelStreaming2`
with `PixelStreaming`. The launcher uses `-PixelStreamingWebRTCNegotiateCodecs=true`
and the PowerShell single-quoted argument
`'-PixelStreamingWebRTCCodecPreferences=\"AV1,VP9,H264\"'`. VP8 is removed from the current startup preference list.
Backslashes preserve literal quotes through Windows argv processing. Ordinary
quotes are stripped, after which Unreal stops at the first comma. Correct names
alone (commit db4b4d4d) or ordinary quotes restrict the list to AV1, yielding no
video offer on the tested Standard host. The regression uses native
CommandLineToArgvW and Unreal's reconstruction/value parsing rules across all
startup codec cases. FPS, bitrate and latency use the same name conversion.

Final launcher SHA256:
2A67134BC613B85F2149A1C8AA2B05A1459F05760B1147303A181623FD880621.
Applied directly to Dev d2 at 2026-09-08 14:42 UTC and d1 at 14:47 UTC, within
runtime pixelstreaming-runtime-20260908-004, restarting only Unreal and retaining
Wilbur. Backups are under
C:\ProgramData\ScaleWorld\Diagnostics\codec-negotiation-db4b4d4d on each host.
Both Dev launchers were restored from the original hash-verified backup on
2026-09-08 at the user's request before final artifact publication. Original SHA256:
27203C0143A133226F2870916F956BB194F9445BBD61152E8F79F2B4D1D4ABEA.
The final source retains the fix; publication does not activate it on these hosts.

On d2, the full offer contains VP9/H264/VP8, governed SDP selects H264, and the
browser answers H264. The user confirmed working H264 video. VP9 switches failed
during negotiation and immediately restored H264. The agreed simplification
removes manual switching: the signed policy default is fixed at connection start,
with actual-codec evidence retained. That simplification needs runtime/frontend
activation; d1 media and Premium AV1 acceptance remain unverified. Initial client fallback now selects from browser-advertised capabilities before
the first offer: policy default, then permitted VP9/H264. Unknown capabilities
retain the default; unsupported advertised decoding is not retried. Deploy the
API accepting codec_selected events before this runtime. Hosted fallback media
acceptance remains pending.

The subsequent runtime 007 VP9 failure was reproduced in Chrome using a sanitized
Dev offer: the frontend synthesized a bare VP9 capability before the advertised
profile-id=0 capability. Chrome then answered with a rejected video section
(m=video 0). With only real browser capabilities reordered, the same offer yields
an active VP9 answer and passes signalling validation; H264 also passes.
Codec preference ordering must preserve advertised profiles and never synthesize
capabilities. The local fix retains all browser capabilities and only changes
their order; signed policy enforcement remains at signalling. Hosted activation
and media verification of this correction remain pending.


| Area | Preservation rule and evidence |
| --- | --- |
| Viewer admission | Keep `createPlayerVerifyClient`, durable runtime admission gates, and signed identity attached before player registration. Query `sm_*` fields remain telemetry. Wilbur and Signalling regression suites cover these paths. |
| ICE and startup | Keep distinct player/streamer peer options. Both static and per-connection provider paths send exactly one streamer config before registry add emits identify. Provider failures fall back to the matching role's options. |
| Connection lifetime | Keep ScaleWorld websocket control-frame keepalive enabled with its existing interval/missed-pong defaults. Upstream `player_keepalive_timeout` is independently opt-in (default 0); it uses protocol messages. |
| Browser lifecycle | Keep peer-generation fences, serialized offers, same-ID streamer replacement, signed-ticket refresh/parent navigation, media evidence, first-frame overlay and the 10-second no-frame guidance. |
| Product defaults | Preserve branding, UI grouping, 30 Mbps maximum bitrate, 600-second AFK timeout and 60-second countdown, premium/standard arguments, and AV1 selection. |
| Runtime state | Entitlement projection, immutable artifacts, reconnect-grace evidence, recycle-token/generation fences, agent commands, and log/screenshot capture remain owned by the existing custom modules. |
| Web serving | Preserve no-cache HTML and rate limiting with upstream CORS/static/API options. Static files only mount when `serve` is enabled; REST-only mode now starts its HTTP listener. |
| Windows operations | Keep `start_streamer_stack.bat`, Wilbur-first launch, direct Node invocation, and intentional deletion of legacy `setup.bat`/`start_turn.bat`. |

Time-limited TURN credentials remain disabled unless a shared secret is explicitly
configured. The provider selects the existing role-specific ICE policy before
minting credentials; enabling it also requires a matching TURN-server configuration.
No TURN infrastructure migration is implied by this source upgrade. Both structured
signalling logs and Common's serialized debug protocol messages redact credentials.

## Toolchain and artifacts

`NODE_VERSION` is `v22.23.2` (Node 22 LTS). The old 22.14.0 pin is below
upstream webpack-dev-server 6 and http-proxy-middleware 4 engine requirements.
Use the pin for builds and capture both `node --version` and `npm --version`;
the verified portable distribution includes npm 10.9.8. Included portable Node
must match the pin and is measured as `portableNodeVersion`. The separate
`nodeVersion` field remains the required toolchain; it does not prove which
executable built precompiled outputs.

Workspace names, custom source imports and artifact materialization use
`@epicgames-ps/*-ue5.8`. The lockfile was reconciled and installed with `npm ci`.
Preserve workspace-local `node_modules` as well as root dependencies: Wilbur uses
Commander 12 locally while the root graph includes Commander 13. Materialized
Common/Signalling packages also retain any local dependency versions.
The runtime ZIP includes the REST API schema under `SignallingWebServer/apidoc`.
Node setup validates a replacement before activation and retains previous portable
binaries in `node-backup-*`; these backup folders are excluded from runtime ZIPs.
An ordinary serving runtime still must not build or install dependencies.

Upstream hosted-write workflows have Epic-repository guards, including npm
publication, release-PR automation, backport and stale handling. Local source
integration does not publish a package, tag, artifact, container or release.

## Local verification

From the repository root with the pinned Node directory first on PATH:

```powershell
npm ci --include=dev --no-audit --no-fund
npm run build
npm run lint
npm test --workspace Signalling -- --runInBand
npm test --workspace SignallingWebServer
npm test --workspace Frontend/library -- --runInBand
npm test --workspace Frontend/ui-library
npm exec --workspace SignallingWebServer tsc -- --noEmit
powershell -ExecutionPolicy Bypass -File BuildScripts/test-runtime-package-dependencies.ps1
powershell -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_stack_launcher_policy.ps1
powershell -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_unreal_prerequisite.ps1
powershell -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_unreal_service_class_args.ps1
powershell -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_scaleworld_process_helpers.ps1
powershell -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_platform_node_setup.ps1
# Bash/Git Bash, with LF checkout:
bash SignallingWebServer/platform_scripts/bash/test_node_setup.sh
```

Root lint includes legacy example-workspace debt. JSStreamer reports 39 unsafe-type
errors; the mediasoup bridge reports 3,278 errors with LF sources, plus CRLF errors
on Windows. Baseline-source comparison under the same upgraded rules produced the
same JSStreamer errors and 3,280 bridge errors; this is not a historical toolchain
execution. Do not hide the failures or format the entire vendor tree to clear them.
Common, Signalling, Wilbur and both frontend libraries have separate passing lint
entry points. Some other upstream workspaces have empty or placeholder scripts;
a root build does not establish end-to-end media correctness.

The reviewed graph has no production or development audit findings after updating
`eslint-plugin-tsdoc` to 0.5.2 and the bridge's coverage-report opener
`open-cli` to 9.0.0. These updates change development dependencies only.
The existing packager still copies installed development dependencies; narrowing
that payload requires preserving workspace-local runtime resolution.

## Review hardening

The post-merge review preserves existing admission and input policies while fixing
bounded failure paths:

- Ticket JSON must contain object-shaped headers and claims. Unexpected verifier
  or runtime-gate failures reject only that upgrade with HTTP 503 and no trusted
  identity. Ordinary invalid tickets still follow enforce/soft mode; off remains
  an explicit bypass. Malformed signalling envelopes are ignored without logging
  their raw bodies. Subscription and routing identifiers are checked before
  coercion; malformed or oversized WebSocket close reasons are omitted without
  losing the requested disconnect. Unhandled-message diagnostics redact secrets.
- Streamer registration rejects malformed identifiers or failed authorizers,
  keeps repeated identifiers stable, and prevents collisions when requested IDs
  already end in digits. Peer-option provider errors retain the per-role fallback
  without exposing arbitrary exception text.
- REST `/api/config` omits live transports/callbacks and redacts ICE credentials
  from its serializable diagnostic snapshot.
- Gamepads retain browser indices after disconnect and share one polling loop;
  teardown cancels/fences polling and removes listeners. Video-player teardown
  removes resize/orientation callbacks and deferred work. Viewport scale changes
  immediately re-evaluate matched resolution.
- Windows Node activation failure restores the previous runtime and failed npm
  setup returns its failure code. Bash rejects malformed version output. Runtime
  packages exclude common local state/log/environment files and validate any
  included portable Node executable. Deployment-required static TURN credentials
  remain deliberately included; see the runtime artifact contract.

## Hosted acceptance still required

Before promoting this runtime, use an immutable artifact and the exact UE 5.8.2
build on Dev, then the normal Stage gate. Verify first presented frames on direct
and forced-TURN paths; same-page reconnect and rapid streamer/Wilbur replacement;
AFK plus reconnect grace; ticket rejection and refresh; signed session identity;
standard/premium startup and entitlement projection/clear; one-shot recycle and
new-generation Ready; diagnostic/screenshot artifacts and artifact rollback.
Record the API/web/runtime identities and evidence through the canonical backlog.

No source-level test can guarantee absence of all regressions against a real GPU,
Unreal process, browser and hosted network. Existing rare zero-media and idle-gamepad
AFK investigations remain open; this merge does not claim to resolve them. The
SFU registration path retains upstream ordering and requires its own hosted media
acceptance before adoption in ScaleWorld.

### Admin direct and shadow connections

Dev runtime 007 admitted a claimless admin ticket and decoded VP8. Current code
rejects tickets without a managed identity or signed shadow target and codec policy.
VP8 is excluded from startup preferences and rejected in ticket policy validation;
historical VP8 observations remain readable.

The API preserves direct admin access: idle instances create tracked internal
sessions, owned sessions reconnect, and occupied instances issue shadow tickets.
Shadows require a live managed viewer for the signed request and policy hash,
inherit its negotiated codec and streamer, and close when that source disappears.
Their codec events are associated with the existing policy under a separate
connection ID, but their identity cannot establish managed viewer/billing evidence.
The agent advertises shadowReady only with healthy enforced codec journaling;
the API gates shadow issuance on that fresh token-bound registration. A separate
<configured audience>.shadow-v1 JWT audience also makes older runtimes reject
shadow tickets across rollback, protecting mixed-version deployments. Deploy the API gate before activating the runtime.

The corrected browser capability ordering and safe negotiation diagnostics are
also included locally. Hosted VP9, Premium AV1/fallback, tracked direct admin and
shadow/billing acceptance remain pending activation of the rebuilt artifact.
