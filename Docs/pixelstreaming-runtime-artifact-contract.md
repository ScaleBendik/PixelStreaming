# PixelStreaming Runtime Artifact Contract

Date: 2026-05-21
Last updated: 2026-06-04
Status: active foundation

## Intent

PixelStreaming runtime changes should deploy through immutable runtime artifacts, not by fetching Git and building on ordinary serving instances.

This contract is intentionally separate from Unreal build ZIPs and from AMI/launch-template refreshes:

1. Unreal builds remain under the existing Unreal artifact/update path.
2. PixelStreaming runtime bundles carry Wilbur, frontend assets, runtime scripts, and their own manifest.
3. AMIs remain a base-image and provisioning speed tool, not the normal PixelStreaming release vehicle.

## S3 Layout

Canonical bucket and prefix:

```text
s3://scaleworlddepot/PixelStreamingRuntime/
```

Recommended object layout per immutable bundle:

```text
PixelStreamingRuntime/<bundleId>/manifest.json
PixelStreamingRuntime/<bundleId>/runtime.zip
```

The manifest is the promotion pointer. Runtime update jobs should target the manifest key, then let the manifest identify the exact runtime ZIP and checksum.

## Manifest

Minimum manifest shape:

```json
{
  "schemaVersion": 1,
  "artifactType": "pixelstreaming_runtime",
  "bundleId": "pixelstreaming-runtime-20260521-001",
  "runtimeZipKey": "PixelStreamingRuntime/pixelstreaming-runtime-20260521-001/runtime.zip",
  "runtimeZipSha256": "hex-encoded-sha256",
  "pixelStreamingRepoCommit": "abcdef1234567890abcdef1234567890abcdef12",
  "sourceRef": "work/release-train-revamp",
  "builtAtUtc": "2026-05-21T12:00:00Z",
  "builtBy": "release-runner-or-ci",
  "nodeVersion": "22.x",
  "npmVersion": "10.x",
  "scaleWorldContractVersion": "2026-05-21.1",
  "capabilities": [
    "runtime-status-v1",
    "instance-agent-bootstrap-v1"
  ],
  "compatibility": {
    "api": {
      "advisoryMinContractVersion": "2026-05-21.1"
    },
    "unreal": {
      "advisoryKnownGoodBuildKeys": []
    }
  },
  "promotable": true
}
```

Compatibility fields are advisory at first. The hard requirements are that the manifest exists, the runtime ZIP exists, the checksum matches, and the bundle id is immutable.

## Bundle Contents

The runtime ZIP should contain only what a serving instance needs to start the PixelStreaming stack:

1. built `SignallingWebServer` output
2. built shared workspace packages used at runtime
3. static player/frontend assets
4. production runtime dependencies
5. runtime scripts and config templates
6. embedded `runtime-bundle-metadata.json` with the bundle identity and source metadata

It must not contain secrets, `.git`, developer-only build caches, or machine-specific state.

Ordinary serving startup must not run `git fetch`, `npm install`, or TypeScript builds.

The external `manifest.json` is intentionally not embedded in the ZIP before checksum calculation, because it carries `runtimeZipSha256`. The installer copies the verified external manifest into the installed bundle root after extraction.

## Packaging

Initial local packager:

```text
BuildScripts/package-runtime-artifact.ps1
BuildScripts/package-runtime-artifact.bat
BuildScripts/publish-runtime-artifact.ps1
BuildScripts/publish-runtime-artifact.bat
BuildScripts/publish-runtime-artifact-shortcut.bat
```

Default behavior:

1. fails on a dirty working tree unless `-AllowDirty` is supplied
2. runs `BuildScripts/build-all.ps1` unless `-SkipBuild` is supplied
3. stages only runtime-serving files into a temporary bundle root
4. includes root `node_modules` by default, with workspace package links replaced by built package outputs
5. writes `runtime-bundle-metadata.json` into the ZIP
6. writes canonical `manifest.json` beside the ZIP
7. refuses `-Publish` unless the artifact is promotable

Promotable means the source tree was clean and runtime dependencies were included. Local smoke artifacts can use `-AllowDirty -SkipNodeModules`, but those are not valid release candidates.

Example local smoke package:

```powershell
BuildScripts\package-runtime-artifact.ps1 -BundleId local-smoke-runtime -OutputRoot BuildArtifacts\RuntimeSmoke -SkipBuild -SkipNodeModules -AllowDirty
```

Example publish package:

```powershell
BuildScripts\package-runtime-artifact.ps1 -BundleId pixelstreaming-runtime-20260521-001 -Publish
```

Preferred publish package:

```powershell
BuildScripts\publish-runtime-artifact.ps1
```

The publish wrapper selects the next bundle id for the current date, using the
`pixelstreaming-runtime-YYYYMMDD-NNN` convention. It checks local
`BuildArtifacts\PixelStreamingRuntime` folders and, when allowed by IAM, existing
S3 manifests under `PixelStreamingRuntime/`. If S3 listing is not allowed, it
prints a warning, falls back to local names, and probes the selected manifest key
before publishing.

