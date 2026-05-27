# ScaleWorld Cloud Infrastructure (Source of Truth)

Last updated: 2026-05-27
Owner: ScaleWorld Platform

## Purpose

This document is the operational source of truth for ScaleWorld cloud infrastructure across:

- Control plane (Session Manager web/API)
- Streaming plane (Pixel Streaming, TURN, network ingress)
- Secrets, IAM, DNS, and deployment flows

## Update Policy (Keep This Current)

Update this file whenever one of the following changes:

- AWS networking, DNS, ALB/NLB, SG, IAM, Route53, ACM
- TURN topology, credentials, or port profile
- Pixel Streaming instance bootstrap/startup flow
- Authorization/connect flow (ticketing, token validation)
- Azure app settings or Key Vault secret model affecting connect/auth

Minimum update steps for every infra change:

1. Update relevant section(s) in this file.
2. Add an entry to the change log at the bottom.
3. If TURN-specific, also update `Docs/turnserverdoc.md`.

## Environments

- `local`: developer workstation
- `dev`: active integration environment
- `stage`: pre-production validation
- `prod`: production

## High-Level Architecture

### Control Plane (Current)

- Session Manager web: user UI for instance lifecycle and connect actions.
- Session Manager API: ownership checks, start/stop orchestration, runtime state.
- API `ConnectTicket__SigningKey` now comes from Azure Key Vault-backed workload env injection.
- API repo `appsettings` no longer carry active hosted connect-ticket signing keys.

### Streaming Plane (Current)

- Streamer instances run:
  - Unreal application
  - Pixel Streaming SignallingWebServer (Wilbur)
  - startup/watchdog scripts under `SignallingWebServer/platform_scripts`
- TURN is a dedicated EC2 host (coturn), not colocated with each streamer.
- TURN public DNS:
  - `turn.scaleworld.net`
- Streamer startup pulls TURN credentials and the connect-ticket signing key from AWS SSM Parameter Store.

### Streaming Plane (Target for HTTPS + Authorization)

- Browser connects through HTTPS/WSS entrypoint (ALB + ACM).
- Session Manager API issues short-lived connect tickets.
- Pixel Streaming signalling validates tickets before accepting player sessions.
- Direct unauthenticated connection to streamer IP/DNS is removed.
- TURN remains dedicated shared tier (not per-instance TURN).

## AWS Components

### Compute

- Streamer EC2 instances (Windows):
  - `start_streamer_stack.bat` as the canonical boot entrypoint
  - Wilbur + Unreal runtime
  - watchdog-driven recovery path
  - optional Unreal update check before launch
- TURN EC2 instances (Linux/coturn):
  - dedicated relay tier

### DNS and Certificates

- Route53 hosted zone includes:
  - `turn.scaleworld.net` -> TURN Elastic IP (current)
- ACM certificate used for TURN TLS (`turn.scaleworld.net`) on coturn host.
- Planned:
  - stream-facing HTTPS domain behind ALB for player traffic.

### Secrets and Parameters

Current SSM SecureString parameters used by streamer startup:

- `/pixelstreaming/turn/username`
- `/pixelstreaming/turn/credential`
- `/pixelstreaming/connect-ticket/signing-key`
- `/pixelstreaming/prod/connect-ticket/signing-key`

Target SSM SecureString parameters for instance-agent bootstrap secrets:

- `/pixelstreaming/dev/instance-agent-bootstrap-shared-secret`
- `/pixelstreaming/stage/instance-agent-bootstrap-shared-secret`
- `/pixelstreaming/prod/instance-agent-bootstrap-shared-secret`

The instance-agent bootstrap secret must be separate from the connect-ticket signing key. The same secret value is copied only between one environment's Azure Key Vault secret and that same environment's AWS SSM parameter. Do not share the value between Dev, Stage, and Prod.

Current SSM String parameter used for prod streamer release pinning:

- `/pixelstreaming/prod/git-target-ref`

Current SSM String parameters used for dev/stage streamer release pinning:

- `/pixelstreaming/dev/git-target-ref`
- `/pixelstreaming/stage/git-target-ref`

Legacy compatibility fallback during the lane split migration. Do not use this as a canonical promotion target:

- `/pixelstreaming/nonprod/git-target-ref`

Planned replacement for normal PixelStreaming code promotion:

