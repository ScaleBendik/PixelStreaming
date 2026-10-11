# Task Scheduler delay investigation — 2026-10-12

Follow-up: [guarded 20 → 15-second Dev validation](task-scheduler-delay-results.md)
records the subsequent experiment and its adoption limits. This investigation
retains the original, unchanged 20-second observation below.

## Result and scope

The installed Dev d1 task has a **20-second boot delay**. This makes the user's
recollection a plausible explanation for most of the approximately 25-second
OS-boot-to-launcher interval. It does not establish that the delay can be removed
without replacing the protection it provided.

This was a source review and one ordinary hosted Dev cold-start observation
(sample 16). Runtime `pixelstreaming-runtime-20261011-003`, source
`26ee94ea453d5d6f01f1a5268d9bf08dd3d26046`, remained installed. No task settings,
runtime code, recovery behavior, API/Web version or estimate budget changed.
No disposable instance was provisioned. Dates in this title use Europe/Oslo;
the captured timestamps below are UTC on 2026-10-11.

## Installed task configuration

Read-only SSM inspection after Ready found the following on Dev d1:

| Setting | Observed value |
| --- | --- |
| Task | `\start_streamer_stack` |
| Principal | SYSTEM, ServiceAccount, Highest |
| Boot trigger | Enabled, `PT20S` |
| Logon trigger | Enabled, any user, `PT30S` |
| Multiple instances | IgnoreNew (stored value 2) |
| Start when available | Enabled |
| Run only with network available | Disabled |
| Failure restart | Every 1 minute, up to 15 retries |
| Execution time limit | None (`PT0S`) |
| Action | Canonical `start_streamer_stack.bat` directly, empty arguments |
| Working directory | Unset |
| Task Scheduler operational history | Disabled |

The runbook's [known-good task](watchdog-runbook.md) documents 20 seconds, an
interactive principal, a CMD wrapper/working directory and 30 failure retries.
The actual host differs. [AMI preparation](../BuildScripts/prepare-for-ami-bake.ps1)
rebinds the existing task to SYSTEM but does not enforce trigger/delay settings.
These inherited settings must be captured and preserved in any delay-only test.
The logon trigger and action form are separate concerns; this investigation does
not recommend changing them alongside the boot delay.

`LastRunTime` was `22:08:08`, earlier than this boot's `22:08:30.500` timestamp.
Its origin is unresolved, and it was excluded from initial-action measurements.
Disabled task history supplies no retained trigger/action events. An empty clock
change query does not establish that early boot clocks were stable.

## Current timings

| Measurement | Sample 16 |
| --- | ---: |
| Click → OS boot | 11.172s |
| OS boot → normal full-stack process birth | **25.279647s** |
| OS boot → normal startup journal begin | 25.579177s |
| Process birth → journal begin | 0.299530s |
| Normal startup metadata span | 4.200s |
| Normal CMD configuration span | 1.590s |
| Click → runtime Ready publication | 143.712s |
| Click → canonical API Ready | **146.228416s** |
| Canonical request → canonical API Ready | 144.689032s |

Normal process birth was `22:08:55.7796470`; journal begin was
`22:08:56.0791766`. Previous same-runtime samples 13–15 had boot-to-process gaps
of 24.990635 / 25.149453 / 25.173770 seconds. The installed 20-second delay is
confirmed, but the remaining approximately five seconds cannot be assigned to
scheduler dispatch, a prerequisite or another cause from these captures.

Metadata reported only first attempts. Normal configuration completed
successfully after a 1.025s optional `pointer_fetch` operation with exit code 1.
The journal cannot distinguish a missing optional Dev pointer/defaults from a
storage failure handled with an exact matching cache. Capture allowlisted
snapshot source/reference presence and a sanitized error category in the next
20-second control before enforcing a no-new-fallback candidate gate.

The main page was still preparing at 79.046s and first observed Ready at
159.841s. This is a polling bound, not an exact client detection latency.
"About 2 minutes" at 36.506s and "less than 2 minutes" at 55.939s/79.046s were
consistent with canonical Ready; both strict upper-bound observations held.
The visible ring advanced 30 → 37 → 55 → 100, with Enter observed only at Ready.
Sparse checkpoints do not prove behavior between observations.