Shortcut wrapper:

```text
BuildScripts\publish-runtime-artifact-shortcut.bat
```

This wrapper starts PowerShell with `-NoExit`, so it is suitable for a desktop shortcut when an operator wants the publish window to remain open after completion or failure.

`BuildScripts\publish-target-ref.ps1` and `BuildScripts\publish-target-ref-shortcut.bat` remain available for the Dev fast path and one-time bootstrap migration through Git target refs.

Minimum workstation/publisher IAM:

1. `s3:PutObject` and `s3:GetObject` on `arn:aws:s3:::scaleworlddepot/PixelStreamingRuntime/*`
2. optional but recommended `s3:ListBucket` on `arn:aws:s3:::scaleworlddepot` constrained to `PixelStreamingRuntime/*`
3. `ssm:GetParameter` and `ssm:PutParameter` on `/pixelstreaming/*/git-target-ref` while the Git-ref migration path remains in use

## Windows Install Layout

Target stable bootstrap/updater root:

```text
C:\PixelStreaming\bootstrap
```

Current migration bootstrap/updater root:

```text
C:\PixelStreaming\PixelStreaming
```

The current Stage/Prod bridge still uses `C:\PixelStreaming\PixelStreaming` as a Git checkout for bootstrappers, update mode, provisioning mode, and bake-prep tooling. Runtime artifact update/provisioning aligns that checkout to the installed runtime artifact source commit before reporting success. This reduces drift between active runtime and bootstrappers, but it is not the final desired layout.

Versioned runtime installs:

```text
C:\PixelStreaming\runtime-releases\<bundleId>
```

Active runtime pointer:

```text
C:\PixelStreaming\PixelStreamingRuntime
```

Mutable runtime state and logs must stay outside the versioned bundle, preferably under:

```text
C:\PixelStreaming\state
C:\PixelStreaming\logs
```

Existing script/runbook paths that still assume `C:\PixelStreaming\PixelStreaming` need compatibility wrappers or explicit root overrides during migration.

Long-term target: Stage/Prod serving instances should not need Git installed or a mutable repository checkout for ordinary operation. The bootstrap/updater payload should be artifact-owned and versioned with the runtime, with Git target refs retained only for Dev iteration and break-glass recovery.

## Update Flow

Initial standalone installer script:

```text
SignallingWebServer/platform_scripts/powershell/install_pixelstreaming_runtime.ps1
```

Fleet update mode now uses this installer for `pixelstreaming_runtime` targets. Provisioning mode also uses it when the instance is launched with a `ScaleWorldTargetRuntimeManifestKey` tag. Release-candidate orchestration still needs to decide which manifest to stamp for each target.

As of 2026-06-04, runtime artifact install/update behavior also:

1. preserves source commit/ref metadata from the manifest into installed runtime metadata
2. prunes older `runtime-releases` bundles so repeated artifact updates do not exhaust disk space
3. uses `C:\PixelStreaming\state\runtime-updates` as transient scratch/cache state
4. lets update/provisioning mode align the bootstrap checkout to the installed artifact source commit before final success

Fleet update target types:

1. `unreal_zip`
   - requires `ScaleWorldTargetZipKey`
   - updates the Unreal payload only
2. `pixelstreaming_runtime`
   - requires `ScaleWorldTargetRuntimeManifestKey`
   - installs, activates, validates, and tags only the PixelStreaming runtime artifact
3. `combined_runtime_unreal`
   - requires both `ScaleWorldTargetZipKey` and `ScaleWorldTargetRuntimeManifestKey`
   - prepares the runtime artifact and Unreal payload in the same maintenance run
   - activates both payloads and validates once from the active runtime launcher
   - publishes both `ScaleWorldCurrentBuild` and PixelStreaming runtime identity tags

Combined updates are intended for changes where the PixelStreaming runtime and Unreal ZIP should be validated as one serving pair. They are not a replacement for the fast Dev `git_ref` path while iterating on PixelStreaming code.

## Delivery Modes

Startup has an explicit PixelStreaming delivery mode:

```text
SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=git_ref|runtime_artifact|auto
ScaleWorldPixelStreamingDeliveryMode=git_ref|runtime_artifact|auto
```

`ScaleWorldPixelStreamingDeliveryMode` is the EC2 tag override and wins when the env var is not set. Defaults are:

1. `dev` deployment track -> `git_ref`, preserving the fast `/pixelstreaming/dev/git-target-ref` startup sync loop for iteration.
2. `stage` and `prod` deployment tracks -> `auto`, delegating to an installed active runtime artifact when one exists and falling back to pinned git-ref compatibility while migration is in progress.

Explicit `runtime_artifact` fails closed when no active runtime is installed. If the delivery-mode tag is missing but runtime artifact identity tags are present, startup infers `runtime_artifact` instead of falling back to the Dev git-ref default. Git-ref startup publishes `ScaleWorldPixelStreamingDeliveryMode=git_ref` and clears stale runtime artifact identity tags only when git-ref delivery is explicit. Runtime artifact update/provisioning success publishes `ScaleWorldPixelStreamingDeliveryMode=runtime_artifact`.

