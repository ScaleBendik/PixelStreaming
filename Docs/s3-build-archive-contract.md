# S3 Build Archive Contract

This document defines the current archive contract for Unreal update artifacts used by streamer instances.

## Scope

Current implementation supports a single application line:

- `Scaleworld_001`

Additional app lines can be added later, but this contract intentionally stays single-line for now.

## Bucket

- S3 bucket: `scaleworlddepot`
- Region: `eu-north-1`

## Current Pointer Files

Preferred mutable pointer:

- `Scaleworld_001/latest.json`

Legacy direct ZIP fallback:

- `Scaleworld_001/ScaleWorld_Latest.zip`

## Recommended Release Layout

Immutable release ZIPs should live under:

- `Scaleworld_001/releases/<build-id>/<artifact-name>.zip`

Examples:

- `Scaleworld_001/releases/2026-03-10-01/ScaleWorld_2026-03-10-01.zip`
- `Scaleworld_001/releases/v030326/ScaleWorld_v030326.zip`

## Manifest Contract

`Scaleworld_001/latest.json` should point to the current recommended build and may contain:

```json
{
  "buildId": "2026-03-10-01",
  "zipKey": "Scaleworld_001/releases/2026-03-10-01/ScaleWorld_2026-03-10-01.zip",
  "sha256": "optional sha256 hex"
}
```

Recommended fields:

- `buildId`
- `zipKey`
- `sha256`

## Instance Tag Contract

Update mode on the instance currently uses:

- `ScaleWorldMaintenanceMode=update`
- `ScaleWorldTargetZipKey=<exact s3 object key>`
- `ScaleWorldCurrentBuild=<last successful zip filename>`
- `ScaleWorldUpdateState=requested|running|succeeded|failed`
- `ScaleWorldLastUpdatedAtUtc=<utc timestamp>`
- `ScaleWorldUpdateResultReason=<short failure reason>`

## Operator Rules

1. Do not overwrite immutable release ZIPs under `releases/`.
2. Move the active build by updating `Scaleworld_001/latest.json`.
3. Prefer manifest-driven updates over direct `ScaleWorld_Latest.zip`.
4. Keep `ScaleWorldTargetZipKey` as the exact S3 object key, not a friendly label.
5. Keep `ScaleWorldCurrentBuild` as the last successfully installed ZIP filename.

## Manual Development Testing

On the instance:

1. Prepare the ephemeral data drive:
   - `platform_scripts/cmd/prepare_data_drive.bat`
2. Run the updater directly:
   - `platform_scripts/cmd/run_unreal_update.bat -BuildKey "Scaleworld_001/releases/<build-id>/<artifact>.zip"`

The updater will:

- download to `D:\ScaleWorldBuilds` when the data drive exists
- use `D:\ScaleWorldBuilds\staging` for extraction scratch space
- keep final installed releases on `C:\PixelStreaming\releases`
