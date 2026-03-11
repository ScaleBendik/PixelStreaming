# ScaleWorld Cloud Infrastructure (Source of Truth)

Last updated: 2026-03-09
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
- API secrets/settings are managed in Azure (Key Vault-backed app settings pattern).

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

TURN server cert materials were previously managed via SSM as well (`/turn/*` pattern).

### IAM

Streamer/TURN instance role must currently support:

- SSM parameter retrieval with decryption in `eu-north-1`
- `ec2:CreateTags` for the approved `ScaleWorldRuntime*` tag keys on self

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
- `SignallingWebServer/platform_scripts/cmd/start_watchdog.bat`
- `SignallingWebServer/platform_scripts/cmd/start_stack.bat` (compatibility wrapper)

Current startup flow:

1. optional Unreal update check via `SWupdate.ps1`
2. Wilbur launch through `start_dev_turn.bat`
3. Unreal launch through `start_unreal.bat`
4. watchdog launch through `start_watchdog.bat`

Recovery flow:

- watchdog restart command points to `start_streamer_stack.bat --recovery`
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

- `pull-latest.bat`: fetch + fast-forward pull current branch
- `build-all.ps1`: build Common -> Signalling -> SignallingWebServer
- `build-all.bat`: wrapper for `build-all.ps1`
- `SWupdate.ps1`: staged Unreal updater with manifest/checksum support and rollback

Standard update/start flow on instance:

1. `pull-latest.bat`
2. `build-all.bat`
3. `start_streamer_stack.bat`

### Unreal Update Flow (Current)

`SWupdate.ps1` now supports:

1. single-line S3 build resolution using:
   - mutable manifest pointer: `Scaleworld_001/latest.json`
   - legacy direct ZIP fallback: `Scaleworld_001/ScaleWorld_Latest.zip`
2. staged extraction into `C:\PixelStreaming\releases\<buildId>`
3. download and scratch extraction on the prepared data drive when available:
   - preferred ephemeral workspace: `D:\ScaleWorldBuilds`
   - fallback local workspace: `C:\PixelStreaming\downloads` / `C:\PixelStreaming\scratch`
4. checksum validation when manifest provides SHA256
5. active install switching via junction at `C:\PixelStreaming\WindowsNoEditor`
6. rollback to previous release metadata
7. runtime status publication during update windows (`updating_infra`)

Manual and maintenance-mode helpers:

- `SignallingWebServer/platform_scripts/cmd/prepare_data_drive.bat`
- `SignallingWebServer/platform_scripts/cmd/run_unreal_update.bat`
- `SignallingWebServer/platform_scripts/powershell/invoke_update_mode.ps1`

`start_streamer_stack.bat` now checks instance maintenance tags before normal startup. If `ScaleWorldMaintenanceMode=update`, the instance runs the update path first instead of launching Wilbur/Unreal for user traffic.

Archive contract and naming rules are documented in:

- `Docs/s3-build-archive-contract.md`

## Security Model

### Current

- TURN credentials are not hardcoded in repo JSON.
- Connect-ticket signing key is no longer committed in startup scripts.
- Streamer runtime secrets are loaded from SSM at launch.
- TURN is separated from streamer host.
- Runtime tag write scope should remain limited to `ScaleWorldRuntime*`.

### In Progress / Planned

- Replace direct streamer-IP connect path with HTTPS/ticketed connect path.
- Enforce owner-only (or admin-policy) connect authorization in signalling.
- Remove legacy crash tooling once watchdog recovery is validated in dev.
- Move to short-lived TURN credentials per session/user (API-issued).

## AWS Prerequisites Before HTTPS + Ticket Implementation

Configure these before code rollout:

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

- HTTPS ingress migration from direct streamer IP access
- Connect ticket issuance + signalling validation
- Dedicated TURN sizing/failover hardening
- Short-lived TURN credentials from API
- Watchdog validation and replacement of legacy crash monitor
- Stronger app-level Unreal health detection beyond process presence
- Retention/cleanup policy for staged Unreal releases and downloaded archives
- AMI readiness validation of fully automated bootstrap

## Change Log

- 2026-03-04: Created initial cloud-infrastructure source-of-truth document; captured current validated TURN/SSM startup model and AWS prerequisites for HTTPS + ticketed access rollout.
- 2026-03-09: Updated streamer runtime source of truth to reflect canonical stack launcher, SSM-backed connect-ticket signing key, startup heartbeats, staged Unreal updater, and watchdog recovery flow.

