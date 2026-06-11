# PixelStreaming Documentation

Last updated: 2026-06-11

This directory mixes upstream Pixel Streaming reference documentation with ScaleWorld operational docs for the customized streamer runtime.

## ScaleWorld Operational Docs

Use these first for the Server Manager integration:

| Area | Doc |
| --- | --- |
| Streamer AWS/TURN/runtime topology | `cloud-infrastructure.md` |
| Instance-agent bootstrap trust and secret separation | `../../scaleworld-server-manager-web/docs/instance-agent-bootstrap-trust-runbook-2026-05-05.md` |
| Prod streamer promotion process | `prod-promotions.md` |
| Stage source-instance AMI bake cleanup | `../BuildScripts/prepare-for-ami-bake.ps1` |
| Unreal ZIP update artifact contract | `s3-build-archive-contract.md` |
| PixelStreaming runtime artifact contract | `pixelstreaming-runtime-artifact-contract.md` |
| Release Train current state | `../../scaleworld-server-manager-web/docs/release-train-current-state-2026-05-22.md` |
| Runtime watchdog and startup recovery | `watchdog-runbook.md` |
| TURN server notes | `turnserverdoc.md` |
| Security guidelines | `Security-Guidelines.md` |
| Active cross-repo backlog | `../../scaleworld-server-manager-web/MASTER_BACKLOG.md` |
| User screenshot artifact contract | `../../user-session-screenshot-artifacts-plan-2026-04-29.md` |

## Current ScaleWorld Runtime Shape

1. `SignallingWebServer/platform_scripts/cmd/start_streamer_stack.bat` is the canonical Windows full-stack entrypoint.
2. `start_dev_turn.bat` launches Wilbur and loads runtime secrets/SSM parameters.
3. `start_unreal.bat` launches the Unreal application.
4. The in-house watchdog can restart Wilbur, Unreal, or the full stack and publishes `ScaleWorldRuntimeStatus*` tags.
5. The instance agent is currently embedded in Wilbur. It bootstraps to the API, sends heartbeats/runtime events, consumes desired state and commands, and registers diagnostic/screenshot artifacts. Desired-state writes are normally driven by SQL-backed session, warm-pool, and operational controls rather than ad hoc server-card UI toggles.
6. Diagnostic bundles and screenshot bundles are uploaded to S3 through AWS CLI and registered with the API for SQL-backed analytics/downloads.
7. Runtime artifact delivery is active: runtime bundles are published under `PixelStreamingRuntime/<bundleId>/`, installed into versioned `C:\PixelStreaming\runtime-releases\<bundleId>` roots, and activated by replacing `C:\PixelStreaming\PixelStreaming` with a junction to the selected bundle. `C:\PixelStreaming\PixelStreamingRuntime` is only a compatibility alias.
8. `git_ref` delivery remains the Dev fast path and the break-glass path. Stage/Prod default to `auto` so an artifact launch root wins when present.
9. Bootstrapped instances publish `ScaleWorldPixelStreamingUpdateCapabilities=pixelstreaming_runtime,combined_runtime_unreal`; Server Manager uses that tag to gate runtime-artifact and combined update jobs.
10. Repo-head startup tagging preserves runtime-artifact identity when `ScaleWorldPixelStreamingDeliveryMode=runtime_artifact` or runtime identity tags are already present without an explicit `git_ref`, so runtime-artifact server cards keep showing the active bundle id instead of reverting to a Git target ref.
11. `start_dev_turn.bat` and Wilbur defaults now align with API session access defaults: 5-minute last-viewer/reconnect grace and 10-minute first-viewer grace. The long-term backlog tracks moving lifecycle policy authority fully to the API.
12. Stage source instances intended for Prod AMI baking should run `BuildScripts\prepare-for-ami-bake.ps1` after the final runtime artifact update and before image capture. The `prepare-scaleworld-s4-for-ami-bake.bat` helper explicitly targets the current Stage bake source instance name.
13. The long-term backlog still tracks splitting the instance agent into a separate service once current warm-pool behavior is stable.

## Upstream Pixel Streaming Docs

The upstream docs remain relevant for general Pixel Streaming behavior:

- `pixel-streaming-2-migration-guide.md`
- repository root `README.md`
- `Frontend/Docs/README.md`
- `Signalling/README.md`
- `SignallingWebServer/README.md`

Do not treat upstream docs as ScaleWorld operational runbooks unless they are explicitly referenced above.
