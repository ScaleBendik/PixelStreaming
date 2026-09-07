# ServerManager PixelStreaming

Owns Wilbur, embedded agent, viewer admission, and runtime startup/update/recycle.

Paths are repo-relative. When present, follow `../AGENTS.md` for shared workflow,
verification, authorization, and maintenance; read the workspace context index once.
Context names below are under `../docs/ai-context/`; load only relevant sections.
Standalone: start with `Docs/README.md` and `SignallingWebServer/README.md`. Inspect Git status/diffs,
preserve unrelated edits, verify against source, and report actual checks/gaps.
If Git is unavailable, preserve originals and check for concurrent edits.
Continue authorized local work; report missing shared context and update local docs.

## Reading routes

- Runtime: `pixelstreaming.md`; toolchain/commands: PixelStreaming in `local-dev.md`.
- Admission/agent/startup/idle/recycle: relevant traps and `cross-system-flows.md`.
- Artifacts/install/release: `release-update-flow.md` and local
  `Docs/pixelstreaming-runtime-artifact-contract.md`. Prefer ScaleWorld Docs over upstream README.

## Constraints

- Wilbur startup affects agent heartbeats/commands. Preserve exact session/generation
  correlation, fail-closed tickets, and immutable artifact identity.
- Signalling readiness alone does not prove usable media.
- Stop/recycle, tag writes, activation, and upload scripts are operational;
  inspect targets and run only within the authorized task.
- Check `NODE_VERSION` and actual executable version for build/release provenance.

## Verification

Use affected workspace `package.json`; shared dependencies may need building first.

- In `SignallingWebServer/`: `npm exec tsc -- --noEmit`, `npm run lint`, and
  `npm test` for runtime behavior (the test script also builds Wilbur).
- For startup/prerequisite changes, from repo root run PowerShell with
  `-ExecutionPolicy Bypass -File` and the relevant harness under
  `SignallingWebServer/platform_scripts/powershell/`:
  `test_stack_launcher_policy.ps1` or `test_unreal_prerequisite.ps1`.
- Run affected library/frontend tests/builds; broaden to root `npm run lint` and
  `npm run build` for shared dependency changes. Report hosted acceptance separately;
  compilation or placeholder test scripts do not establish lifecycle/media behavior.
