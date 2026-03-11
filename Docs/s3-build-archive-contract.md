# S3 Build Archive Contract

This document defines the ZIP-only archive contract for Unreal update artifacts used by streamer instances and Fleet updates.

## Bucket

- S3 bucket: `scaleworlddepot`
- Region: `eu-north-1`

## Supported Layout

All update ZIPs should be uploaded as immutable objects under:

- `ScaleworldBuilds/<artifact-name>.zip`

Examples:

- `ScaleworldBuilds/ScaleWorld_2026-03-10-01.zip`
- `ScaleworldBuilds/ScaleWorld_v030326.zip`

Fleet artifact discovery lists `.zip` objects from `s3://scaleworlddepot/ScaleworldBuilds/`.

## Fleet / Instance Tag Contract

Update mode on the instance uses:

- `ScaleWorldMaintenanceMode=update`
- `ScaleWorldUpdateJobId=<guid>`
- `ScaleWorldUpdateTarget=<exact s3 object key>`
- `ScaleWorldTargetZipKey=<exact s3 object key>`
- `ScaleWorldCurrentBuild=<last successful zip filename>`
- `ScaleWorldUpdateState=requested|running|validating|succeeded|failed|stopping`
- `ScaleWorldLastUpdatedAtUtc=<utc timestamp>`
- `ScaleWorldUpdateResultReason=<short failure reason>`
- `ScaleWorldUpdateCompletedAtUtc=<utc timestamp>`

Fleet command tags stay on the instance until the API later observes the matching job instance in a stopped terminal state and clears:

- `ScaleWorldMaintenanceMode`
- `ScaleWorldUpdateJobId`
- `ScaleWorldUpdateTarget`
- `ScaleWorldTargetZipKey`

## Operator Rules

1. Upload immutable release ZIPs only. Do not overwrite an existing ZIP in `ScaleworldBuilds/`.
2. Fleet updates should always target an exact ZIP key selected from the Fleet Manager dropdown.
3. `Scaleworld_001/latest.json` and `Scaleworld_001/ScaleWorld_Latest.zip` are deprecated and should not be used for Fleet or normal instance update flow.
4. Treat Fleet command tags as API-owned control state. Do not manually clear or rewrite `ScaleWorldMaintenanceMode`, `ScaleWorldUpdateJobId`, `ScaleWorldUpdateTarget`, or `ScaleWorldTargetZipKey` during normal operations.
5. Keep `ScaleWorldTargetZipKey` as the exact S3 object key, not a friendly label.
6. Treat `ScaleWorldCurrentBuild` as an outcome marker written by update mode. It is not an operator input.
7. Retry or advance Fleet updates through the Fleet API/admin surface, not by rebooting the instance to rerun terminal maintenance state.

## Manual Development Testing

On the instance:

1. Prepare the ephemeral data drive:
   - `platform_scripts/cmd/prepare_data_drive.bat`
2. Run the updater directly with an exact ZIP key:
   - `platform_scripts/cmd/run_unreal_update.bat -ZipKey "ScaleworldBuilds/<artifact>.zip"`

The updater will:

- download to `D:\ScaleWorldBuilds` when the data drive exists
- use `D:\ScaleWorldBuilds\staging` for extraction scratch space
- keep final installed releases on `C:\PixelStreaming\releases`