- immutable runtime manifests under `s3://scaleworlddepot/PixelStreamingRuntime/`
- canonical contract: `pixelstreaming-runtime-artifact-contract.md`
- Fleet update mode can now install and validate `pixelstreaming_runtime` manifests from stopped instances
- provisioning mode can now install a runtime manifest when launch/provisioning tags include `ScaleWorldTargetRuntimeManifestKey`
- release candidates point at runtime manifest keys instead of promoted Git refs; the API candidate store and first Release page capture/pin actions exist, while validation evidence, idempotent promotion orchestration, shared/SQL candidate storage, rollback, and capacity convergence remain in progress
- Git target refs remain compatibility and break-glass inputs during migration
- delivery mode is explicit:
  - Dev defaults to `git_ref` so `/pixelstreaming/dev/git-target-ref` remains the fast iteration path
  - Stage/Prod default to `auto` so active runtime artifacts win when installed, with pinned git-ref fallback during migration
  - `ScaleWorldPixelStreamingDeliveryMode=runtime_artifact` forces artifact startup and fails closed if no active runtime is installed

Current Azure Key Vault secret used by the API workload for connect tickets:

- `kv-scaleworld-dev` -> `connect-ticket-signing-key`
- `kv-scaleworld-stage` -> `connect-ticket-signing-key`
- `kv-scaleworld-prod` -> `connect-ticket-signing-key`

Target Azure Key Vault secret used by the API workload for instance-agent bootstrap:

- `kv-scaleworld-dev` -> `instance-agent-bootstrap-shared-secret`
- `kv-scaleworld-stage` -> `instance-agent-bootstrap-shared-secret`
- `kv-scaleworld-prod` -> `instance-agent-bootstrap-shared-secret`

Current note:
- `dev` and `stage` intentionally still share the same active connect-ticket signer on the streamer side
- instance-agent bootstrap secrets should not share that connect-ticket signer; use separate `instance-agent-bootstrap-shared-secret` values per environment
- prod lane is now live for normal Session Manager traffic
- prod API startup requires `kv-scaleworld-prod/connect-ticket-signing-key` to be populated with the real prod signing key and that value must match streamer-side SSM `/pixelstreaming/prod/connect-ticket/signing-key`
- streamer startup is now lane-aware through `SCALEWORLD_STREAMING_LANE=nonprod|prod`
- startup also supports a deployment-track override through:
  - instance tag `ScaleWorldDeploymentTrack=dev|stage|prod`
  - fallback env `SCALEWORLD_DEPLOYMENT_TRACK=dev|stage|prod`
- if the instance tag resolves successfully, that value overrides stale inherited machine `SCALEWORLD_DEPLOYMENT_TRACK`
- current intended deployment-track model:
  - dev fleet and any remaining Gold instance -> tag `ScaleWorldDeploymentTrack=dev`
  - stage fleet -> tag `ScaleWorldDeploymentTrack=stage`
  - prod fleet -> tag `ScaleWorldDeploymentTrack=prod`
- current bootstrap defaults are:
  - `nonprod` -> SSM `/pixelstreaming/connect-ticket/signing-key`, issuer `scaleworld-dev-connect-ticket`
  - `prod` -> SSM `/pixelstreaming/prod/connect-ticket/signing-key`, issuer `scaleworld-prod-connect-ticket`
- lane-wide instance-agent control-plane targeting now uses a paired API URL + environment model:
  - `INSTANCE_AGENT_API_BASE_URL=<absolute-http(s)-url>` remains available as an explicit per-instance override
  - `INSTANCE_AGENT_CONTROL_PLANE_ENV=dev|stage|prod` remains available as an explicit per-instance override
  - nonprod deployment-track parameters:
    - dev API URL: `/pixelstreaming/dev/instance-agent-api-base-url`
    - dev control-plane env: `/pixelstreaming/dev/instance-agent-control-plane-env`
    - stage API URL: `/pixelstreaming/stage/instance-agent-api-base-url`
    - stage control-plane env: `/pixelstreaming/stage/instance-agent-control-plane-env`
    - legacy fallback API URL: `/pixelstreaming/nonprod/instance-agent-api-base-url`
    - legacy fallback control-plane env: `/pixelstreaming/nonprod/instance-agent-control-plane-env`
  - normal prod lane parameters:
    - API URL: `/pixelstreaming/prod/instance-agent-api-base-url`
    - control-plane env: `/pixelstreaming/prod/instance-agent-control-plane-env`
  - startup resolves the effective control-plane env before loading the bootstrap secret:
    - a known hosted API URL wins so URL and secret stay paired even if the env parameter is stale
    - known URL mapping: `scaleaq-dev.net` -> `dev`, `scaleaq-stage.net` -> `stage`, `scaleaq.net` -> `prod`
    - unknown/custom URLs use the explicit/lane control-plane env parameter
    - if neither URL nor env is set, startup falls back to deployment-track defaults
  - the bootstrap secret SSM path is derived from the effective control-plane env when `INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM` is not set:
    - `dev` -> `/pixelstreaming/dev/instance-agent-bootstrap-shared-secret`
    - `stage` -> `/pixelstreaming/stage/instance-agent-bootstrap-shared-secret`
    - `prod` -> `/pixelstreaming/prod/instance-agent-bootstrap-shared-secret`
  - startup refuses a prod control-plane env on the nonprod streaming lane and refuses non-prod envs on the prod streaming lane
  - `INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET_PARAM=<ssm-path>` remains available as an explicit emergency override
  - `INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF=true` to make Wilbur fail bootstrap instead of falling back when IMDS identity proof is unavailable
  - if no explicit override or lane parameter is present, startup still falls back to deployment-track defaults:
    - `dev` -> `https://scaleworld.api.scaleaq-dev.net`
    - `stage` -> `https://scaleworld.api.scaleaq-stage.net`
    - `prod` -> `https://scaleworld.api.scaleaq.net`
