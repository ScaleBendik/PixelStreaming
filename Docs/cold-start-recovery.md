# Cold startup measurement and recovery investigation

This document owns the measurement method, results and next investigation steps
for stopped-instance startup without warm capacity. It does not authorize a
change to admission, recovery or commercial lifecycle rules. Measurements are
from Dev on 2026-10-11. The initial observation pass changed documentation only;
the subsequent authorized metadata, telemetry and Web implementation is described
below. Historical observation sections retain their original runtime identities.

## What recovery currently protects

Destructive teardown durably advances the ticket issuance cutoff and sets
`commercialRecoveryRequired`. A normal Shutdown leaves this flag across EC2
stop/start. The desired-state, command, auth and recycle journals live outside
the versioned runtime bundle, normally under `C:\PixelStreaming\state`.

On the next boot, recovered commands are quarantined until authenticated API
control state confirms the exact current operation. If the API clears old
teardown, but the auth flag remains without a marker or elapsed evidence, the
agent requires one safe local full-stack recycle. A new OS boot alone does not
discharge that flag. The existing prior-boot viewer reconciliation explicitly
refuses commercial recovery and pending evidence.

Local recovery completion requires durable replacement proof, replacement runtime
Ready, the two-sided ticket clock-skew margin and atomic auth-state completion.
The marker remains until exact control-plane acknowledgement. In the observed
cycle, local auth completion and runtime Ready preceded marker acknowledgement;
do not describe acknowledgement as a prerequisite for local admission reopening.
With the default five-second skew, the admission
hold is approximately ten to eleven seconds. This is a safety boundary rather
than a delay to remove. Missing, corrupt or unwritable expected state must fail
closed. A 204 entitlement response does not prove previous teardown completed.

Source entry points:

- `SignallingWebServer/src/connect-ticket-runtime-state.ts`: teardown latch,
  prior-boot viewer reconciliation, cutoff/Ready margin and atomic completion.
- `SignallingWebServer/src/instance-agent.ts`: recovered-command quarantine,
  authoritative control ordering, deferred latch-only recovery and completion.
- `SignallingWebServer/src/viewer-idle-stop.ts`: committed teardown and recycle.
- `SignallingWebServer/platform_scripts/powershell/invoke_stack_recycle.ps1`:
  intent, old-process absence, replacement marker and recovery launcher.
- `SignallingWebServer/platform_scripts/cmd/start_streamer_stack.bat`: serial
  bootstrap, Wilbur TCP wait and independent Unreal launch.

## Measurement rules

Use the actual Request ScaleWorld button. Record click beginning/end, API request,
provider start, OS boot, task action start if available, config write, each
Wilbur/Unreal process generation, recovery decision, replacement marker,
entitlement projection, runtime Ready and canonical API Ready. First observed
Enter and decoded video are observation bounds, not exact startup transitions.
Exclude human delay after Ready from startup duration.

Record exact API/Web/client asset/runtime/Unreal/config identities and preceding
lifecycle. Separate first boot after update validation, post-normal-End,
never-connected cancellation, same-boot recycle and SQL-wake cohorts. Updating
a runtime can complete recovery during validation and then provider-stop it;
that first boot is not equivalent to the boot after normal managed End.

Diagnostics Web build info describes the deployment, not necessarily JavaScript
already loaded in an open SPA tab. Reload before acceptance and record the
document script asset. On this date build 1358 / `d5a016bc` produced
`index-D-lKoBCy.js`; build 1360 / `4330a799` produced `index-Bz6M9YUA.js`.

State observations allowlist booleans, timestamps and operation/request IDs;
exclude credentials, actor emails, ticket contents, raw command lines and
entitlement contents. Collect process PID, parent, creation UTC and a static
launcher-role classification. Label instrumented timing samples: observer work
can affect performance. Use a narrow read-only observer and emit changes only.

Read all relevant log files for the measured time window, record their physical
bundle roots, timestamp coverage and any truncation. Daily logs mix generations;
newest-file/tail/phrase filtering cannot prove that a recovery did not happen.
An append-only external generation/phase journal would make later measurements
more reliable. Task LastRun can be overwritten by Boot/Logon triggers and is not
an initial-action timestamp. Task Scheduler history was unavailable in this
sample; do not infer a removable delay from LastRun alone.

## Observed ordinary post-End candidate boot

Instance `i-0ce5ffd16bd50eb24`, g5.2xlarge, Stockholm; all Dev streamers stopped
before the request, no warm capacity. Runtime `pixelstreaming-runtime-20261011-005`
/ `dc9dda0d`, API `e9756bf7`, Unreal `ScaleWorld_20261008b.zip`. SQL was awake.
Request `ad4813622cdf462abb7bd4ab302c306b` followed the normal End of the prior
candidate session.

