# Cold startup measurement and recovery investigation

This document owns the measurement method and proposed investigation sequence
for stopped-instance startup without warm capacity. It does not authorize a
change to admission, recovery or commercial lifecycle rules. Measurements below
are from Dev on 2026-10-11 using the already deployed metadata-handoff candidate.
This investigation changed no recovery, admission, lifecycle or startup code.

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

### Recovery acceptance before any hosted optimization

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

## Observation completion

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
