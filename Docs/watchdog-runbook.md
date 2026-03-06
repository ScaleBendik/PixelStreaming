# Runtime Watchdog (Standalone Scaffold)

Last updated: 2026-03-06

## Purpose

This is the first in-house watchdog scaffold for Windows streamer instances.

It is intentionally standalone and not wired into default startup yet.
The goal is to validate process supervision and restart behavior without destabilizing the current startup path.

## Current Scope

The watchdog can:

1. monitor Unreal and/or Wilbur processes
2. publish `runtime_fault` when required processes disappear
3. optionally run pre-restart, restart, and post-restart commands
4. optionally terminate matched processes before recovery
5. publish `booting` with reason `watchdog_restart_pending` before restart

The watchdog does not yet:

1. install itself as a Windows service
2. refresh TURN credentials on its own
3. integrate with Session Manager callback APIs
4. replace the current startup script automatically

## Files

- PowerShell watchdog: `SignallingWebServer/platform_scripts/powershell/watchdog.ps1`
- Batch launcher: `SignallingWebServer/platform_scripts/cmd/start_watchdog.bat`

## Required Inputs

Environment variables or equivalent PowerShell parameters:

- `WATCHDOG_UNREAL_PROCESS_NAME`
- `WATCHDOG_WILBUR_PROCESS_NAME` (default `node.exe`)
- `WATCHDOG_WILBUR_COMMANDLINE_PATTERN` (default `SignallingWebServer`)
- `WATCHDOG_RESTART_COMMAND`

Recommended optional inputs:

- `WATCHDOG_POLL_INTERVAL_SECONDS` (default `15`)
- `WATCHDOG_FAILURE_THRESHOLD` (default `3`)
- `WATCHDOG_RESTART_COOLDOWN_SECONDS` (default `120`)
- `WATCHDOG_POST_RESTART_GRACE_SECONDS` (default `30`)
- `WATCHDOG_PRE_RESTART_COMMAND`
- `WATCHDOG_POST_RESTART_COMMAND`
- `WATCHDOG_TERMINATE_MATCHED_PROCESSES` (default `false`)
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
$env:WATCHDOG_UNREAL_PROCESS_NAME = 'MyProject-Win64-Shipping.exe'
$env:WATCHDOG_RESTART_COMMAND = '"C:\PixelStreaming\PixelStreaming\SignallingWebServer\platform_scripts\cmd\start_dev_turn.bat"'
$env:WATCHDOG_RUNTIME_STATUS_ENABLED = 'true'
$env:WATCHDOG_DRY_RUN = 'true'

C:\PixelStreaming\PixelStreaming\SignallingWebServer\platform_scripts\cmd\start_watchdog.bat
```

## Runtime Status Behavior

When enabled, the watchdog writes the same generic runtime tags already used by startup, Wilbur, and idle-stop:

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

1. Start with `WATCHDOG_DRY_RUN=true`.
2. Keep the watchdog out of default startup until restart behavior is validated on a dev instance.
3. If you run Wilbur in an interactive console, continue to account for Windows console and QuickEdit pause behavior during tests.
4. If recovery should stop stale processes before relaunch, enable `WATCHDOG_TERMINATE_MATCHED_PROCESSES=true`.
5. The restart command is launched detached, so point it at a command that is safe to run in a separate `cmd.exe` process.

## Recommended Next Steps

1. Validate process detection on one dev instance.
2. Validate dry-run fault detection for Unreal-only failure.
3. Validate dry-run fault detection for Wilbur-only failure.
4. Validate restart command against the actual AMI launch path.
5. After that, decide whether to wire the watchdog into startup or run it as a service or scheduled task.