| Event | UTC | Seconds from click beginning |
| --- | --- | ---: |
| Request click beginning | 17:42:42.418 | 0.000 |
| API request | 17:42:43.8578192 | 1.440 |
| EC2 start | 17:42:46 | 3.582 |
| OS boot | 17:42:55.500 | 13.082 |
| Config snapshot write | 17:43:38.8680393 | 56.450 |
| Initial Wilbur PID 6060 | 17:43:49.5491789 | 67.131 |
| Recovery requested | 17:43:52.794 | 70.376 |
| Replacement-started marker | 17:43:53.9668561 | 71.549 |
| First captured shipping Unreal PID 1152 | 17:43:55.4738070 | 73.056 |
| Replacement Wilbur PID 4352 | 17:44:18.7990570 | 96.381 |
| Durable recovery completion | 17:44:50.011 | 127.593 |
| Runtime Ready | 17:44:50.039 | 127.621 |
| Canonical API Ready | 17:44:52.5644988 | 130.146 |

Before the first Wilbur, persisted desired state still requested Shutdown and
auth state retained the previous request's Shutdown flag/cutoff from 17:04:29.
There was no active command, recycle marker or elapsed-evidence record.
Authenticated control reconciliation cleared desired Shutdown, then created a
tokenless passive recovery marker. The old owner and recovery flag were removed
only after cutoff 17:44:44, Ready-not-before 17:44:49 and completion at 17:44:50.
The marker was cleared after API acknowledgement at 17:44:51.136. Cutoff and
completed-token history remained. This confirms the recovery path described
above; it does not prove acceptance/rejection under injected skew or stale tokens.

The player presented H264 at 30 FPS with decoded frames and zero reported packet
loss/drops. The session ended normally. An attempted post-End snapshot command
returned Cancelled with no state evidence.

Two Wilbur generations are proved. Three-second sampling captured only one
Unreal generation; an earlier brief process cannot be excluded. The original
stack parent is not included in the recycle helper's stop matchers. Its TCP wait
can complete before asynchronous agent reconciliation, allowing it to launch
Unreal after the helper's old-process absence witness. Parent/launcher provenance
must distinguish this overlap before changing startup order.

The 57.245 seconds from recycle request to runtime Ready contains normal startup,
stabilization and the admission margin. It is not a measured removable saving.
Likewise, the 29.250-second separation between Wilbur generations is not a safe
counterfactual saving. The earlier candidate's 28.141-second advantage over the
baseline mean remains confounded by update-validation history and baseline
variance. The metadata handoff removed duplicate successful resolver calls.
Two trials of each standalone resolver on the already running host had a mean
combined duration of about 3.835 seconds. That is not a measured per-cold-launch
saving; launch/cache/network conditions may differ. End-to-end benefit remains
unestablished.

## Repeat after normal End with the refreshed client

Request `b3b3e822d14644fe929e05fe5ed40b80`, same deployed runtime/API/Unreal,
click 17:53:55.925–17:53:56.978, loaded Web `4330a799` /
`index-Bz6M9YUA.js`. The instance was confirmed stopped with no owner/runtime/warm
tags before requesting. Read-only observer included allowlisted process ancestry.

| Event | UTC | Seconds from click beginning |
| --- | --- | ---: |
| API request | 17:53:57.3758684 | 1.451 |
| EC2 start | 17:53:59 | 3.075 |
| OS boot | 17:54:07.500 | 11.575 |
| Initial stack parent PID 5220 | 17:54:32.716531 | 36.792 |
| Config snapshot write | 17:54:51.2546891 | 55.330 |
| Initial Wilbur PID 5576 | 17:55:02.0063755 | 66.081 |
| Recovery requested | 17:55:05.243 | 69.318 |
| Replacement marker | 17:55:06.4008447 | 70.476 |
| Recovery stack parent PID 2160 | 17:55:06.571462 | 70.646 |
| Replacement Wilbur PID 1728 | 17:55:27.0776747 | 91.153 |
| First captured shipping Unreal PID 6100 | 17:55:31.4183273 | 95.493 |
| Durable recovery completion | 17:56:25.011 | 149.086 |
| Runtime Ready | 17:56:25.026 | 149.101 |
| Canonical API Ready | 17:56:27.6868218 | 151.762 |

Before Wilbur, persisted Shutdown latch/cutoff matched the preceding End at
17:47:26, with no command/marker/evidence record. Auth state still blocked
admission at the prepared cutoff 17:56:19 and Ready-not-before 17:56:24;
completion occurred strictly later, with marker acknowledgement at 17:56:26.191.
New viewer admission followed at 17:56:40. Video again showed H264/30 FPS,
decoded frames and zero reported loss/drops, followed by normal End.

The tree connects initial stack 5220→Wilbur launcher 5024→Node 5576, then helper
3652→recovery stack 2160→Wilbur launcher 2608→Node 1728. Initial parent 5220
was no longer captured after recovery began. A PowerShell process with role
`other`, PID 5844, was captured with parent 2160 and child Unreal 5508→6100;
the captured Unreal is therefore a descendant of the recovery stack. Only one
Unreal generation was sampled. This run's Unreal began about 22 seconds later relative
to click than the previous run, while runtime Ready was about 21.5 seconds later.
That correlation supports investigating launch overlap; it is not a controlled
proof of its cause.