- TURN credentials still default to the current shared SSM paths for all lanes
- cloud startup now enables Wilbur reverse-proxy mode by default
  - `ENABLE_REVERSE_PROXY=true`
  - `REVERSE_PROXY_NUM_PROXIES=1`
  - this matches the current ALB/X-Forwarded-For path and avoids `express-rate-limit` proxy warnings
- repo/bootstrap sync policy now supports:
  - `SCALEWORLD_GIT_SYNC_MODE=upstream|pinned|off`
  - default `nonprod` behavior: `pinned` through deployment track `dev` or `stage`
  - default `prod` behavior: `pinned`
  - deployment-track defaults:
    - `dev` -> `pinned` with `SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/dev/git-target-ref;/pixelstreaming/nonprod/git-target-ref`
    - `stage` -> `pinned` with `SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/stage/git-target-ref;/pixelstreaming/nonprod/git-target-ref`
    - `prod` -> `pinned` with `SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/prod/git-target-ref`
  - `SCALEWORLD_GIT_TARGET_REF=<tag-or-commit>` or `SCALEWORLD_GIT_TARGET_REF_PARAM=<ssm-parameter-name>` is required for `pinned`
  - boot-time repo sync now defaults on for any sync mode except `off`
  - recommended prod launch-template setting:
    - `SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/prod/git-target-ref`
  - recommended dev warm-pool launch-template / provisioning tag setting:
    - `ScaleWorldDeploymentTrack=dev`
  - recommended stage launch-template / provisioning tag setting:
    - `ScaleWorldDeploymentTrack=stage`
  - note:
    - explicit machine env vars such as `SCALEWORLD_GIT_TARGET_REF_PARAM`, `INSTANCE_AGENT_API_BASE_URL`, or `INSTANCE_AGENT_API_BASE_URL_PARAM` still override the derived defaults if they were manually set on the box
    - `SCALEWORLD_GIT_SYNC_MODE=upstream` is not accepted for `stage` or `prod`; startup forces those deployment tracks back to `pinned` so the environment-specific SSM target ref remains authoritative
  - normal prod boot through `start_streamer_stack.bat` now applies pinned repo sync before the stack launch
  - if the AMI repo/build baseline is behind the promoted prod tag, first boot may spend several minutes in repo reset + `BuildScripts/build-all.bat` before Wilbur starts

TURN server cert materials were previously managed via SSM as well (`/turn/*` pattern).
The canonical instance-agent bootstrap trust runbook is `../../scaleworld-server-manager-web/docs/instance-agent-bootstrap-trust-runbook-2026-05-05.md`.

Screenshot bundle retention is currently three days. Keep the S3 lifecycle rule for `PixelStreamingScreenshots/*`, the streamer default `INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS`, and the Server Manager API `UserSessionArtifacts:ScreenshotRetentionDays` setting aligned so user-facing download availability does not outlive the object.

### IAM

Streamer/TURN instance role must currently support:

- SSM parameter retrieval with decryption in `eu-north-1`
- `s3:GetObject` for approved Unreal update artifacts and, after runtime-artifact rollout, `s3://scaleworlddepot/PixelStreamingRuntime/*`
- `ec2:CreateTags` for the approved runtime/session tag keys on self:
  - `ScaleWorldRuntime*`
  - `ScaleWorldPixelStreamingVersion`
  - `ScaleWorldPixelStreamingDeliveryMode`
  - `ScaleWorldPixelStreamingRuntimeBundleId`
  - `ScaleWorldPixelStreamingRuntimeManifestKey`
  - `ScaleWorldPixelStreamingRuntimeArtifactKey`
  - `ScaleWorldPixelStreamingRuntimeSourceCommit`
  - `ScaleWorldPixelStreamingRuntimeContractVersion`
  - `ScaleWorldSessionNetworkPathSessionId`
  - `ScaleWorldSessionTurnUsed`
  - `ScaleWorldSessionRelayProtocol`
  - `ScaleWorldSessionCandidateType`

Normal serving dev/stage/prod instance roles should keep read-only SSM access for their active lane plus the temporary legacy fallback while the AMI/bootstrap migration is in progress:

- `ssm:GetParameter` on:
  - `/pixelstreaming/dev/git-target-ref`
  - `/pixelstreaming/stage/git-target-ref`
  - `/pixelstreaming/prod/git-target-ref`
  - `/pixelstreaming/nonprod/git-target-ref` (temporary fallback only)
  - `/pixelstreaming/nonprod/instance-agent-api-base-url` (temporary fallback only)
  - `/pixelstreaming/nonprod/instance-agent-control-plane-env` (temporary fallback only)
  - `/pixelstreaming/stage/instance-agent-api-base-url`
  - `/pixelstreaming/stage/instance-agent-control-plane-env`
  - `/pixelstreaming/prod/instance-agent-api-base-url`
  - `/pixelstreaming/prod/instance-agent-control-plane-env`

Gold/stage-prod promotion operator context must also support:

- `ssm:GetParameter` on `/pixelstreaming/stage/git-target-ref`
- `ssm:GetParameter` on `/pixelstreaming/prod/git-target-ref`
- `ssm:GetParameter` on `/pixelstreaming/stage/instance-agent-api-base-url`
- `ssm:GetParameter` on `/pixelstreaming/stage/instance-agent-control-plane-env`
- `ssm:GetParameter` on `/pixelstreaming/prod/instance-agent-api-base-url`
- `ssm:GetParameter` on `/pixelstreaming/prod/instance-agent-control-plane-env`
- `ssm:PutParameter` on `/pixelstreaming/stage/git-target-ref`
- `ssm:PutParameter` on `/pixelstreaming/prod/git-target-ref`
- `ssm:PutParameter` on `/pixelstreaming/stage/instance-agent-api-base-url`
- `ssm:PutParameter` on `/pixelstreaming/stage/instance-agent-control-plane-env`
- `ssm:PutParameter` on `/pixelstreaming/prod/instance-agent-api-base-url`
- `ssm:PutParameter` on `/pixelstreaming/prod/instance-agent-control-plane-env`
- `ssm:DeleteParameter` on `/pixelstreaming/stage/instance-agent-api-base-url`
- `ssm:DeleteParameter` on `/pixelstreaming/stage/instance-agent-control-plane-env`
- `ssm:DeleteParameter` on `/pixelstreaming/prod/instance-agent-api-base-url`
- `ssm:DeleteParameter` on `/pixelstreaming/prod/instance-agent-control-plane-env`

Workstation/manual dev-pool target updates may additionally need:

- `ssm:GetParameter` on `/pixelstreaming/dev/git-target-ref`
- `ssm:PutParameter` on `/pixelstreaming/dev/git-target-ref`

Workstation/manual runtime artifact publishing needs:

- `s3:PutObject` on `arn:aws:s3:::scaleworlddepot/PixelStreamingRuntime/*`
- `s3:GetObject` on `arn:aws:s3:::scaleworlddepot/PixelStreamingRuntime/*`
- optional `s3:ListBucket` on `arn:aws:s3:::scaleworlddepot` constrained to the `PixelStreamingRuntime/` prefix so `BuildScripts\publish-runtime-artifact.ps1` can select the next bundle id without falling back to local-only names

Current hardening note:

- Gold should use a dedicated EC2 role / instance profile for release-ref writes
- normal stage/prod serving instances should not retain `ssm:PutParameter` on the promotion refs

### Security Groups

Current intended split:

- prod streamer SG:
  - ALB and TURN/media ingress only
  - no inbound `3389`
- Gold/nonprod debug SG:
  - same runtime ingress
  - optional break-glass/admin `3389` while nonprod still requires it

Operational note:

- keep RDP out of prod
- prefer SSM/Fleet-based operations over RDP for serving instances

