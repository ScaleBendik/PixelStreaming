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

### Packaged content root and Development builds

The ZIP may contain a flat package or a wrapping build directory. The installed
content root must contain the bootstrap `ScaleWorld.exe`. Shipping normally has
one executable with that exact name; Development also has
`ScaleWorld/Binaries/Win64/ScaleWorld.exe`. This two-file layout is valid and must
retain both executables, the surrounding `Engine`/`ScaleWorld` content, and PDBs.
The wrapper directory does not have to match the uploaded ZIP's friendly name.

`SWupdate.ps1` resolves one unambiguous bootstrap root and permits only that exact
nested Development executable as an additional same-name candidate. Multiple
release roots, unexpected extra `ScaleWorld.exe` files, and a nested runtime
without its bootstrap are rejected before activation. Do not remove or rename
either executable to work around validation.

Startup, recycle liveness, and watchdog detection recognize Development by its
exact nested executable path under the active install or its junction target.
The root bootstrap alone cannot establish runtime liveness. Shipping matching
and configured watchdog command-line filters remain supported.

Older runtime artifacts reject the Development archive as multiple executable
candidates and can miss its runtime process after startup. Install a corrected
**PixelStreaming runtime-only update first**, then retry the Unreal ZIP through
Fleet. A first combined update still begins under the old updater and cannot be
relied on to fix its own archive validation. No Unreal repackaging is needed for
this compatibility fix. A failed preparation has not activated the new build;
the prior current-build marker is therefore expected to remain.

Focused local checks (no EC2 operations):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_unreal_archive_layout.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File SignallingWebServer/platform_scripts/powershell/test_scaleworld_process_helpers.ps1
```

The archive harness imports only updater function definitions and exercises tiny
ZIPs. Its optional `-PackageRoot <existing-unpacked-build>` checks an actual
package's content-root selection without changing that package.

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

## Session Artifact Boundary

This contract is only for immutable Unreal update ZIPs under `ScaleworldBuilds/`.

Do not store diagnostic bundles or user screenshot bundles under this prefix. Runtime/session evidence uses the agent artifact pipeline and separate prefixes such as `PixelStreamingLogs/` and `PixelStreamingScreenshots/`, with SQL metadata and signed download URLs owned by the Server Manager API.