Fresh-client observations: at 33.448 and 65.246 seconds, Preparing streaming
services / less than two minutes (29% and 40%); at 118.340 seconds, Loading assets /
less than one minute (74%); at 138.146 seconds, Verifying stream / less than one
minute (94%); API Ready at 151.762 seconds, first observed Enter/100% at 157.041.
The five-minute spike did not repeat. No early Enter was observed. The configured
150-second estimate was close in this cycle, but one freshly loaded cycle does
not establish percentile accuracy or correctness on recovery/error/SQL-wake paths.

The two ordinary post-End candidates averaged API Ready **140.954 seconds**,
versus **146.724 seconds** for the two baselines: an observed **5.770 seconds
(3.9%)** difference, with overlapping ranges and only two samples per group.
These instrumented observations do not establish causal end-to-end savings.
The faster 118.583-second post-update sample belongs to a separate cohort.

The retained reset diagnostic bundle's helper log resolves another part of the
sequence: cycle 5 stopped the first Unreal PowerShell wrapper PID 5884 before
recording old-process absence. It recorded no stopped native Unreal. Cycle 4's
helper stopped only the first Node and Wilbur launcher, then later detected the
same early Unreal PID 1152. This is consistent with different launcher overlap;
cycle 4's missing ancestry still prevents assigning that Unreal to a particular
original parent. There is no proof of discarded expensive Unreal initialization
in either sample.

Recovery startup already reuses the validated instance-config snapshot when
environment/class/bundle/build match. Its repeated setup includes metadata and
service-class checks; do not call it a repeated remote config download. In cycle
5 the replacement stack spent about 11.46 seconds before creating its Wilbur
launcher, then that launcher spent about 9.05 seconds before Node. Instrument
those prerequisites before deciding which are safely redundant.

## Recommended iteration sequence

1. **Measure each launcher phase and generation.** Record monotonic duration,
   boot/launch identity, helper start/end, retry count and result category, physical
   paths and recovery reason. Preserve the current execution order. Establish
   comparable post-End samples before attributing savings.
2. **Batch initial lane/track/delivery discovery.** Share one launch-local IMDS/tag
   lookup across these resolvers, retaining standalone behavior, field-specific
   retry budgets, aliases, region precedence and failure versus missing-tag
   distinctions. Pass only validated structured values. Keep maintenance,
   provisioning, update and policy reads fresh at their present boundaries.
3. **Reuse successful service-class discovery within the same launch.** Do not
   hand off a fallback Standard value after a failed lookup: config startup is
   stricter than the outer launcher. Measure pointer/revision fetch separately
   before considering SHA-validated immutable config revision caching. Always
   refresh the pointer and preserve schema/class/identity/atomic-write checks.
4. **Review recovery orchestration separately.** First establish whether the
   initial launcher wastes Unreal initialization or actually overlaps useful
   work. A prelaunch handshake that delays Unreal could regress time. Prefer a
   bounded, generation-fenced choice of the existing safe paths if evidence shows
   useful savings. A boot-specific recovery completion path is a larger change:
   it needs explicit immutable boot/teardown provenance, host-wide launch fencing,
   authoritative assignment/control, no ambiguous evidence, original operation
   identity, existing Ready margin and durable completion without inventing a
   recycle-command acknowledgement.
5. **Improve estimates from observed phases.** Keep Enter/100% API-gated. Use
   comparable cold-start history and observed phase age, distinguish wake/queue
   and recovery, and report uncertainty with honest copy. Do not convert a phase
   percentage into time remaining. Verify the ordinary-user response shape and
   freshly loaded client, not just admin metadata or deployment build info.

Do not clear the recovery flag or delete journals for speed, shorten the skew
margin, treat raw streamer/TCP health as commercial Ready, or remove Boot/Logon
delays without task-action evidence.

### First implementation iteration

The next candidate batches the first lane/track/delivery read into one fresh
IMDS/tag lookup. Each field retains its retry budget, delay and missing-versus-
failure policy; later attempts read again. Only fixed enum tokens enter CMD.
Standalone resolvers are unchanged. A successful full-stack service-class lookup
is passed explicitly to config initialization in that launch; an outer Standard
fallback after a failure is never handed off. Config and lifecycle storage rules,
fresh maintenance/update/provisioning reads, recovery order and Ready margins
remain unchanged. Real CMD tests also fence delivery failure exit status: calling
GOTO-based retries from the prior parenthesized block could exit successfully
after refusal, so that call now runs outside the block.

