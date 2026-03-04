# ScaleWorld Cloud Infrastructure (Source of Truth)

Last updated: 2026-03-04  
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
- TURN is a dedicated EC2 host (coturn), not colocated with each streamer.
- TURN public DNS:
  - `turn.scaleworld.net`
- Streamer startup now pulls TURN credentials from AWS SSM Parameter Store.

### Streaming Plane (Target for HTTPS + Authorization)

- Browser connects through HTTPS/WSS entrypoint (ALB + ACM).
- Session Manager API issues short-lived connect tickets.
- Pixel Streaming signalling validates tickets before accepting player sessions.
- Direct unauthenticated connection to streamer IP/DNS is removed.
- TURN remains dedicated shared tier (not per-instance TURN).

## AWS Components

### Compute

- Streamer EC2 instances (Windows):
  - Wilbur + Unreal runtime
  - Pull from private GitHub repo using deploy-key SSH alias
- TURN EC2 instances (Linux/coturn):
  - Dedicated relay tier

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

TURN server cert materials were previously managed via SSM as well (`/turn/*` pattern).

### IAM

Streamer/TURN instance role currently validated for SSM parameter retrieval with decryption in `eu-north-1`.

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

### Streamer Launcher (Implemented)

`SignallingWebServer/platform_scripts/cmd/start_dev_turn.bat` now:

1. Resolves AWS CLI path.
2. Reads TURN username/password from SSM.
3. Exports env vars for Wilbur process.
4. Starts Wilbur with split peer option files.

## Deployment and Update Flow (Streamer Instances)

Repo root helpers (implemented):

- `pull-latest.bat`: fetch + fast-forward pull current branch
- `build-all.ps1`: build Common -> Signalling -> SignallingWebServer
- `build-all.bat`: wrapper for `build-all.ps1`

Standard update flow on instance:

1. `pull-latest.bat`
2. `build-all.bat`
3. launch/restart via `start_dev_turn.bat`

## Security Model

### Current

- TURN credentials are no longer hardcoded in repo JSON.
- Credentials are loaded at runtime from SSM.
- TURN is separated from streamer host.

### In Progress / Planned

- Replace direct streamer-IP connect path with HTTPS/ticketed connect path.
- Enforce owner-only (or admin-policy) connect authorization in signalling.
- Replace third-party crash tool with in-house watchdog/service.
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
   - ensure streamer instances can read SSM TURN params.
8. Observability:
   - ALB access logs/metrics and health alarms.

Note:
- If streamer instances are made fully private, media will rely heavily on TURN (higher latency/cost tradeoff).

## Linked Runbooks / Plans

- TURN runbook: `Docs/turnserverdoc.md`
- Security baseline: `Docs/Security-Guidelines.md`
- Session-manager-side secure access plan:
  - `scaleworld-server-manager-web/docs/pixelstreaming-secure-access-plan-2026-02-22.md`
  - `scaleworld-server-manager-web/docs/pixelstreaming-https-owner-access-runbook-2026-02-23.md`

## Open Work Items (Summary)

- HTTPS ingress migration from direct streamer IP access
- Connect ticket issuance + signalling validation
- Dedicated TURN sizing/failover hardening
- Short-lived TURN credentials from API
- In-house watchdog replacement for runtime supervision
- AMI readiness validation of fully automated bootstrap

## Change Log

- 2026-03-04: Created initial cloud-infrastructure source-of-truth document; captured current validated TURN/SSM startup model and AWS prerequisites for HTTPS + ticketed access rollout.
