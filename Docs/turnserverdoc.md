# TURN Server + Pixel Streaming Integration Runbook

## Purpose

This document describes the current TURN setup and the Pixel Streaming modifications required to make it stable and repeatable.

It is written as an operational runbook so future setup/recovery can be done without re-discovery.

For full cross-cloud architecture context (AWS + control plane), see:
- `Docs/cloud-infrastructure.md`

## Final Architecture (Working)

- **Browser/Player** connects to signalling web app.
- **Signalling server (Wilbur)** brokers WebRTC negotiation between player and streamer.
- **TURN server (coturn, dedicated EC2)** relays traffic when direct path is not available.
- **Streamer (UE instance)** connects to TURN over **private VPC path**.
- **Player** connects to TURN over **public DNS** (`turn.scaleworld.net`).

Key point:
- Player and streamer must not always share identical TURN endpoints in this setup.
- Stable behavior required split peer options:
  - Player: public TURN/TURNS endpoints.
  - Streamer: private TURN endpoint.

## Why We Changed the Default Behavior

Using one shared `peerConnectionOptions` worked for some paths but caused relay instability / no media in others (negotiated state with `0 bytes`).

Root cause pattern observed:
- Streamer advertised private host candidates but TURN traffic could arrive via a different routed source path.
- Result: relay path mismatch and intermittent media failure.

Fix:
- Add **separate peer options for player and streamer** in signalling.

## Infra Components

- TURN EC2 (Ubuntu + coturn), dedicated host, Elastic IP.
- DNS record:
  - `turn.scaleworld.net` -> TURN Elastic IP.
- TLS certificate:
  - Public cert for `turn.scaleworld.net`.
  - Installed on TURN host as coturn cert/key.

## TURN Host Configuration

### coturn listener profile (current target)

- `listening-port=3478`
- `tls-listening-port=443`
- `min-port=49160`
- `max-port=51159`
- `external-ip=<public>/<private>`
- `relay-ip=<private>`
- `cert=/etc/turnserver/certs/fullchain.pem`
- `pkey=/etc/turnserver/certs/privkey.pem`

Do **not** keep conflicting flags for this profile:
- `no-tls`
- `no-udp`
- `no-tcp`

### Verify listeners

`ss -lntup | grep -E '(:443|:3478)'`

Expected:
- TCP `:443` listening
- UDP/TCP `:3478` listening

## Security Group / Network Requirements

### Client -> TURN

- TCP `443` (TURNS)
- UDP `3478` (TURN UDP)
- TCP `3478` (optional TURN TCP fallback)

### TURN relay range

- UDP `49160-51159`

### Streamer <-> TURN (inside AWS)

- Must allow relay UDP range both ways.
- Use SG-to-SG rules where possible.

Note:
- SG rules use IP/CIDR/SG references, not DNS names.

## Certificate Delivery Pattern Used

Certificate material was stored as SSM SecureString parameters:
- `/turn/cert`
- `/turn/chain`
- `/turn/key_encrypted`
- `/turn/key_passphrase`

TURN instance role required:
- `ssm:GetParameter` / `ssm:GetParameters` for `/turn/*`
- `kms:Decrypt` for the key used by those SecureStrings

Cert files on host:
- `/etc/turnserver/certs/fullchain.pem`
- `/etc/turnserver/certs/privkey.pem`

Certificate validation check:

`echo | openssl s_client -connect turn.scaleworld.net:443 -servername turn.scaleworld.net 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName`

Expected SAN includes:
- `DNS:turn.scaleworld.net`

## Pixel Streaming Source Changes

### Files changed

- `Signalling/src/SignallingServer.ts`
- `SignallingWebServer/src/index.ts`
- `SignallingWebServer/README.md`
- `SignallingWebServer/config.json`
- `SignallingWebServer/platform_scripts/cmd/start_dev_turn.bat`

### Behavior change