Runtime-artifact identity is sticky across normal startup. The repo-head publisher may still record repository diagnostics after startup, but when the current instance tag says `ScaleWorldPixelStreamingDeliveryMode=runtime_artifact` or runtime identity is present without an explicit `git_ref`, it must not clear runtime identity tags and must not rewrite `ScaleWorldPixelStreamingVersion` to the Git target ref. The displayed version should continue to be the runtime bundle id until an explicit Git-ref delivery update changes the delivery mode.

Per instance:

1. enter update maintenance mode
2. download `manifest.json`
3. verify `artifactType`, `bundleId`, runtime ZIP key, and checksum fields
4. download `runtime.zip`
5. verify SHA256
6. extract to `runtime-releases\<bundleId>`
7. switch `PixelStreamingRuntime` active pointer
8. start stack from the active runtime root in validation mode
9. validate streamer health and EC2 runtime readiness
10. publish runtime identity tags

For combined updates, the runtime prepare step runs before activation and in parallel with the Unreal prepare work where possible. If either prepare step fails, activation is not attempted. If activation or validation fails after one payload has already been activated, the instance stays in failed update maintenance state for manual inspection. Runtime rollback to a previous installed bundle is still a planned follow-up.

Rollback should switch the active pointer back to the previous installed bundle and restart, not reset a Git checkout.

Migration note: existing instances only gain this path after their bootstrap checkout or base AMI contains the updated updater/provisioning scripts. Use the legacy repo-sweep/git-ref path once to deploy the bootstrap, then use runtime artifacts for subsequent PixelStreaming changes. For Stage/Prod, prefer a Stage-validated source-instance AMI after bake prep over routine Git target-ref updates.

Bootstrap readiness tag:

```text
ScaleWorldPixelStreamingUpdateCapabilities=pixelstreaming_runtime,combined_runtime_unreal
```

The updater publishes this capability tag after the stable bootstrap/updater path is present. Server Manager API and web use it as the coarse compatibility gate for runtime-artifact and combined update jobs. A versioned updater contract is still a planned follow-up.

Source alignment check after updates:

```text
ScaleWorldPixelStreamingRuntimeSourceCommit == installed artifact manifest commit
ScaleWorldRuntimeRepoHead == same commit, or diagnostic-only when running from a non-git runtime root
```

If these disagree on a Stage/Prod source instance intended for AMI bake, run bake prep or inspect update/provisioning logs before baking.

## Runtime Identity Tags

Planned EC2 tags:

```text
ScaleWorldPixelStreamingDeliveryMode
ScaleWorldPixelStreamingRuntimeBundleId
ScaleWorldPixelStreamingRuntimeManifestKey
ScaleWorldPixelStreamingRuntimeArtifactKey
ScaleWorldPixelStreamingRuntimeSourceCommit
ScaleWorldPixelStreamingRuntimeContractVersion
```

These are separate from the existing Unreal build tag `ScaleWorldCurrentBuild` and from legacy Git identity tags.

For runtime artifacts, `ScaleWorldPixelStreamingVersion` is a display compatibility tag and should match the active runtime bundle id. Git-ref startup may use the resolved Git target ref for that tag only when the effective delivery mode is `git_ref`.

## Release Candidate Role

Release candidates should reference the PixelStreaming runtime manifest key, not a promoted Git ref, as the deployable runtime object.

Gold or a dev streamer may build and validate a runtime artifact, but the source of truth after publish is the immutable manifest plus its release-candidate record.

Current branch state:

1. Server Manager API exposes `GET /admin/fleet/release-candidates`, `POST /admin/fleet/release-candidates/capture`, and `PUT /admin/fleet/release-candidates/current/{target}`.
2. The candidate store has independent Dev, Stage, and Prod current pointers under the `release-candidates/` Blob prefix.
3. Candidates are captured from a source target. Current pinning is conservative: Dev pins Dev-sourced candidates, Stage pins Stage-sourced candidates, and Prod pins only the Stage live pointer with passed validation evidence.
4. Candidate capture resolves the runtime manifest through the API-owned runtime artifact catalog and rejects missing manifests or mismatched requested artifact key, bundle id, source commit, contract version, or runtime ZIP SHA256.
5. The Release page reads candidate state in the Dev/Stage/Prod Release Train cards, can capture/pin Dev or Stage candidates from the latest listed runtime artifact, records Stage validation evidence, and can promote the validated Stage live pointer to Prod.
6. Idempotent capacity convergence, rollback controls, shared/SQL candidate storage, and full runtime ZIP re-hashing are still follow-up work.

Current storage caveat: the Blob release-candidate store uses the environment runtime Blob container. Stage and Prod therefore use separate candidate stores in committed config, even though the blob names are the same. Cross-environment promotion currently bridges through SSM live pointers at `/scaleworld/release/stage/current-candidate` and `/scaleworld/release/prod/current-candidate`; SQL/shared candidate storage remains the long-term target.