## Pixel Streaming Runtime Configuration

### Split Peer Options (Implemented)

- Player options file:
  - `SignallingWebServer/peer_options.player.json`
- Streamer options file:
  - `SignallingWebServer/peer_options.streamer.json`

Both use env placeholders:

- `${ENV:TURN_USERNAME}`
- `${ENV:TURN_CREDENTIAL}`

### Signalling Config (Implemented)

`SignallingWebServer/config.json` uses relative paths:

- `peer_options_player_file: "peer_options.player.json"`
- `peer_options_streamer_file: "peer_options.streamer.json"`

### Windows Startup Stack (Implemented)

Canonical Windows entrypoint:

- `SignallingWebServer/platform_scripts/cmd/start_streamer_stack.bat`

Supporting scripts:

- `SignallingWebServer/platform_scripts/cmd/start_dev_turn.bat`
- `SignallingWebServer/platform_scripts/cmd/start_unreal.bat`

### Fleet Provisioning Template Baseline (Current)

Approved launch templates used by Fleet provisioning should already boot into the same validated Windows runtime stack:

- PixelStreaming repo checkout present on disk
- `SignallingWebServer/platform_scripts/cmd/start_streamer_stack.bat` as the canonical startup entrypoint
- SSM parameter access for TURN credentials and connect-ticket signing key
- runtime status tags emitted normally after boot

Fleet provisioning now assumes the API will:

- launch the template into `ScaleWorldMaintenanceMode=provisioning`
- create the per-instance target group and ALB host rule
- wait for target health and runtime `ready`
- only then clear provisioning maintenance and expose the instance to the normal pool
- during provisioning maintenance, Wilbur suppresses no-viewer idle-stop timers and the watchdog uses an extended streamer-health startup grace so long Unreal shader/precache warmup does not trigger premature stop/restart
- `SignallingWebServer/platform_scripts/cmd/start_watchdog.bat`
- `SignallingWebServer/platform_scripts/cmd/start_stack.bat` (compatibility wrapper)

Current startup flow:

1. optional Unreal update check via `SWupdate.ps1`
2. Wilbur launch through `start_dev_turn.bat`
3. Unreal launch through `start_unreal.bat`
4. watchdog launch through `start_watchdog.bat`

Current lane selection:

- startup first tries to resolve the instance tag:
  - `ScaleWorldLane=nonprod|prod`
- temporary migration compatibility also accepts the typo:
  - `ScaleWorldlane=nonprod|prod`
- if the instance tag resolves successfully, that value overrides any stale inherited machine `SCALEWORLD_STREAMING_LANE`
- if no lane tag is available, startup still supports:
  - `SCALEWORLD_STREAMING_LANE=nonprod`
  - `SCALEWORLD_STREAMING_LANE=prod`
- if neither tag nor env is available, startup falls back to:
  - `nonprod`
- explicit env overrides still win when set:
  - `TURN_USER_PARAM`
  - `TURN_CREDENTIAL_PARAM`
  - `CONNECT_TICKET_SIGNING_KEY_PARAM`
  - `CONNECT_TICKET_ISSUER`
- Wilbur auth settings now resolve from process environment instead of carrying the signing key on the startup command line

Recovery flow:

- watchdog restart command points to `start_streamer_stack.bat --recovery`
- recovery-mode stack launches keep watchdog supervision enabled even if Wilbur or Unreal startup fails
- Wilbur startup reloads TURN credentials and connect-ticket signing key from SSM

### Runtime Status Ownership (Implemented)

Current ownership model:

- startup script owns `booting` / `updating_infra`
- signalling owns `waiting_for_streamer` / `ready`
- idle-stop owns `idle_shutdown_pending` / `stopping`
- watchdog owns `runtime_fault`

Startup uses `runtime-status-heartbeat.ps1` to keep long-running startup states fresh until steady-state signalling heartbeats take over.

### Watchdog (Implemented, Dev Validation)

Current watchdog files:

- `SignallingWebServer/platform_scripts/powershell/watchdog.ps1`
- `SignallingWebServer/platform_scripts/cmd/start_watchdog.bat`
- `Docs/watchdog-runbook.md`

The watchdog now has a defined restart path through the stack launcher, but full removal of legacy crash tooling still depends on end-to-end dev validation.

## Deployment and Update Flow (Streamer Instances)

Repo root helpers:

