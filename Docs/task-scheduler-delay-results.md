# Boot-delay optimization: hosted Dev results

Client date: 2026-10-12 (Europe/Oslo). Captured timestamps use UTC.

Status: accepted for the existing isolated Dev d1 and current image only. One
instrumented 20-second control and three 15-second candidates passed startup,
sustained-video and normal session teardown checks. All three Dev instances were
confirmed stopped at `2026-10-11T23:29:48.5501784Z`. The request-page refresh
anomaly in 21 remains a separate unresolved issue.

## Change and isolation

Only Dev `ScaleWorld_d1` (`i-0ce5ffd16bd50eb24`, g5.2xlarge, eu-north-1) was
changed: `\start_streamer_stack` BootTrigger delay **20 → 15 seconds**.
The exact captured task definition was verified before and after the change.
LogonTrigger remains 30 seconds / any user; SYSTEM, highest privilege, direct
canonical BAT action, unset working directory, IgnoreNew, all conditions,
one-minute restart interval and 15 retries remain unchanged.

Runtime/API/Web/Unreal identities stayed fixed:

- Runtime `pixelstreaming-runtime-20261011-003`, source
  `26ee94ea453d5d6f01f1a5268d9bf08dd3d26046`.
- Web `5bc95c6c06cb2bb7e635b505a0598b22cd8a56a8`.
- API `e9756bf7838e9bbd899aaa35118fbbb81ef48d33` (build 1379).
- Unreal `ScaleWorld_20261008b.zip`.

No runtime upload or API/Web deployment was necessary. The recovery fix from
`d17821a` remains an ancestor of the runtime source. Launcher-overlap recovery
work and its safety margins remain separate.

Retain `PT15S` on d1 with the original history setting restored. This pass changes
no AMI, Stage, Prod or fleet default. Fresh-image and Stage acceptance remain open;
retain the pinned `PT20S` rollback and restore it before an ordinary reusable bake.

## Measurements

Session 18 is the instrumented 20-second control. Preparation 17 is excluded:
history was disabled during its boot, an early clock correction occurred, and
its unchanged-runtime reconnect required a retry after initial healthy playback.
Each trial uses Request ScaleWorld after normal End, canonical Teardown Completed
and EC2-stopped confirmation. There is no available warm pool in these samples.

Retained, sanitized evidence:
[boot-delay validation](evidence/task-delay-validation-20261012.json) and
[local native-command profile](evidence/native-aws-capture-local-profile-20261012.json).
The validation retains original timestamp strings, input hashes, exact-definition
receipts, bounded task/process/config/media observations and their limitations.

| Sample | Boot delay | Boot → scheduler process event | Click → API Ready | Saving versus 18 |
| --- | --- | --- | --- | --- |
| 18 control | 20s | 24.976868s | 129.586357s | — |
| 19 candidate | 15s | 19.965114s | 124.653018s | 4.933339s |
| 20 candidate | 15s | 20.125001s | 123.266586s | 6.319771s |
| 21 candidate | 15s | 20.190866s | 123.933339s | 5.653018s |
| Candidate mean | 15s | 20.093660s | 123.950981s | 5.635376s |

Scheduler event 129 is matched to the normal launcher PID; event 200/201 and
100/102 share one task instance. LastRunTime is excluded: it differs from first
action evidence. No clock changes were captured for 18–21. Task scans are scoped
before their cap. ISO timestamps retain their original precision.

The three task-start gains are **5.012, 4.852 and 4.786 seconds**: mean **4.883s**.
Shipping Unreal → runtime Ready was 56.520 / 54.535 / 54.497s, compared with
56.591s in 18. The control's 129.586s click → API Ready became 123.951s on average,
an observed **5.635s improvement**. The roughly five-second task shift is the
directly targeted component. Whole-start results also include API polling,
provider and initialization variation; the extra whole-start difference is not
attributed entirely to the task change. One control and three same-host candidates
do not establish fleet percentiles or a guaranteed per-request saving.

## Acceptance evidence and limits

Each candidate has one successful scheduled action, complete normal and recovery
journals, first-attempt metadata reads, and freshly published Dev defaults after
the optional missing configuration pointer. No cached-storage fallback was used.
Required measured phases succeeded. Playback at 103 / 135 / 129 seconds was 30fps,
with zero lost packets and dropped frames. Ready respected the recovery not-before
hold; the local admission identity matched each current request. Candidate 21's
admission was captured in a separate read-only post-connect snapshot because
its original observer finished before the delayed entry.

All 18–21 retain the known original-launcher Unreal overlap. The normal-parent
engine launched after the replacement marker and remained alongside replacement
Node. No persistent second native engine was observed through the observer,
which polls native process identities about every 3 seconds and emits trees on
changes. Transient duplicates and exclusive generation ownership are not proved.
This pass does not repair or exonerate that recovery issue.

This is an existing-image Dev boot trial. Fresh/Sysprep boots, other GPU classes,
required-pointer configurations, failure injection and Stage acceptance remain
gates before a reusable image/fleet or Prod rollout. The historical shorter-delay
failure still has no established diagnosis. No disposable instance was needed for
this bounded existing-image test.

## User-facing estimates

The ETA budget remains 150 seconds plus its existing initial buffer. Trial 19's
sampled numeric progress 35 → 57 → 100 did not regress; its “less than 2 minutes”
messages were true against actual API Ready. In control 18 and candidate 20,
numeric progress briefly became indeterminate with a generic warm-up message
before UI Ready. These fallback transitions are not a perfectly continuous bar.

