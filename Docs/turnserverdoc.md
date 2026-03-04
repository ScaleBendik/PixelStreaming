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
        "turn:turn.scaleworld.net:3478?transport=udp",
        "turns:turn.scaleworld.net:443?transport=tcp"
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
        "turn:<turn-private-ip>:3478?transport=udp",
        "turn:<turn-private-ip>:3478?transport=tcp"
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
pull-latest.bat
build-all.bat
```

PowerShell alternative:

```powershell
.\build-all.ps1
```

`build-all.ps1` executes build in required order:

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

4. Pull with `pull-latest.bat`.

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