Added optional split config:
- `peerOptionsPlayer`
- `peerOptionsStreamer`

Fallback behavior kept:
- If split values are not provided, server still uses legacy shared `peer_options`.

### New CLI/config options

- `peer_options_player`
- `peer_options_player_file`
- `peer_options_streamer`
- `peer_options_streamer_file`

## Runtime Configuration Files

Store in:
- `SignallingWebServer/peer_options.player.json`
- `SignallingWebServer/peer_options.streamer.json`

### Player options (public path)

```json
{
  "iceServers": [
    { "urls": ["stun:stun.l.google.com:19302"] },
    {
      "urls": [
        "turn:${ENV:TURN_PUBLIC_HOST}:3478?transport=udp",
        "turns:${ENV:TURN_PUBLIC_HOST}:443?transport=tcp"
      ],
      "username": "${ENV:TURN_USERNAME}",
      "credential": "${ENV:TURN_CREDENTIAL}"
    }
  ],
  "iceTransportPolicy": "all"
}
```

### Streamer options (private VPC path)

```json
{
  "iceServers": [
    {
      "urls": [
        "turn:${ENV:TURN_PRIVATE_HOST}:3478?transport=udp",
        "turn:${ENV:TURN_PRIVATE_HOST}:3478?transport=tcp"
      ],
      "username": "${ENV:TURN_USERNAME}",
      "credential": "${ENV:TURN_CREDENTIAL}"
    }
  ],
  "iceTransportPolicy": "all"
}
```

### Signalling config reference

`SignallingWebServer/config.json` should include:

```json
{
  "peer_options_player_file": "peer_options.player.json",
  "peer_options_streamer_file": "peer_options.streamer.json"
}
```

Why:
- Relative paths are portable across machines (local workstation and EC2) and resolved from `SignallingWebServer` working directory.

### Startup script reference

`start_dev_turn.bat` now does all of the following:

- Fetches TURN username/password from SSM parameters at launch:
  - `/pixelstreaming/turn/username`
  - `/pixelstreaming/turn/credential`
- Exports them as `TURN_USERNAME` / `TURN_CREDENTIAL`.
- Fails fast if AWS CLI is unavailable or params cannot be read.
- Starts Wilbur with split player/streamer peer option files.

### Deploying endpoint selection before a new TURN host

The startup selector defaults to `SCALEWORLD_TURN_MODE=legacy-shared`. It keeps
the existing public `turn.scaleworld.net`, private `172.31.32.124`, and generic
credential paths above. No new DNS record, SSM parameter, role or TURN instance
is required to install this runtime. Deploy through an immutable runtime artifact
and a drained canary; activation still restarts the stack and needs direct and
forced-relay regression acceptance. This is preparation, not completed isolation.

`SCALEWORLD_TURN_MODE=isolated` selects only the lane's primary relay; Prod-only
`redundant` selects that relay plus the retained shared service automatically. Both are later
activations in the launch environment and resolve the established streaming lane:

| Lane / tracks | Credential parameters | Endpoint parameters and required values |
| --- | --- | --- |
| `nonprod` / `dev`, `stage` | `/pixelstreaming/nonprod/turn/{username,credential}` | `public-host` = `turn-nonprod.scaleworld.net`; `private-host` = `turn-nonprod.internal.scaleworld.net` under the same prefix |
| `prod` / `prod` | `/pixelstreaming/prod/turn/{username,credential}` | `public-host` = `turn-prod.scaleworld.net`; `private-host` = `turn-prod.internal.scaleworld.net` under the same prefix |

`resolve_turn_configuration.ps1` selects paths before any runtime parameter
request. Isolated/redundant modes refuse shared/other-lane credential overrides, clear
inherited hosts, load both hosts alongside credentials in the existing SSM batch,
and refuse missing values or mismatched DNS names before Wilbur starts. There
is no implicit fallback on an SSM failure. DNS ownership, actual relay identity,
IAM and SG enforcement still require hosted verification; a name check is not
infrastructure isolation. Legacy/isolated startup does not read fallback credentials.