In 21, runtime Ready was 118.818s and API Ready 123.933s, yet the page remained at
68% / “Starting ScaleWorld” through **196.797s**. Its local estimate clock
continued and eventually claimed startup was taking longer than usual. Returning
from Analytics did not refresh it. One explicit reload exposed Ready, first
observed at 217.631s; actual streaming then passed. This is at least **72.864s of
stale waiting after API Ready**. The browser
extension reconnected during this cycle; that correlation does not establish a
cause. The successful runtime result does not count as a successful uninterrupted
request-page refresh test.

Source review found a credible separate candidate: the request query does not
consume TanStack's AbortSignal, and token/header acquisition, GET and response
body consumption have no overall deadline. An unresolved fetch can be reused by
interval polling and survive an Analytics unmount/remount. This matches the
observed recovery pattern but is **not a reproduced diagnosis**. A next pass
should first reproduce a held request in an isolated test, then validate bounded
cancellation/retry, request identity, transient-error messaging and disposal on
navigation. Do not retry the session-creation POST or change admission semantics.

Source basis in the Web repository (no `src` differences between deployed
`5bc95c6` and reviewed `d5e54d9`):
`src/features/sessionAccess/queryOptions.ts:30–52`,
`src/features/sessionAccess/api.ts:19–24`,
`src/utils/endpointService.ts:78–103,147–150` and
`src/routes/_authenticated/admin/index.tsx:223–225`.
The installed, lockfile-pinned TanStack Query Core 5.90.12 implementation was
checked for pending-promise reuse and unused-signal unmount behavior.

This same-host cohort does not justify fleet ETA recalibration. Keep cold-only,
version/GPU/ownership-aware cohorts and distinguish API readiness from displayed
readiness. Address stalled refresh before tuning the estimate budget.

## Operator procedure and rollback

The reviewed helper is
[invoke-dev-startup-delay-experiment.ps1](../BuildScripts/invoke-dev-startup-delay-experiment.ps1).
It is an operator tool, not normal startup. It is outside the explicit runtime
BuildScripts package allowlist;
execute the reviewed source through the explicitly targeted AWS PowerShell SSM
document. Do not assume it is installed on the host.

Capture verified IMDS identity and exact Dev d1 tags, exported the complete XML,
retained a receipt, then enabled temporary task history. Apply required the
independently retained receipt SHA256, rejected task drift, changed only the Boot
trigger, and verified the complete resulting definition. Unexpected post-change
differences restore baseline XML and prior history. Neither operation starts the
task. The first Capture attempt safely rejected a PS5.1 JSON-array parsing issue
before mutation; the parser was fixed and its native multiline JSON fixture added.
The PS5.1 harness passes 53 assertions/scenarios with mocked host, task and
history adapters and real XML/backup I/O. It covers failure rollback, tampering,
non-Dev targets and preservation of an initially enabled history log. The live
Capture and Apply calls additionally verified the real ScheduledTasks API.
The existing stack-launcher policy and Unreal service-class argument-execution
tests also passed under PowerShell 5.1. Runtime application source did not change,
so no new application build or artifact deployment was required.

Dev backup directory:
`C:\PixelStreaming\diagnostics\startup-delay-experiment\bootdelay-20261012`.
Pinned receipt SHA256:
`613dd3208b9625b121eb73472985f443dcb76e400c5ab5f7183808a5c8461ddb`.
XML SHA256:
`560190b2e5a031752112e8f18312f190b4c6a0022a1b9d9cc9a4d20ac6904344`.
Raw task XML is retained only on the host; it is not committed to this report.

`Restore` with that target, directory and receipt hash restores the exact 20-second
task and the original history-enabled state. `RestoreHistory` retains an accepted
15-second task while restoring history-enabled=false, without clearing events.
The latter completed and verified `PT15S`, unchanged non-delay definition and
history=false, with 259 retained history records (SSM
`bf6e4c83-2311-4399-94da-a61cff290181`).
Ordinary runtime updates do not modify this task in source; persistence across
an update was not separately tested. AMI preparation rebinds SYSTEM while
preserving the inherited delay. **Restore and export-verify 20 seconds before an
ordinary reusable bake** until an isolated 15-second image cohort is accepted.

## Next meaningful candidate

A bounded three-round local PowerShell 5.1 profile found the current native
`Start-Process -Wait` capture returning 967–974ms after process exit. Concurrent
.NET stream capture was 65–85ms versus 1031–1098ms for the current path, a mean
985ms difference per call. Doubling local per-call differences gives a
**1.93–2.03s two-call projection**. This is a local component opportunity.
There is no measured AWS/network or cold-start saving yet. Removing `-Wait`
alone failed exit-code
capture and is rejected. A later replacement must prove descendant waiting,
stream draining, argument quoting, Unicode, exit codes and failure cleanup before
Dev validation. `Start-Process -Wait` includes process-tree/job completion; root
process exit plus stream EOF does not prove every descendant completed. The
fixture had no descendants. Preserve or explicitly justify that contract, along
with payload lifetime and cleanup, before replacing capture. This was profiling
only; no capture implementation changed. The request-page stall has larger
potential user-visible impact and should receive the next bounded investigation.

## Documentation coordination

Shared AI context and the current canonical backlog were checked. Findings,
operator instructions and remaining acceptance gates are recorded in this
branch-owned runtime documentation. Shared files were left unchanged to honor
the new-branch requirement and avoid overwriting the newer canonical backlog
with the older isolated Web checkout. Fresh-image, GPU-class, Stage and fleet
acceptance gates remain open.