Best-effort phase journals live under the install base's `diagnostics/startup`,
outside versioned bundles. Launchers enable them unless
`SCALEWORLD_STARTUP_TELEMETRY_ENABLED=false`; explicit caller settings are retained.
Per-context files separate concurrent launches and parent launch IDs connect
stack/Wilbur/config contexts. No credentials, command arguments or entitlement
contents are recorded. Journals are diagnostics and never lifecycle authority.
They survive a launcher exit without a final record. PowerShell appends and
CMD reading/finalization have size/record caps; raw CMD phase echoes do not
enforce a writer size cap. Current finite launcher phases/retries keep those
files small, but an oversized raw file is rejected by the reader rather than
truncated on write. Journals are retained for investigation, with no deletion
on the startup path; operational retention belongs outside startup.
CMD timestamps use local wall-clock centiseconds with an explicit UTC base;
the reader marks clock regression uncertain. Config phases use Stopwatch.
Parent process lookup is opt-in because CIM added startup delay; a zero launcher
PID means unknown. Local Begin measured about 0.44–0.49 seconds per process,
and an in-process phase append about 1.1–1.3 ms. Hosted samples must therefore
remain labelled instrumented. Explicit false disables new journal work.

Web keeps the configured 150-second calibration. The initial pending phase uses
the same timing model, longer configured budgets retain their appropriate slow
threshold, and `Almost ready` needs fresh finalizing evidence for the current
launch. Enter and 100% remain API-gated. More timing evidence is required before
replacing this calibration with a statistical estimate.

A fresh runtime-005 post-End baseline on 2026-10-11 reached canonical API Ready
in 150.169 seconds (runtime Ready 147.364 seconds); H264/30 FPS, zero reported
loss/drops and normal End/Teardown Completed were verified. It is recorded as
sample 6 in the timing ledger. Candidate deployment and matched measurements
were the hosted gate for this iteration; acceptance results follow below.

### Hosted acceptance and timing results

Runtime `e04dbb6dcd86233bf02cdf053bc96bd54041096c` was packaged through the
standard runtime publisher and automatically uploaded as
`pixelstreaming-runtime-20261011-002`. This was an unused artifact ID, not an
overwrite or an ordering assertion. ZIP size was 148,901,270 bytes; SHA256 was
`9ee49ea6817e9fcfcef689063f84df932eb443af9ec85c646e981e1eb73e3972`.
Dev update job `78b57d13-11ff-45f9-b9df-ec2ebe781c19` targeted only
`i-0ce5ffd16bd50eb24` and completed validation at 18:57:52 UTC on 2026-10-11.
API `e9756bf7838e9bbd899aaa35118fbbb81ef48d33` and Unreal
`ScaleWorld_20261008b.zip` were retained. No disposable instance was needed.

Web `6796143` corrected pending estimates and fresh-finalizing copy. Follow-up
`5bc95c6c06cb2bb7e635b505a0598b22cd8a56a8` only hid two decorative button
spinners from accessibility. Manual Dev workflow 1365/run `38167435055`
succeeded; the freshly loaded client was `index-Cjj904Ce.js`.

The comparable runtime-005 normal-End baseline is samples 4/5/6: canonical
API Ready **130.146 / 151.762 / 150.169 seconds** from the Request button click,
mean **144.026**, median **150.169**. Sample 4's stale Web client excludes its
UI estimate from that comparison; the canonical API endpoint remains useful.
Samples 5/6 alone average **150.966 seconds**. Provider runtime Ready and
canonical API Ready are distinct; a sparse browser observation is a bound,
not the exact Enter transition.

| Runtime-002 sample | Cohort | Runtime Ready (s) | API Ready (s) | Last disabled / first enabled UI (s) |
|---|---|---:|---:|---|
| 7 | First stopped boot after update | 111.438 | 113.766 | 95.126 / 116.291 |
| 8 | Normal End, stopped, no warm capacity, SQL awake | 123.526 | 126.311 | 122.766 / 132.764 |
| 9 | Normal End, stopped, no warm capacity, SQL awake | 143.813 | 146.378 | 140.642 / 149.543 |
| 10 | Normal End, stopped, no warm capacity, SQL awake | 125.924 | 129.006 | 113.751 / 129.043 |

Samples 8/9/10 average API Ready **133.898 seconds**, median **129.006**,
range **126.311–146.378**. The observed mean difference from baseline 4/5/6 is
**10.127 seconds (7.0%)**. Baseline and candidate ranges overlap. These are
three instrumented same-instance cases per cohort, not percentile confidence
or causal attribution. Comparing against only fresh-client baseline 5/6 changes
the reference mean to 150.966 seconds and the observed difference to 17.067;
that sensitivity must not replace the disclosed three-sample baseline.

Sample 7 had one launcher generation and recovery already cleared by update
validation. It is excluded from end-to-end savings. Samples 8/9/10 had both
original and recovery launcher generations; all six selected journals per run
were collected without rejected, omitted or partial records. Recollection also recovered all
three sample-7 journals after the diagnostic reader was updated to recognize
the newly recorded bounded metadata-attempt phase names.