Video was observed at 30fps, with zero reported lost packets/dropped frames at
22:11:33.459 and 22:12:44.621 (22.5 and 93.7 seconds of playback). Normal End
was requested, with canonical End at `22:13:58.2469075`. Hosted teardown and
final fleet state are recorded in the [sanitized evidence](evidence/task-delay-baseline-20261012.json).

No delay was shortened, so **this investigation establishes no new startup
saving**. Its timing sample is separate from the completed PowerShell comparison
in [cold-start-recovery.md](cold-start-recovery.md).

## Why an earlier launch might fail

The historic shorter-delay failure has no established diagnosis in the inspected
source history. The 20-second setting was documented as empirically stable in
March. Separate history explicitly mentions unavailable Windows networking on
an early scheduler tick. Current source still contains these relevant boundaries:

| Boundary | Protection and remaining risk |
| --- | --- |
| IMDS and routing/maintenance tags | Bounded retry attempts exist; a slow or failed read can consume a nominal delay saving. |
| Configuration identity and storage | Some IMDS reads are attempted once. Certain storage failures can reuse only an exact matching cached configuration; other failures exit startup. |
| Wilbur secrets | Required TURN credentials and signing key are checked. The launcher-level SSM batch has no retry around a failed required read. |
| Runtime files and VC++ prerequisites | Checked before Unreal launch; missing prerequisites cause immediate failure. |
| GPU/driver readiness | No explicit readiness wait was found. Post-Ready driver health does not establish when the driver became usable during boot. |

These failures can occur before watchdog scheduling. The installed task's
one-minute restart policy can turn a nominal five-second improvement into a
much longer start. Wilbur TCP and Unreal process waits protect later boundaries;
they do not repair earlier configuration/secret failures. A successful boot with
the current delay does not establish the earliest safe launch time.

## Recommended autonomous iteration

1. **Establish reliable task and prerequisite evidence at 20 seconds.** Preserve
   the exact task XML/settings and its hash. Temporarily enable task history on
   the isolated Dev target, record its prior state and restore it afterward.
   Correlate trigger/action events with process births, monotonic launcher spans,
   early clock behavior, dependency outcomes and any task restarts. Avoid printing
   secret values or changing configuration/state to perform the measurement.
2. **Trial only the boot delay at 15 seconds.** Leave the 30-second logon trigger,
   principal, action, conditions, IgnoreNew and failure retries exactly as
   captured. Target an existing stopped Dev instance first; retain an exact
   20-second restoration path. This is a proposed test, not a validated setting.
3. **Repeat paired normal session cycles.** Use current runtime/API/Web/Unreal
   identities and comparable SQL/warm-pool conditions. Require at least three
   successful candidate cold boots, fresh canonical Ready, sustained video,
   normal End, Teardown Completed and provider-stopped confirmation. Compare
   boot-to-action/process time separately from total Ready time and classify
   original/replacement launcher ancestry for every sample.
4. **Restore/reject on evidence of regression.** New or worsened startup errors,
   prerequisite retries/cache fallback, unexpected task actions/restarts, concurrent
   native engines, changed recovery or admission ordering, unhealthy Unreal/video,
   incomplete teardown or missing measurement evidence reject the candidate.
   The expected normal/recovery launches must remain distinguishable. Existing
   optional configuration
   behavior and known launcher overlap must be compared with the control rather
   than silently treated as newly resolved.
5. **Broaden only after the existing-image gate passes.** Fresh/Sysprep boots,
   other GPU classes, required secret/config reads and Stage acceptance remain
   separate gates before an AMI/fleet or Prod change. Do not provision a disposable
   instance until those tests require one. Consider a further small reduction only
   after the 15-second boundary is understood.

The nominal opportunity for a 20 → 15-second change is **five seconds**, contingent
on earlier launch avoiding retries or other waits. Whole-start savings require
measurement. Keep the existing ETA budget during the trial; recalibrate it from
accepted, comparable cold-start cohorts afterward. Launcher-overlap recovery
work remains separate, including its existing safety gates.

AI context already records the legacy runbook/SYSTEM mismatch. No shared AI
context or backlog change was made for this read-only investigation; the
implemented/runtime deployment scope is unchanged.
