# Prod Streamer Promotions

This document is the current reference for how prod streamer code is promoted.

Stage/candidate promotion now exists as a separate first step:
- Gold validation can promote the tested checkout to `/pixelstreaming/nonprod/git-target-ref`
- prod promotion can then promote that already-tested stage candidate to `/pixelstreaming/prod/git-target-ref`

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
- prod API startup also depends on Azure Key Vault secret `kv-scaleworld-prod/connect-ticket-signing-key`; it must contain the same value as streamer-side SSM `/pixelstreaming/prod/connect-ticket/signing-key`

## Naming Convention

- `pixelstreaming-prod-ddmmyyyy<letter>`
- example: `pixelstreaming-prod-20032026a`

The suffix letter allows multiple same-day promotions without reusing a tag name.
The letter suffix also makes it obvious when more than one promotion candidate was created on the same date.

## Operator Flow

Run from the repo root on an operator workstation or the validated gold instance:

```bat
BuildScripts\promote-prod-streamer-release.bat -Region eu-north-1
```

Optional notes:

```bat
BuildScripts\promote-prod-streamer-release.bat -Region eu-north-1 -Notes "Initial prod dark launch"
```

Optional explicit validated commit/ref:

```bat
BuildScripts\promote-prod-streamer-release.bat -Region eu-north-1 -TargetCommit b7ef17499255bb20d6ae8b3be103b23cb62109b4
```

What the script does:
1. fetch tags from `origin`
2. resolve the promotion commit:
   - default: verify local `HEAD` exactly matches `origin/<current-branch>`
   - optional: resolve `-TargetCommit` and verify fetched `origin/*` contains it
3. determine the next tag for today
4. create an annotated tag on the resolved promotion commit
5. push the tag
6. update `/pixelstreaming/prod/git-target-ref`
7. append a local entry to `Docs/prod-promotions.local.md`

The same script also supports the stage/candidate path when called with:
- `-TargetRefParameterName /pixelstreaming/nonprod/git-target-ref`
- `-TagPrefix pixelstreaming-stage`
- `-LedgerPath Docs/stage-promotions.local.md`

## Prerequisites

The operator context on the workstation or gold instance must be able to:
- push tags to the PixelStreaming remote
- `ssm:PutParameter` on `/pixelstreaming/prod/git-target-ref`

If you run from a workstation instead of EC2:
- pass `-Region eu-north-1` explicitly unless `AWS_REGION` / `AWS_DEFAULT_REGION` is already set
- use `-TargetCommit <validated-sha-or-ref>` when you want promotion to be tied to a previously validated commit instead of the currently checked-out `HEAD`

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

Release reminder:
- verify the launch template AMI id before provisioning
- a wrong AMI can leave fresh prod instances stuck on stale API-owned `booting` tags without ever publishing instance-owned runtime status

## Current Live Prod Release

Current validated live prod tuple:

- prod tag: `pixelstreaming-prod-26032026b`
- commit: `b7ef17499255bb20d6ae8b3be103b23cb62109b4`
- SSM target ref parameter:
  - `/pixelstreaming/prod/git-target-ref`

Validated on `2026-03-26`:

1. prod API/control plane was brought up successfully with the Key Vault-injected connect-ticket signing key
2. prod admin access, release-notes access, and normal server discovery were confirmed
3. prod provisioning succeeded on the promoted streamer code and corrected AMI launch template
4. regular browser connection succeeded end to end for normal prod traffic

Important:

- this is the first validated live prod Session Manager + streamer cutover, not just a dark-connect milestone
- the prod Key Vault secret must stay aligned with streamer-side SSM `/pixelstreaming/prod/connect-ticket/signing-key`
- the launch template AMI is part of the rollout tuple and should be recorded in `Docs/prod-promotions.local.md`

## Historical Dark-Connect Milestone

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

- this validated the prod streamer runtime/auth/routing contract before the later live control-plane cutover
- AMI id and launch-template version are operator-local rollout details and should be recorded in `Docs/prod-promotions.local.md` for each real prod release tuple

## Recording Real Rollouts

For a real prod rollout, the local ledger only needs the minimum operator note that is hard to recover later:

1. prod launch template version used
2. validation timestamp
3. operator notes

Why this is enough in practice:

1. prod tag / commit are already recoverable from the promotion flow and `/pixelstreaming/prod/git-target-ref`
2. the AMI id is recoverable from the launch template version

If you want redundancy, you can still record the full tuple, but it is not required for every rollout.

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

| PromotedAtUtc | LaunchTemplateVersion | Notes |
| --- | --- | --- |

Example:

| 2026-03-22T18:45:00Z | ScaleWorld_Prod v7 | dark connect succeeded |