A separate read-only paired measurement ran after sample 7 was playing video.
Three alternating standalone/batched pairs used fresh PowerShell processes and
the deployed scripts, with all three fields resolved successfully. Standalone
means were **6.176 seconds**, batched **2.028 seconds**: **4.147 seconds saved
per initial full-stack metadata lookup** (67.2%). This component result is
separate from total session-start time and must not be multiplied into a
guaranteed end-to-end saving.

Samples 8 and 10 captured the previously documented launcher overlap. In 8, original
stack 6000 launched native Unreal after the recovery intent/cutoff and
replacement marker. That fresh Unreal remained beside replacement Node 2728.
The current recovery contract checks old-process absence at its witness,
replacement Node/streamer health, durable completion and the Ready margin; it
does not establish exclusive replacement-launcher ancestry. The original
full-stack parent is not cancelled by the recycle matcher. This is an unresolved
generation-isolation/TOCTOU limitation, not evidence of a pre-reset Unreal
surviving cleanup. It confounds attribution of a faster total time. No recovery,
admission or margin change was made to exploit that overlap.

Sample 10 similarly retained fresh native Unreal from the original stack after
the replacement marker. Sample 9's captured final Unreal descended from the
recovery stack, matching baseline 6; a brief original Unreal cannot be excluded
by three-second sampling. Sample 9 reached API Ready 3.791 seconds earlier than
baseline 6. The larger advantage in samples 8/10 follows earlier native Unreal
birth, not a demonstrated faster final warmup. Native Unreal-to-runtime-Ready
was about 54–56 seconds in the matched candidates; that interval includes
initialization, stream stabilization and recovery holds and is not a removable
sleep. It needs finer profiling before an optimization recommendation.

| Sample | Retained cutoff UTC | Ready-not-before UTC | Runtime Ready UTC | Owner/flag observed absent by UTC |
|---|---|---|---|---|
| 8 | 19:22:45 | 19:22:50 | 19:22:51.034 | 19:22:53.300 |
| 9 | 19:34:20 | 19:34:25 | 19:34:26.034 | 19:34:28.473 |
| 10 | 19:45:07 | 19:45:12 | 19:45:13.041 | 19:45:15.205 |

All are 2026-10-11 UTC. Previous ownership and the recovery flag were observed
retained before these holds; cutoffs remained after clearing. New admission
followed the hold and clearing in every sampled run. These are observation
bounds: exact reset-completion/API reset-ack timestamps were not captured in
8/9/10. A previous Shutdown reason/command ID is inherited teardown metadata,
not proof of a new current idle/grace Shutdown. No unrequested idle/grace stop
was observed during the active canaries.

All three matched candidates delivered H264 2240×1260 at 30 FPS with decoded
frames and zero reported packet loss/drops over sustained playback, then used
normal End Session. Canonical End and Teardown Completed are recorded in the
ledger. No Ready/admission failure, stranded ownership or unexplained stop was
observed. This acceptance covers the sampled normal-End Dev path; it does not
prove SQL wake, fresh-image provisioning, outage or percentile behavior.

The user-facing comparison uses the canonical API endpoint because baseline
Enter observations had human/polling gaps. Main-ring 100% and enabled Enter
were observed together after API Ready; the hidden decorative ring is excluded.
Matched sampled `less than` bounds held. Numeric progress briefly fell back to
indeterminate preparation in 8/9; 10 captured `Verifying stream` at 92% while
Enter was disabled. No `Almost ready` observation tested its positive eligibility.
The raw 150-second calibration and existing 10-second display buffer are retained:
the slower matched sample was 146.378 seconds. Lowering the budget from the two
faster overlap cases would overfit an unresolved lifecycle timing difference.

### Next safe iterations and rollback at the previous completion

1. Completed by the PowerShell publication iteration below: measure, then
   combine Wilbur's separate UTC-generation PowerShell call with
   its existing state-file/tag publisher. Preserve state-write-before-network,
   exact format/status order, heartbeat semantics, warning behavior, exit codes
   and standalone fallback. Verify failed writes/tag failures and real CMD
   arguments, then repeat matched Dev starts. This removes process overhead
   without caching mutable lifecycle policy.
2. Profile the native Unreal-to-Ready interval and the roughly 24-second
   OS-boot-to-first-stack gap using actual task action/runtime timestamps.
   Do not infer savings from task LastRun, phase percentages or a recovery's
   total elapsed time; do not reduce Boot/Logon delays without that evidence.
3. Address original-parent cancellation/generation fencing as a separate safety
   change. First reproduce late launch, original/replacement overlap, duplicate
   Unreal, interrupted replacement, config/secret failures and stale readiness
   deterministically. A broad parent-process kill is not an approved substitute.
4. For UI copy, distinguish fresh current runtime Ready while API admission is
   pending with `Finalizing session access`; retain the API gate and avoid an
   invented countdown. Add SQL-wake/queue/failed-start cohorts before statistical
   or per-phase estimate calibration.