Legacy emergency `TURN_USER_PARAM` / `TURN_CREDENTIAL_PARAM` overrides remain
supported except known opposite-lane paths. Clear such overrides when switching
mode. Endpoint parameter names in isolated mode are derived from the lane, not
overridable. Local direct Wilbur launches bypassing the cloud launcher must supply
`TURN_PUBLIC_HOST`, `TURN_PRIVATE_HOST`, `TURN_USERNAME` and `TURN_CREDENTIAL`.
The packager already includes both peer files and the new helper.

Before activating either new mode, provision and independently accept public/private
DNS, coturn credentials, certificate renewal/status, IAM/SGs and UDP/TLS relay data.
Set the mode only on a drained canary and verify the effective launch environment;
the current Instance Config schema does not project this switch. Roll out to
running and stopped-reusable instances before tightening legacy access.

Redundant mode is rejected for Dev/Stage before parameter reads, and by Wilbur
itself for direct launches without `SCALEWORLD_STREAMING_LANE=prod`. The planned
nonprod primary is the retained fallback host: two aliases do not provide redundancy.
Use legacy/isolated mode in nonprod; never relabel a Stage runtime as Prod to bypass
this guard. Real redundancy acceptance needs two distinct relays in an explicitly
isolated test topology or the controlled Prod canary.

Redundant mode reads `/pixelstreaming/prod/turn-fallback/{username,credential}`
in a separate two-parameter SSM batch. Both credentials must differ from the
primary. Wilbur appends a separate authenticated ICE server for the retained
public `turn.scaleworld.net` (UDP 3478/TLS 443) and private `172.31.32.124`
(UDP/TCP 3478). A global `turn_secret` is incompatible because it would replace
the separate credentials. Missing configuration fails startup; an unavailable
configured relay is handled by ICE. Both endpoints are advertised: array order
does not guarantee primary preference, and a healthy fallback can be selected
even when the primary is reachable. This is automatic redundancy, not seamless
transfer of an existing TURN allocation or strict primary/standby scheduling.

The player retries its current authenticated subscription on ICE failure or
10 seconds of continuous disconnection, at most twice per signalling connection,
only when distinct TURN hosts are configured and automatic reconnect is enabled.
The existing server-owned codec/media-generation path handles the retry. Recovery
cancels when the peer is retired or disconnected; short transient losses do not
restart media. Successful in-call failover still needs real Unreal/browser tests.

Keep the retained host as an intentional ongoing nonprod/fallback dependency,
with separate nonprod-primary and Prod-fallback users and scoped SG/IAM access. This leaves
a shared availability/security dependency; it is not complete physical isolation
or independent Prod HA. Before adding users, replace/extend
`Docs/Resources/turn/sync-coturn-creds-from-ssm.sh`: its current single-user sync
deletes every `user=` entry and would erase additional fallback users. The sync,
realm/certificate names, least-privilege reads, rotation and combined capacity
must be accepted during provisioning, before enabling redundant mode. Nonprod
must never read Prod primary secrets; the retained relay's role may read only its
explicit fallback-user parameters, never Prod signing/bootstrap/control secrets.

Emergency rollback remains available: drain, clear overrides, restore
`legacy-shared`, restart, restore the API probe target/status source and prove
forced-relay media. Do not delete the legacy material during initial migration.

The API already accepts `TurnHealth:Host`, `Port`, `AutomationStatusParameter`
and `AutomationRegion`. Keep its current settings while legacy mode serves
traffic. At dedicated-primary activation select the matching public DNS and
`/pixelstreaming/{prod,nonprod}/turn/certificate-status`; do not point operational
health at an unprovisioned candidate, or move it to fallback to conceal primary
failure. API diagnostics cannot select the runtime relay or prove media. The owning
[isolation plan](../../scaleworld-infrastructure/docs/aws-streaming-environment-isolation-plan.md)
defines the infrastructure cutover.

