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