Runtime rollback is the immutable `pixelstreaming-runtime-20261011-005`
manifest through the normal Dev update path. Web rollback is the previously
validated `4330a799` Dev image/workflow 1360 (run 38158507506), with a fresh-client
asset check. API/Unreal need no rollback because this iteration did not change
them. Stage/Prod were not promoted. Larger recovery changes require their own
safety gate rather than a startup-speed justification.

Verification passed runtime TypeScript/lint, 99 Node + 18 Jest tests and focused
real CMD metadata retry/refusal, config/class-handoff, launcher-policy and
telemetry failure/exit-code harnesses. Web passed 1,203 tests across 129 files,
382-file source checks and Dev build. Explicit app TypeScript checking retained
103 pre-existing diagnostics, with zero added in the baseline-overlay comparison.

### History and attribution limits

Git history dates identify implementation changes, not hosted deployment dates:

| Date / commit | Change relevant to the path |
| --- | --- |
| March 20 / `46ccfa4b`; March 28 / `bf96d1bf` | Lane and track tag resolution |
| April 25 / `59dc0fd0` | Batched SSM startup reads, a prior optimization |
| May 22 / `966e7fad` | Delivery-mode resolution |
| May 29 / `fd6aacfc`; June 1 / `5558e404` | Root cleanup and active runtime identity publication |
| June 19 / `c85b3c48` | Fresh maintenance-mode lookup |
| August 23 / `d6e72bd4` | Persistent recovery latch, managed viewer evidence and Ready skew margin |
| August 24 / `90ef8acc` | Authoritative no-marker recovery decision reproduced here |
| August 30 / `7aa0fe12` | Default Unreal-first changed to Wilbur-first for media initialization ordering |
| September 1 / `02f4032e` | Service-class lookup / Premium policy |
| September 9 / `761e06c1` | Host-boot assignment reconciliation, still refusing a recovery latch |
| September 22 / `2551baf3` | Fresh config pointer/revision fetch, validation and atomic snapshot |
| October 11 / `dc9dda0d` | Successful initial-child lane/track metadata reuse |

Current observations establish an additional local recovery generation and about
44 seconds from OS boot to config write. They do not quantify each historic
change, prove the user's original 90-to-150-second trend, or account for image,
driver, task, OS, region or Unreal-content changes. Matched historical artifacts
and deployment/request timelines are required for that attribution.

### Acceptance required before changing recovery

Use real gate/agent/launcher integration coverage for connected and never-connected
Shutdown→stop→boot; same-boot Wilbur restart and full recycle; active/expired/newer
commands; tokenless and conflicting marker phases; pending/corrupt/missing evidence;
API outage/lost acknowledgement; clock skew in both directions and integer boundaries;
two launchers; persistence failure/crash between transitions; new admission racing
reconciliation. Preserve exact original teardown time and operation identity,
completed-token replay, entitlement identity and rejection of old tickets.

Then canary repeated exact-artifact post-End cold boots in Dev, checking one intended
runtime generation/launcher, unchanged commercial end, acknowledged recovery,
fresh entitlement and usable video. Keep an immediate rollback and current-safe-path
fallback. Stage/Prod remain separate promotion gates. No disposable instance is
needed for normal observation; fault injection or host/task changes should use an
isolated instance when shared Dev would be affected.

## Historical observation completion (before this implementation)

Both follow-up sessions ended through End Session. Analytics recorded candidate
4 and 5 as Teardown Completed; candidate 5's End timestamp was
17:58:18.4881308 UTC. At 18:04:23 UTC, d1/d2/d4 were verified stopped with no
owner, mode, maintenance, warm-pool or runtime-status tags in the allowlisted
fleet check. No disposable instance, new artifact, deployment, fault injection,
task change or admission/recovery change was performed during this investigation.

The prior implementation removed duplicate resolver calls. This pass establishes
no additional implemented time saving and no causal end-to-end savings claim.
Its outcome is a more comparable timing record, a successful fresh-client ETA
observation, and a staged investigation plan with explicit acceptance gates.

Evidence provenance: read-only state observers were SSM commands
`2e7acd3d-ddba-4327-883d-ad3ac767a7d6` and
`1048b446-fe86-41e8-85b1-e106e9a353ff`. Recovery logs were captured from the
physical runtime 005 root and the retained reset diagnostic bundles for recycle
`faf1d047-c6f2-4b08-ab08-08306ea9ae1b` and
`48b77210-7e9a-4939-883d-6a4bdf19cf8b`. Candidate 5's retained bundle SHA-256 was
`b185d86b2699bf646fa931db5228fe67c76f9f3e4d09a9e007d577e6cb812af1`.
Canonical click-relative timings and exact build identities are maintained in
the Web owning docs' `docs/evidence/cold-start-20261011.csv`. Raw observations are
retained locally rather than committing actor or payload data.

## Previous implementation completion

