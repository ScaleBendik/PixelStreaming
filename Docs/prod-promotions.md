# Prod Streamer Promotions

This document is the current reference for how prod streamer code is promoted.

## Current Model

Prod streamer startup should not track moving upstream directly.

Current prod model:
1. validate the desired PixelStreaming commit on the gold/nonprod baseline
2. bake the gold AMI from that same validated commit
3. create an immutable annotated prod tag
4. update the SSM parameter:
   - `/pixelstreaming/prod/git-target-ref`
5. prod instances in `pinned` mode resolve that parameter at startup

Operational note:
- the actual gold-instance promotion script now writes to `Docs/prod-promotions.local.md`
- that local ledger is intentionally untracked so prod promotions do not block future pulls on the gold instance
- the promotion script now refuses to create a prod tag unless local `HEAD` exactly matches `origin/<current-branch>`
- keep the AMI bake and promotion on the same validated commit so prod startup does not need an expensive first-boot catch-up build

## Naming Convention

- `pixelstreaming-prod-ddmmyyyy<letter>`
- example: `pixelstreaming-prod-20032026a`

The suffix letter allows multiple same-day promotions without reusing a tag name.

## Operator Flow

Run from the repo root on the gold instance:

```bat
BuildScripts\promote-prod-streamer-release.bat
```

Optional notes:

```bat
BuildScripts\promote-prod-streamer-release.bat -Notes "Initial prod dark launch"
```

What the script does:
1. fetch tags from `origin`
2. verify local `HEAD` exactly matches `origin/<current-branch>`
3. determine the next tag for today
4. create an annotated tag on `HEAD`
5. push the tag
6. update `/pixelstreaming/prod/git-target-ref`
7. append a local entry to `Docs/prod-promotions.local.md`

## Prerequisites

The operator context on the gold instance must be able to:
- push tags to the PixelStreaming remote
- `ssm:PutParameter` on `/pixelstreaming/prod/git-target-ref`

If the SSM update fails after tag push:
- the tag may already exist remotely
- do not assume the parameter was updated
- verify the parameter value explicitly before launching new prod instances

If prod startup resolves a newer promoted tag than the AMI was baked with:
- normal boot can still self-heal by resetting the repo to the promoted tag
- that recovery path may then run `BuildScripts/build-all.bat`
- this is expected safety behavior, but it makes prod launch materially slower than the intended fast path

## Launch-Template Contract

Prod launch templates should use:
- `ScaleWorldLane=prod`
- `SCALEWORLD_GIT_SYNC_MODE=pinned`
- `SCALEWORLD_GIT_TARGET_REF_PARAM=/pixelstreaming/prod/git-target-ref`

## Validated Prod Dark-Connect Milestone

Current validated promoted code ref:

- prod tag: `pixelstreaming-prod-21032026c`
- commit: `9dd171f2`
- SSM target ref parameter:
  - `/pixelstreaming/prod/git-target-ref`

Validation achieved on `2026-03-22`:

1. fresh prod-lane instance booted successfully in the `prod` lane
2. startup resolved the pinned prod tag from SSM
3. a manual prod-shaped connect ticket was minted successfully
4. a manual ALB dark-route setup was created for the instance
5. browser connect through the dark URL succeeded

Important:

- this validates the current prod streamer runtime/auth/routing contract
- it does not by itself mean the hosted prod API/control plane is cut over
- AMI id and launch-template version are operator-local rollout details and should be recorded in `Docs/prod-promotions.local.md` for each real prod release tuple

## Recording Real Rollouts

For a real prod rollout, the local ledger should capture the full release tuple, not just the code ref:

1. promoted tag
2. commit
3. AMI id
4. prod launch template version
5. validation timestamp
6. operator notes

Why this matters:

1. the prod tag/commit tell you which code was promoted
2. the AMI id tells you which machine image the instance actually booted from
3. the launch-template version tells you which concrete launch configuration was used

That makes it possible to reconstruct exactly what was rolled out when something later needs rollback or incident review.

## Dark-Connect Validation Without Prod API

You can validate the prod streamer auth/routing contract before prod API cutover by:

1. launching a prod-lane dark-test instance
2. creating temporary ALB route resources for that instance
3. minting a manual prod-shaped connect ticket
4. opening the direct player URL manually

Supported helper:

- `mint-prod-dark-connect-ticket.ps1`

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\mint-prod-dark-connect-ticket.ps1 `
  -InstanceId <instance-id> `
  -UserEmail <your-email> `
  -Region eu-north-1
```

The helper:

1. reads the prod signing key from SSM
2. resolves `RouteKey` from the instance tag when present
3. falls back to instance id when no explicit route key exists
4. prints the full dark-connect URL and raw token

## Reference Ledger Format

Recommended columns for `Docs/prod-promotions.local.md`:

| PromotedAtUtc | Tag | Commit | Region | SSM Parameter | SourceMachine | AmiId | LaunchTemplateVersion | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Example:

| 2026-03-22T18:45:00Z | pixelstreaming-prod-21032026c | 9dd171f2 | eu-north-1 | /pixelstreaming/prod/git-target-ref | GOLD-INSTANCE | ami-0123456789abcdef0 | ScaleWorld_Prod v7 | dark connect succeeded |