The bundled player reports selected-candidate relay identity over authenticated
signalling (`scaleWorldTurnRelay`, version 1). Wilbur assigns connection/sequence
identity, binds it to the admitted request, classifies either relay leg against
configured identities and sends only role metadata as `viewer_turn_relay_observed`.
Changed paths report on the next stats sample; unchanged paths report every 30
seconds. Send errors leave the report retryable and do not block legacy HTTP
telemetry. The receiver admits four burst reports, refills one per ten seconds,
and suppresses unchanged repeats inside ten seconds. Classification awaits a
shared DNS refresh for at most two seconds; failures/overlapping address aliases
remain unknown. The browser URL identifies only its own relay leg: it must not
hide a separately identified streamer fallback. An observation received before
viewer departure retains the original admitted request while DNS completes.
Raw candidate addresses/URLs and credentials are not persisted in this event.
Unavailable identity means `unknown`, not healthy. API Session Analytics exposes
additive `turnRelayUsage`; Web shows **TURN fallback used** and a warning that
persists after recovery. Wilbur also emits a warning log. This is observed session
history, not a live global outage alarm or unattended notification delivery.

Deploy API and Web consumers before the bundled runtime/player, initially with
legacy mode unchanged. Older consumers can ignore the additive event/field but
cannot show warnings. No SQL migration or minimum-runtime increase is required.
Before activation, test primary unavailable at setup, primary loss during media,
recovery, dual failure, unknown telemetry, and warning persistence. Exercise UDP
and TLS separately with increasing decoded frames/input, plus both relay legs,
rotation/restart and a combined nonprod/Prod-fallback capacity soak.

Local verification: `test_turn_configuration.ps1` exercises default/isolated
and redundant selection, failures, redaction and the actual batch bridge; it is included in
`test_stack_launcher_policy.ps1`. Wilbur integration tests read the packaged
peer files and inspect the configurations delivered to player and streamer.

Expected host requirements for this script:
- AWS CLI installed (PATH, AWS CLI v2 path, or AWS CLI v1 path)
- EC2 role can read/decrypt those two SSM SecureString parameters

Launch path:

```bat
call start.bat -- ^
  --peer_options_player_file="%ROOT%\peer_options.player.json" ^
  --peer_options_streamer_file="%ROOT%\peer_options.streamer.json"
```

## Secret Handling (Current Pattern)

- Do not commit static TURN credentials into repository JSON files.
- Keep `peer_options.player.json` and `peer_options.streamer.json` with `${ENV:...}` placeholders.
- Runtime env vars are now populated by `start_dev_turn.bat` from SSM on Windows streamer instances.
- Manual env export is still valid for ad-hoc local testing.

Fail-fast behavior:
- If either env var is missing, Wilbur exits at startup with an explicit error listing missing variable names.

## Build/Deploy Steps After Code Changes

From repo root (`C:\PixelStreaming\PixelStreaming`), use the helper scripts:

```bat
BuildScripts\pull-latest.bat
BuildScripts\build-all.bat
```

PowerShell alternative:

```powershell
.\BuildScripts\build-all.ps1
```

`BuildScripts\build-all.ps1` executes build in required order:

1. `Common`
2. `Signalling`
3. `SignallingWebServer`

Restart signalling service/process after build.

## EC2 Git Access (Validated Pattern)

Private repo pull without user login on instance:

1. Generate SSH key on instance and add `.pub` as GitHub Deploy Key (read-only) on this repo.
2. Add SSH host alias in `%USERPROFILE%\.ssh\config`:

```text
Host github-pixelstreaming
  HostName github.com
  User git
  IdentityFile ~/.ssh/pixelstreaming_ro
  IdentitiesOnly yes
```

3. Set remote URL to alias form:

```text
git@github-pixelstreaming:ScaleBendik/PixelStreaming.git
```

4. Pull with `BuildScripts\pull-latest.bat`.

## Validation Checklist

1. DNS:
   - `nslookup turn.scaleworld.net` resolves to TURN EIP.
2. TURN listeners:
   - `:443` and `:3478` are active.
3. Cert:
   - SAN includes `turn.scaleworld.net`.
4. Player receives public config in signalling logs.
5. Streamer receives private config in signalling logs.
6. Browser test (`webrtc-internals`):
   - selected candidate pair stable
   - bytes received increases during stream
7. Regression:
   - regular non-forced path works
   - forced TURN test works where expected
8. Streamer startup:
   - `start_dev_turn.bat` logs `Loaded TURN credentials from SSM parameter store.`
   - Wilbur starts without hardcoded credentials.

## TURN Credential Sanity Check Commands

Quick check from instance:

```sh
aws ssm get-parameter --name /pixelstreaming/turn/username --with-decryption --region eu-north-1 --query Parameter.Value --output text
```

## Credential Persistence vs SSM Rotation

coturn does not query SSM on every authentication request. It reads credentials from local config/userdb at startup.

This means:
- Reboot with unchanged SSM values: usually still works.
- Rotate SSM values later: coturn keeps old credentials until a sync + restart is performed.

Use this script on TURN host for one-time/manual sync:
- `Docs/Resources/turn/sync-coturn-creds-from-ssm.sh`

Optional helper to install startup sync hook (systemd `ExecStartPre`) so each coturn restart/boot re-syncs from SSM:
- `Docs/Resources/turn/install-coturn-ssm-sync.sh`

### One-time sync command

```sh
sudo bash Docs/Resources/turn/sync-coturn-creds-from-ssm.sh --restart
```

### Install boot/start sync hook

```sh
sudo bash Docs/Resources/turn/install-coturn-ssm-sync.sh
```

## Troubleshooting Quick Map

### Symptom: `WEBRTC CONNECTION NEGOTIATED` but no video (`0 bytes`)

Check:
- streamer/player split config actually loaded
- TURN relay UDP range open between streamer and TURN
- selected candidate pair in `webrtc-internals`

### Symptom: `icecandidateerror` 701 to TURN

Check:
- TURN endpoint/port in peer options
- listener present on TURN
- SG path for that protocol/port

### Symptom: TURN logs show `Cannot find credentials of user` / `401 Unauthorized`

Check:
- coturn auth mode is long-term credentials (`lt-cred-mech`) and not conflicting with `use-auth-secret`.
- correct config file is being used by coturn service (`systemctl cat coturn` / `ExecStart`).
- local coturn credentials were synced from SSM after any rotation.
- run `Docs/Resources/turn/sync-coturn-creds-from-ssm.sh --restart` and retest.

### Symptom: TURNS cert errors

Check:
- cert/key paths in `turnserver.conf`
- cert SAN contains `turn.scaleworld.net`
- server name in client URL matches cert DNS name

### Symptom: `start_dev_turn.bat` exits immediately

Check:
- Run directly in `cmd` to view raw output.
- Ensure AWS CLI can be resolved (`aws --version`).
- Ensure EC2 role can read SSM params.
- Ensure Node/Wilbur ports are not already in use (`80`, `8888`, `8889`).

## Security/Operational Notes

- Avoid committing sensitive credentials in repo.
- Prefer short-lived TURN credentials from backend over static shared credentials.
- Keep this split-config patch small to ease upstream rebases.
- If using manual file copy deployment, keep versioned backups and rollback path.

## Source of Truth

When in doubt, verify these files first:

- `Signalling/src/SignallingServer.ts`
- `SignallingWebServer/src/index.ts`
- `SignallingWebServer/config.json`
- `SignallingWebServer/peer_options.player.json`
- `SignallingWebServer/peer_options.streamer.json`
- `/etc/turnserver.conf`