The authorized implementation and matched Dev acceptance are documented above;
the historical observation-only statements describe the earlier pass. Runtime
`e04dbb6d` / artifact `pixelstreaming-runtime-20261011-002` and Web `5bc95c6`
were deployed at completion of that iteration. Documentation commits do not
change those identities.
Both repositories use `perf/cold-start-iteration`. All candidate sessions ended
through normal End Session and reached Teardown Completed. At 19:58:40 UTC on
2026-10-11, Dev d1/d2/d4 were verified stopped. Only d1 received the runtime update;
no disposable instance was provisioned and Stage/Prod were not promoted.

## PowerShell publication iteration (2026-10-11)

Runtime code `26ee94ea453d5d6f01f1a5268d9bf08dd3d26046` consolidates Wilbur's
UTC generation and local startup state write into its existing synchronous tag
publisher. The two ordinary status transitions now use two PowerShell processes,
previously four; both AWS writes remain. This count is verified by source and
the focused execution harness, not by process telemetry in the timing fixture.
Recovery, launcher generation handling, admission, readiness and hold rules
were not changed. The launcher-overlap recovery fix remains separate work.

The optional `StartupStateFilePath` parameter is appended after existing
parameters. State still precedes the AWS call, retains its raw five-line format
and transition timestamp, and receives a separately fresh publication heartbeat.
State I/O failure warns and permits tag publication; AWS failure remains nonfatal
to the launcher. Missing-helper state-only fallback, standalone default/explicit
timestamps and existing positional callers are preserved.

The clean immutable `pixelstreaming-runtime-20261011-003` artifact was built with
Node `v22.23.2` / npm `11.6.0`, using the normal runtime publisher. Its ZIP is
146,797,197 bytes with SHA-256
`33e4e61f0ceda8c49a67661db0cc8382dda0038b17043532a2f0d189153989d0`.
Both changed packaged source files matched the reviewed checkout. Dev update
job `24b438f1-d913-4555-ac68-c78c3de9d301` targeted only d1 and validated the runtime
at 20:54:18.4996861 UTC. API `e9756bf7`, Web `5bc95c6` (fresh client asset
`index-Cjj904Ce.js`) and Unreal `ScaleWorld_20261008b.zip` stayed unchanged.

### Controlled component measurement

On the playing Dev d1, three alternating paired trials ran the actual old/current
CMD status labels and publishers in unique temporary fixtures with a native AWS
stub. Each trial covered two transitions. Baseline source `5fcac6a0` is identical
for these files to deployed baseline code `e04dbb6d` / runtime 002.

| Pair | Order | Baseline | Candidate | Difference |
| --- | --- | ---: | ---: | ---: |
| 1 | baseline, candidate | 3.186232s | 2.858814s | 0.327418s |
| 2 | candidate, baseline | 3.158373s | 2.884182s | 0.274191s |
| 3 | baseline, candidate | 3.119286s | 2.856391s | 0.262895s |
| Mean | alternating | 3.154630s | 2.866462s | **0.288168s** |

SSM command `e57de66f-124c-4d95-aaee-225661cfdea2` succeeded with stable exact
artifact/source provenance, two stub calls per trial, state-before-AWS, argument,
payload and timestamp checks, and fixture cleanup all passing. It made no real
EC2 calls or lifecycle state writes. This establishes component savings per two
transitions; it does not measure real AWS latency or whole cold-start savings.
The sanitized [component evidence](../../scaleworld-server-manager-web/docs/evidence/powershell-overhead-component-20261011.json)
retains per-trial results, source hashes and verification flags.

### Matched cold-start observations

The primary comparison uses all four comparable runtime-002 post-normal-End
starts (8–11) and three runtime-003 post-normal-End starts (13–15). The fresh
baseline 11 was measured before this update. SQL was active, d1 was fully stopped
before each request, and no warm pool was available. API/Web/Unreal identities,
instance class and the read-only SSM instrumentation were held constant.
Sample 12, the first boot after the artifact update, is recorded separately.

| Cohort | Samples | Click → runtime Ready | Click → canonical API Ready |
| --- | --- | ---: | ---: |
| Baseline runtime 002 | 8–11 | 134.146s mean | **137.121s mean** (126.311–146.789s) |
| Candidate runtime 003 | 13–15 | 124.272s mean | **127.280s mean** (125.349–130.632s) |
| Separate post-update | 12 | 111.437s | 114.319s |

Candidate API times were 125.349 / 130.632 / 125.859s. The observed mean
difference is 9.841s (7.18%). This is not a causal saving established for the
PowerShell change: small instrumented sequential cohorts have no concurrent
control and different original/replacement launcher ancestry distributions.
The isolated component measurement above is the attributable saving.

