# PixelStreaming Runtime Artifact Contract

Date: 2026-05-21
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

## Windows Install Layout

Stable bootstrap/updater root:

```text
C:\PixelStreaming\bootstrap
```

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

## Update Flow

Initial standalone installer script:

```text
SignallingWebServer/platform_scripts/powershell/install_pixelstreaming_runtime.ps1
```

Fleet update mode now uses this installer for `pixelstreaming_runtime` targets. Provisioning mode also uses it when the instance is launched with a `ScaleWorldTargetRuntimeManifestKey` tag. Release-candidate orchestration still needs to decide which manifest to stamp for each target.

## Delivery Modes

Startup has an explicit PixelStreaming delivery mode:

```text
SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE=git_ref|runtime_artifact|auto
ScaleWorldPixelStreamingDeliveryMode=git_ref|runtime_artifact|auto
```

`ScaleWorldPixelStreamingDeliveryMode` is the EC2 tag override and wins when the env var is not set. Defaults are:

1. `dev` deployment track -> `git_ref`, preserving the fast `/pixelstreaming/dev/git-target-ref` startup sync loop for iteration.
2. `stage` and `prod` deployment tracks -> `auto`, delegating to an installed active runtime artifact when one exists and falling back to pinned git-ref compatibility while migration is in progress.

Explicit `runtime_artifact` fails closed when no active runtime is installed. Git-ref startup publishes `ScaleWorldPixelStreamingDeliveryMode=git_ref` and clears stale runtime artifact identity tags. Runtime artifact update/provisioning success publishes `ScaleWorldPixelStreamingDeliveryMode=runtime_artifact`.

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

Rollback should switch the active pointer back to the previous installed bundle and restart, not reset a Git checkout.

Migration note: existing instances only gain this path after their bootstrap checkout or base AMI contains the updated updater/provisioning scripts. Use the legacy repo-sweep/git-ref path once to deploy the bootstrap, then use runtime artifacts for subsequent PixelStreaming changes.

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

## Release Candidate Role

Release candidates should reference the PixelStreaming runtime manifest key, not a promoted Git ref, as the deployable runtime object.

Gold or a dev streamer may build and validate a runtime artifact, but the source of truth after publish is the immutable manifest plus its release-candidate record.