- `BuildScripts/pull-latest.bat`: fetch + fast-forward pull current branch
- `BuildScripts/build-all.ps1`: build Common -> Signalling -> SignallingWebServer
- `BuildScripts/build-all.bat`: wrapper for `BuildScripts/build-all.ps1`
- `BuildScripts/promote-prod-streamer-release.bat`: wrapper for prod promotion/tagging
- `SWupdate.ps1`: staged Unreal updater with explicit ZIP-key targeting and rollback

Compatibility note:

- root-level `build-all.*` and `pull-latest.bat` wrappers remain for backward compatibility, but operator use should prefer `BuildScripts/`

Standard update/start flow on instance:

1. fetch latest PixelStreaming repo changes
2. fast-forward pull and `BuildScripts/build-all.bat` only when upstream changed
3. run `start_streamer_stack.bat`

Current prod startup note:

1. prod launch normally relies on the AMI already containing the intended promoted code/build outputs
2. `start_streamer_stack.bat` still applies pinned repo sync on prod boot as a safety net
3. if the checkout/build stamp already match the promoted prod tag, startup should skip rebuild
4. if the AMI is behind, prod boot can self-heal by resetting to the promoted tag and running `BuildScripts/build-all.bat`, but this makes launch materially slower

Prod promotion flow:

1. validate the desired PixelStreaming commit on the gold/nonprod baseline
2. bake the gold AMI from that same validated commit
3. run `BuildScripts/promote-prod-streamer-release.bat -Region eu-north-1` from the operator workstation or validated gold instance
4. the script creates an annotated tag using:
   - `pixelstreaming-prod-ddmmyyyy<letter>`
5. the script either:
   - promotes checked-out `HEAD` after verifying it exactly matches `origin/<current-branch>`
   - or promotes `-TargetCommit <sha-or-ref>` after verifying fetched `origin/*` contains it
6. the script pushes the tag and updates:
   - `/pixelstreaming/prod/git-target-ref`
7. the script records the promotion in:
   - `Docs/prod-promotions.local.md`
   - this file is intentionally untracked so promotions do not block future pulls on the machine that ran the promotion
8. prod streamer instances in `pinned` mode resolve their startup ref from that SSM parameter at normal boot

### Unreal Update Flow (Current)

`SWupdate.ps1` now supports:

1. explicit S3 ZIP targeting using an exact object key such as `ScaleworldBuilds/ScaleWorld_2026-03-10-01.zip`
2. staged extraction into `C:\PixelStreaming\releases\<buildId>`
3. download and scratch extraction on the prepared data drive when available:
   - preferred ephemeral workspace: `D:\ScaleWorldBuilds`
   - fallback local workspace: `C:\PixelStreaming\downloads` / `C:\PixelStreaming\scratch`
4. active install switching via junction at `C:\PixelStreaming\WindowsNoEditor`
5. rollback to previous release metadata
6. runtime status publication during update windows (`updating_infra`)

Manual and maintenance-mode helpers:

- `SignallingWebServer/platform_scripts/cmd/prepare_data_drive.bat`
- `SignallingWebServer/platform_scripts/cmd/run_unreal_update.bat`
- `SignallingWebServer/platform_scripts/powershell/invoke_update_mode.ps1`

`start_streamer_stack.bat` now checks instance maintenance tags before normal startup.

- If `ScaleWorldMaintenanceMode=update`, the instance runs the update path first instead of launching Wilbur/Unreal for user traffic.
- If `ScaleWorldMaintenanceMode=provisioning`, the instance runs a bounded provisioning bootstrap first. That bootstrap waits for fresh-launch prerequisites, syncs the PixelStreaming repo if upstream changed, runs `BuildScripts/build-all.bat` when needed, installs the tagged PixelStreaming runtime artifact when `ScaleWorldTargetRuntimeManifestKey` is present, and then continues into normal Wilbur/Unreal startup. This keeps normal restarts fast while making new launches self-healing even if the AMI repo is behind or Windows networking is not ready at the first scheduler tick.
- If delivery mode is `runtime_artifact`, startup requires `C:\PixelStreaming\PixelStreamingRuntime` to point at an installed runtime bundle.
- If delivery mode is `auto`, startup delegates to that active runtime when present and otherwise falls back to pinned git-ref sync.
- If delivery mode is `git_ref`, startup ignores installed runtime artifacts and follows the deployment-track target ref. This is the Dev default.

During Unreal maintenance-mode updates, `invoke_update_mode.ps1` also syncs the PixelStreaming repo before running `SWupdate.ps1`:

1. `git fetch --prune`
2. compare `HEAD` with the configured upstream branch
3. if upstream changed and there are no tracked local edits, run `git pull --ff-only`
4. run `BuildScripts/build-all.bat`
5. continue with the Unreal update sequence

If tracked local changes exist in the repo, the maintenance update fails fast instead of overwriting instance-local edits.

Prerequisite: the instance must have a valid PixelStreaming git checkout and Git installed so update mode can fetch/pull before building.

During PixelStreaming runtime maintenance-mode updates, `invoke_update_mode.ps1` does not build on the serving instance. It downloads the selected runtime manifest, verifies and installs the ZIP through `install_pixelstreaming_runtime.ps1`, switches the active runtime junction, launches validation from the active runtime root, publishes runtime identity tags, and stops for API reconciliation.

Combined Unreal ZIP plus PixelStreaming runtime updates use `ScaleWorldUpdateTargetType=combined_runtime_unreal`. The instance prepares the runtime artifact in the background while the Unreal payload is prepared, fails before activation if either prepare step fails, activates the runtime artifact, activates the Unreal release, validates once from the active runtime launcher, publishes both `ScaleWorldCurrentBuild` and the runtime identity tags, and then stops for API reconciliation.

Migration prerequisite: current live/stopped instances must first receive this bootstrap/updater code through the legacy repo-sweep/git-ref path or a refreshed base AMI. After that one-time bootstrap rollout, they publish `ScaleWorldPixelStreamingUpdateCapabilities=pixelstreaming_runtime,combined_runtime_unreal`, and small PixelStreaming runtime changes should use runtime manifests instead of AMI bakes.

Current limitation: combined activation is not transactional. If activation or validation fails after one payload has already been activated, the instance remains in failed update maintenance state and should be inspected or repaired manually. Runtime rollback and a versioned updater compatibility contract are planned follow-ups.

Provisioning mode uses the same shared repo-sync helper:

- `SignallingWebServer/platform_scripts/powershell/ensure_repo_current.ps1`
- `SignallingWebServer/platform_scripts/powershell/invoke_provisioning_mode.ps1`

Recommended Task Scheduler settings for fresh launches:

1. trigger: `At startup`
2. delay: `20 seconds`
3. if the task fails, restart every `1 minute`
4. attempt restart up to `30` times

Recommended provisioning bootstrap env vars:

- `SCALEWORLD_PROVISIONING_BOOTSTRAP_TIMEOUT_SECONDS` default `900`
- `SCALEWORLD_PROVISIONING_DETECTION_TIMEOUT_SECONDS` default `90`
- `SCALEWORLD_PROVISIONING_BOOTSTRAP_RETRY_DELAY_SECONDS` default `15`

Successful maintenance-mode update no longer clears Fleet command tags on the instance itself. The instance records the terminal result and requests stop, and the API clears Fleet command tags after it observes the stopped instance for the matching update job.

Archive contract and naming rules are documented in:

- `Docs/s3-build-archive-contract.md`

## Security Model

### Current

- TURN credentials are not hardcoded in repo JSON.
- API-side connect-ticket signing key is no longer committed in hosted API config.
- Streamer runtime secrets are loaded from SSM at launch.
- Active dev/stage connect-ticket signing key rotation was validated on 2026-03-19.
- TURN is separated from streamer host.
- Runtime tag write scope should remain limited to the approved runtime/session keys above; avoid broad `ec2:CreateTags` grants beyond those keys.

### Current Security Gaps

- nonprod streamer startup still reads the signing key from the shared generic SSM path
- streamer startup still loads the signing key into process environment at launch time
- stage still shares the dev-shaped connect-ticket contract
- prod is now live, but the prod API Key Vault signer and streamer-side prod SSM signer must remain aligned
- the Windows runtime still relies on the current shared autologon/admin access pattern

### Completed Baseline And Remaining Work

- HTTPS/ticketed connect is the normal Session Manager path.
- Owner/admin connect authorization is enforced through API-issued connect tickets and Wilbur ticket validation.
- Remove legacy crash tooling once watchdog recovery is validated in dev.
- Move to short-lived TURN credentials per session/user (API-issued).

## AWS HTTPS/Ticketing Runtime Prerequisites

Keep these verified before routing live traffic or changing streamer topology:

1. Route53 stream domain plan:
   - choose domain pattern for HTTPS stream entrypoint.
2. ACM cert for stream domain:
   - DNS validated in same region as ALB.
3. Internet-facing ALB:
   - HTTPS listener (`443`) with ACM cert.
4. Target groups and routing strategy:
   - deterministic route to intended streamer target.