Live normal-launch identity→heartbeat→Node-scheduled spans decreased from
4.890s mean (4.88–4.91s) to 4.677s (4.67–4.68s), an observed 0.213s difference.
Recovery spans increased from 5.865s mean (4.87–7.13s) to 7.700s (7.03–8.94s).
Candidate recovery spans were 8.94 / 7.13 / 7.03s; retain the slower result.
These live spans include synchronous AWS process/network time, heartbeat
handling, scheduling and diagnostics. Node-scheduled timestamps are distinct
from actual process birth. No evidence supports removing either AWS write or
making lifecycle publication asynchronous in this iteration.

All candidate startup journal collections were complete, with no rejected,
omitted or partial records, uncertain clocks or observed config failures.
Recovery cutoff/hold and admission ordering were checked against timestamped
state observations. The five-second hold is unchanged; exact API reset
acknowledgements were not captured, so marker/field removal remains bounded by
observation timestamps. Usable sustained video was observed in each candidate
cycle: 29–30fps and zero lost packets/dropped frames at the sampled checkpoints.
Baseline 11 later had 1,568 lost packets and must not be reported as zero-loss
throughout. The known original-launcher Unreal/replacement-Node overlap persists;
exclusive generation isolation is not established by this change.

See the [timing ledger](../../scaleworld-server-manager-web/docs/evidence/cold-start-20261011.csv) and
the [fixed-cohort results](../../scaleworld-server-manager-web/docs/evidence/powershell-overhead-results-20261011.json)
for raw per-cycle endpoints, phases, recovery bounds, media and ancestry limits.

### User-facing estimate evaluation

The unchanged main progress ring had no sampled decrease, premature 100% or
early Enter across 16 visible matched-candidate checkpoints. All 5/5 strict
upper-bound messages held for API and bounded page readiness; five rounded
"about" messages are recorded separately. No Almost-ready or late generic
handoff checkpoint was captured. First-page-Ready observation bounds were
13 (95.084,142.537]s, 14 (105.353,130.911]s and 15 (106.188,133.381]s;
gaps from canonical API Ready are not exact client detection latency.

The raw 150s reference budget's MAE was 12.879s on baseline 8–11 and 22.720s on
candidate 13–15. It was more conservative against these faster observations;
this is separate from displayed-copy/countdown error and does not establish
improved estimate algorithm accuracy. Retain 150s and its existing initial 10s
display buffer. See the [ETA evidence](../../scaleworld-server-manager-web/docs/evidence/powershell-overhead-eta-20261011.json).

### Verification and follow-up scope

Windows PowerShell 5.1 real-CMD/native-shim tests passed for state-before-AWS,
all six tags, fresh heartbeat/default/explicit timestamps, positional callers,
disabled/no-identity behavior, missing-helper and UTC failure, visible state-I/O
failure continuation, nonfatal launcher AWS failure, raw state versus normalized
tag payload, and the actual heartbeat reader with ASCII/UTF-8 BOM fixtures.
The stack-launcher policy/service-class execution harness passed. Pinned Node
22 runtime TypeScript, lint, 99 Node tests and 18 Jest tests passed. Independent
source and actual benchmark reviews found no remaining scope/semantic concern.
No Web source changed, so prior Web suite results remain historical evidence.

Retain the current estimate budget and API Ready gate. Further calibration needs
more starts with comparable generation behavior and separate SQL-wake/queue
cohorts. The next measurement work should profile actual task execution and the
native Unreal-to-Ready interval. Launcher cancellation/generation fencing remains
separate recovery safety work with the integration gates documented above.
Current runtime rollback is immutable `pixelstreaming-runtime-20261011-002`
through the normal Dev artifact update path; API/Web/Unreal were unchanged.

### Iteration completion

Samples 11–15 ended through normal End Session and were verified as Teardown
Completed in Session Manager Analytics. Final sample 15's canonical End was
21:35:26.6307275 UTC. At 21:41:54.8315402 UTC on 2026-10-11, Dev d1/d2/d4 were
verified stopped. Only d1 received runtime 003; d2/d4 retained runtime
`pixelstreaming-runtime-20261009-003`. The final allowlisted fleet check found
no current owner, session-mode, maintenance, warm-pool or runtime-status keys;
d2's retained LastInstanceStartWarmPoolPolicyId is historical metadata.
No disposable instance, host/task override or Stage/Prod promotion was performed.
The fixed-cohort evidence includes these independently verified hosted completion
gates alongside the separate pre-End startup observer limits. Both repositories
remain on `perf/cold-start-iteration`; documentation commits do not alter the
deployed runtime/API/Web/Unreal identities.

## Task delay investigation follow-up (2026-10-12)

The [Task Scheduler investigation](task-scheduler-delay-investigation.md) confirms
Dev d1's inherited 20-second Boot and 30-second Logon delays. One additional
unchanged-runtime baseline (16) measured 25.280s from OS boot to the normal stack
process and 146.228s from click to canonical API Ready. Task history is disabled;
first-action timing, early prerequisite readiness and the normal optional-pointer
configuration branch remain unresolved. No delay or deployed behavior changed.
The report defines a gated 20-to-15-second Dev trial and restoration criteria,
with launcher-overlap recovery work kept separate.
