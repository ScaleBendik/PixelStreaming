# Runtime Watchdog

Last updated: 2026-03-09

## Purpose

This is the in-house Windows runtime supervisor for ScaleWorld streamer instances.

The intended stack is:

1. `start_streamer_stack.bat` launches the streaming stack
2. `start_dev_turn.bat` starts Wilbur and loads runtime secrets
3. `start_unreal.bat` launches the Unreal application
4. `start_watchdog.bat` runs the watchdog and uses `start_streamer_stack.bat --recovery` for full-stack recovery

`start_dev_turn.bat` is now the Wilbur-specific startup script.
`start_streamer_stack.bat` is the canonical Windows entrypoint for the full streamer stack.

## Current Scope

The watchdog can:

1. monitor Unreal and/or Wilbur processes
2. publish `runtime_fault` when required processes disappear
3. optionally run pre-restart, restart, and post-restart commands
4. optionally terminate matched processes before recovery
5. trigger full-stack recovery through `start_streamer_stack.bat --recovery`
6. publish `booting` with reason `watchdog_restart_pending` before recovery

The watchdog does not yet:

1. run as a Windows service by default
2. detect app-level hung-but-present Unreal states
3. integrate with Session Manager callback APIs
4. fully replace legacy crash tooling in all environments

## Files

- Canonical stack launcher: `SignallingWebServer/platform_scripts/cmd/start_streamer_stack.bat`
- Compatibility wrapper: `SignallingWebServer/platform_scripts/cmd/start_stack.bat`
- Wilbur launcher: `SignallingWebServer/platform_scripts/cmd/start_dev_turn.bat`
- Unreal launcher: `SignallingWebServer/platform_scripts/cmd/start_unreal.bat`
- Watchdog PowerShell script: `SignallingWebServer/platform_scripts/powershell/watchdog.ps1`
- Watchdog batch launcher: `SignallingWebServer/platform_scripts/cmd/start_watchdog.bat`

## Required Inputs

Environment variables or equivalent PowerShell parameters:

- `WATCHDOG_UNREAL_PROCESS_NAME`
- `WATCHDOG_WILBUR_PROCESS_NAME` (default `node.exe`)
- `WATCHDOG_WILBUR_COMMANDLINE_PATTERN` (default `SignallingWebServer`)

Recommended optional inputs:

- `WATCHDOG_RESTART_COMMAND` (defaults to `start_streamer_stack.bat --recovery` in `start_watchdog.bat`)
- `WATCHDOG_POLL_INTERVAL_SECONDS` (default `10`)
- `WATCHDOG_FAILURE_THRESHOLD` (default `3`)
- `WATCHDOG_RESTART_COOLDOWN_SECONDS` (default `10`)
- `WATCHDOG_POST_RESTART_GRACE_SECONDS` (default `15`)
- `WATCHDOG_PRE_RESTART_COMMAND`
- `WATCHDOG_POST_RESTART_COMMAND`
- `WATCHDOG_TERMINATE_MATCHED_PROCESSES` (default `true` in `start_watchdog.bat`)
- `WATCHDOG_DRY_RUN` (default `false`)
- `WATCHDOG_RUN_ONCE` (default `false`)
- `WATCHDOG_LOG_PATH`

Runtime status publishing inputs:

- `WATCHDOG_RUNTIME_STATUS_ENABLED` (defaults to `RUNTIME_STATUS_ENABLED`, otherwise `true`)
- `WATCHDOG_RUNTIME_STATUS_SOURCE` (default `watchdog`)
- `WATCHDOG_RUNTIME_STATUS_VERSION`
- `WATCHDOG_AWS_CLI_PATH` (defaults to `RUNTIME_STATUS_AWS_CLI_PATH`, otherwise `aws`)

## Example

```powershell
$env:WATCHDOG_UNREAL_PROCESS_NAME = 'ScaleWorld'
$env:WATCHDOG_DRY_RUN = 'true'

C:\PixelStreaming\PixelStreaming\SignallingWebServer\platform_scripts\cmd\start_watchdog.bat
```

Default behavior from `start_watchdog.bat`:

- Unreal process: `ScaleWorld`
- terminate matched processes before restart: `true`
- restart command: `start_streamer_stack.bat --recovery`

## Runtime Status Behavior

When enabled, the watchdog writes the shared runtime tag namespace:

- `ScaleWorldRuntimeStatus`
- `ScaleWorldRuntimeStatusAtUtc`
- `ScaleWorldRuntimeStatusSource`
- `ScaleWorldRuntimeStatusReason`
- `ScaleWorldRuntimeStatusVersion`

Current watchdog writes:

1. `runtime_fault`
   - `unreal_process_missing`
   - `wilbur_process_missing`
   - combined fault reasons if multiple required processes are missing
2. `booting`
   - `watchdog_restart_pending`
3. `runtime_fault`
   - `watchdog_restart_failed`

## IAM Requirement

If runtime status publishing is enabled, the instance role must allow `ec2:CreateTags` for the approved `ScaleWorldRuntime*` tag keys on the streamer instance resource.

## Operational Notes

1. Use `start_streamer_stack.bat` as the normal Windows boot/start entrypoint.
2. Use `start_dev_turn.bat` directly only for focused Wilbur troubleshooting.
3. Start with `WATCHDOG_DRY_RUN=true` until fault detection and restart behavior are validated on a dev instance.
4. Keep legacy crash tooling only until watchdog restart flow is verified end-to-end in dev.
5. Recovery should restart the whole stack through `start_streamer_stack.bat --recovery`, not only one process.
6. `start_dev_turn.bat` reloads TURN credentials and the connect-ticket signing key on restart, so recovery should continue to flow through that script.

## Recommended Validation Path

1. Validate process detection for Unreal-only failure.
2. Validate process detection for Wilbur-only failure.
3. Validate full-stack recovery using the default restart command.
4. Confirm runtime status transitions during recovery:
   - `runtime_fault`
   - `booting`
   - `waiting_for_streamer`
   - `ready`
5. After that, decide when to remove the legacy crash monitor from the default AMI startup path.