5. Security groups:
   - streamer ingress only from ALB/gateway SG (no broad public access).
6. TURN SG/profile:
   - keep dedicated TURN ports/range aligned to coturn config.
7. Instance role permissions:
   - ensure streamer instances can read SSM TURN params and connect-ticket signing key.
8. Observability:
   - ALB access logs/metrics and health alarms.

Note:
- If streamer instances are made fully private, media will rely heavily on TURN (higher latency/cost tradeoff).

## Linked Runbooks / Plans

- TURN runbook: `Docs/turnserverdoc.md`
- Security baseline: `Docs/Security-Guidelines.md`
- Watchdog runbook: `Docs/watchdog-runbook.md`
- Session-manager-side secure access plan:
  - `scaleworld-server-manager-web/docs/pixelstreaming-secure-access-plan-2026-02-22.md`
  - `scaleworld-server-manager-web/docs/pixelstreaming-https-owner-access-runbook-2026-02-23.md`

## Open Work Items (Summary)

- Keep HTTPS/ticketed ingress healthy while removing any leftover direct-IP operational shortcuts
- Complete Dev/Stage/Prod deployment-track separation inside the nonprod/prod streamer pools and control-plane selection
- Nonprod rename from dev-shaped issuer/key contract to proper nonprod contract
- Env-specific streamer SSM parameter names for TURN credentials and connect-ticket signing key
- Keep Prod API/control-plane isolated on the prod lane and verify launch-template tags include `ScaleWorldDeploymentTrack=prod`
- Runtime access hardening for Windows autologon vs human admin access
- Dedicated TURN sizing/failover hardening
- Short-lived TURN credentials from API
- Watchdog validation and replacement of legacy crash monitor
- Stronger app-level Unreal health detection beyond process presence
- Retention/cleanup policy for staged Unreal releases and downloaded archives
- AMI readiness validation of fully automated bootstrap

## Change Log

- 2026-03-04: Created initial cloud-infrastructure source-of-truth document; captured current validated TURN/SSM startup model and AWS prerequisites for HTTPS + ticketed access rollout.
- 2026-03-09: Updated streamer runtime source of truth to reflect canonical stack launcher, SSM-backed connect-ticket signing key, startup heartbeats, staged Unreal updater, and watchdog recovery flow.
- 2026-03-19: Documented the API-side Key Vault secret cutover, validated dev/stage key rotation, and the remaining shared-streamer SSM/key-exposure gaps.
- 2026-03-19: Added lane-aware streamer startup defaults for `nonprod` and `prod`, while keeping current nonprod behavior unchanged.
- 2026-03-19: Removed connect-ticket signing key exposure from the Wilbur command line and redacted sensitive startup config logging.
- 2026-03-20: Added SSM-backed prod streamer promotion flow, `BuildScripts/` operator entrypoints, runtime-status publish ordering fixes, and provisioning-heartbeat visibility during repo/bootstrap work.
- 2026-03-21: Added helper-based lane fallback from instance tag `ScaleWorldLane` (with temporary `ScaleWorldlane` compatibility), switched prod promotion ledger writes to a local untracked file, fixed annotated-tag pinned-sync resolution, added a stale-HEAD guard to prod promotion, and validated a dark-launch prod instance booting successfully in the prod lane after pinned catch-up.
- 2026-03-22: Added a manual dark-connect helper (`mint-prod-dark-connect-ticket.ps1`) and validated end-to-end prod dark connect through manual ALB routing plus a prod-shaped ticket against the current promoted prod ref.
- 2026-05-15: Hardened stage/prod streamer startup so stale machine-level `SCALEWORLD_GIT_SYNC_MODE=upstream` cannot bypass the stage/prod SSM target refs.
- 2026-05-21: Added the immutable PixelStreaming runtime artifact direction, S3 manifest/ZIP contract, Fleet runtime update install path, provisioning tag hook, explicit git-ref/runtime-artifact delivery mode split, and migration note that existing instances need a one-time bootstrap update before runtime artifact jobs can run.
- 2026-05-22: Added release-candidate store status, runtime-artifact publisher IAM, first manifest-backed Release page candidate capture/pin actions, and clarified that Git target refs are now Dev/bootstrap/break-glass migration paths rather than the long-term Stage/Prod release object.
- 2026-05-27: Documented the runtime update capability tag used by Server Manager to gate runtime-artifact and combined update jobs, and narrowed the remaining update follow-up to a versioned updater compatibility contract plus rollback semantics.

