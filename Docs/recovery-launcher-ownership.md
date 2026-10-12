# Recovery launcher ownership

## Bounded preparation follow-up

Branch `perf/recovery-preparation-once` adds an optional receipt for an immediate
replacement of a fresh, incomplete artifact launch. The receipt binds the
source generation and Node birth, current OS boot, resolved environment and the
hashes of runtime metadata, configuration snapshot and Unreal build state.
It expires after 90 seconds and cannot be propagated by a replacement.

The recycler selects it under the existing ownership lock and binds it to the
reserved generation, recycle operation, helper dispatch and live independent
monitor. Replacement entry rechecks the inputs. Invalid, changed or missing
evidence uses the existing full preparation path. No receipt grants spawn,
replacement proof, Ready, reset completion or admission.

Routing, maintenance and service-class lookups remain fresh. Reuse avoids
repeating active-runtime identity publication, the immutable instance-ID lookup,
current-build tag publication and secret retrieval for the immediate replacement.
Later recycles and maintenance/validation launches retain full preparation.
`SCALEWORLD_STACK_PREPARATION_REUSE_ENABLED=false` disables this optimization.

Hosted acceptance is pending. Compare disabled and enabled runs of the same
candidate at the captured Dev task delay; keep runtime `20261011-003` as rollback.
The temporary early-boot probe only records local/IMDS prerequisite availability.
It does not launch stack components or prove GPU encoder readiness. Neither the
20-second fleet default nor the previous isolated Dev 15-second setting changes.
Legacy migration safety remains a separate promotion gate.

## Scope and baseline

This iteration prioritizes exclusive, verifiable recovery ownership over startup
speed. It branches from `a31a44c5f7272348fe598f28e040a9370e9fe46a` on
`fix/recovery-launcher-overlap`. The `d17821a` recycle-ready recovery changes
remain in its ancestry. API, Web, Unreal and admission policy are separate from
the launch-attempt registry.

The comparable preceding Dev d1 samples 19–21 used runtime
`pixelstreaming-runtime-20261011-003`, a 15-second Boot trigger and the same
Unreal package. Click to canonical API Ready was 124.653 / 123.267 / 123.933
seconds (mean 123.951). All three retained the original full-stack launcher's
ability to create Unreal after replacement proof. That overlap makes their
whole-start times unsuitable as an exclusive-generation correctness baseline.
See [boot-delay results](task-scheduler-delay-results.md) for the exact ledger.

The task delay remains 15 seconds on this isolated existing Dev instance. It
must be restored to 20 seconds before ordinary reusable AMI baking. This
iteration does not reduce the recovery cutoff, five-second hold, entitlement
fences, exact API acknowledgement requirement or user-facing estimate budget.

## Failure being addressed

The detached recycle helper can stop Wilbur and Unreal while the original
`start_streamer_stack.bat` CMD and its PowerShell children remain able to
launch later. A delayed watchdog or scheduler retry can also outlive that
cleanup. A listener becoming ready does not identify which attempt produced
it. Killing the whole process tree would also kill the detached recycler.

## Ownership protocol

1. Full-stack entry registers the exact Windows CMD PID, creation time,
   executable and canonical entry path before configuration or health-file
   side effects. A durable launch UUID identifies this attempt.
2. A short install-base mutex serializes entry, actual Node/Unreal spawn,
   cancellation and replacement reservation. It is released during normal
   runtime operation and readiness waits.
3. The leased Wilbur wrapper records its actual direct Node child's PID,
   creation time and canonical executable under that spawn lock. Original CMD
   `CALL` argument semantics and synchronous exit status are preserved by a
   small native BAT.
4. A dispatch binds its fresh helper UUID to the current launch UUID and
   exact source Node birth. The recycle operation/token/request and original
   requested timestamp are retained. An old marker without dispatch fields
   remains readable; a new dispatch must obtain a current verified pin.
5. Before destruction, the helper checks the immutable intent, dispatch,
   launch and source identities. It revokes the old attempt, cancels verified
   CMD/PowerShell producers while preserving its own branch, and proves Node
   plus bootstrap/Shipping absence.
6. Only then may it publish replacement-started proof and reserve one exact
   replacement CMD. Its grant travels in the child environment and is pinned
   before the lock is released. Late children from revoked attempts fail at
   their actual-spawn gates.
7. Successful launch records a live Node pin so a normal scheduler retry
   cannot delete replacement health/config after marker acknowledgement.
   Incomplete startup, markerless recovery and Git-sync handoff have explicit
   paths rather than a permanent duplicate latch.

The lease is stored at `<install-base>\state\stack-launch-lease.json`; it is
process ownership evidence, not admission or reset-completion authority.
Dead identities are reclaimable except for the terminal `stopping` fence
described below. Ambiguous identity, malformed state, failed I/O, lock timeout
or unverified child cleanup fails closed.

Every entry checks for actual scoped Node processes before writing a new lease.
A live unregistered Node causes a harmless skip before health/config changes,
even after the monitor and other recorded actors have died. It is never adopted
by a new generation. Only an exact registered Node may survive an ungranted
repair in its existing generation; unavailable executable identity or discovery
failure denies entry. Verified absence or explicit operator repair is required
to resolve an unregistered survivor.

## Recycler death and bounded disposition

Revocation creates an additional operational responsibility: a surviving old
watchdog cannot restart through the revoked generation. A completed startup
task provides no further retry. API command/reset timeouts intentionally retain
ownership; reservation/demo expiry requires the embedded Node agent to execute
Shutdown. None is an independent provider-stop fallback for an absent agent.
The older recycler also had a crash window after killing the watchdog.

Before revocation, the helper must start an independent operation monitor,
retain its exact process handle and verify its readiness receipt. The revocation
write binds that monitor to the planned replacement generation, recycler birth,
recycle operation and helper dispatch. Producer cancellation preserves this
separate child branch. The monitor neither repeats destructive cleanup nor
advances intent, reset completion, request ownership or admission.

The normal default waits compute a 601-second decision deadline: three
120-second component waits, the 120-second health wait, a 120-second cleanup/
receipt allowance and the 250 ms pre-termination wait, rounded up. Larger
explicit helper wait budgets increase it. Helper death does not shorten this
deadline while a replacement may still be initializing. Normal marker
completion/removal or supersession ends monitoring without action. A completed
lease with an exact live replacement Node also permits early handoff; a Node
birth pin while the lease is still `starting` does not.

At the deadline, terminal shutdown requires the same operation and dispatch,
the same lease/monitor/helper identities, and no live replacement Node under
the lifecycle mutex. A fresh scan of the exact runtime Node executable also
blocks shutdown for an unpinned or ambiguous process. A hung exact helper can
be terminated through its retained handle only after a preliminary operation
check, followed by the authoritative mutex recheck. Under that lock, the
monitor cancels only verified exact `start_wilbur_native.bat` Windows CMD
invocations through birth/executable-bound retained handles and proves those
tiny producers absent. It then repeats the Node check before the durable
`stopping` transition. Whole-marker binding is rechecked after cancellation,
after the transition and after diagnostic I/O immediately before shutdown.
An unparsed invocation, process-discovery error or surviving unclassified Node
denies the terminal action; the monitor never kills arbitrary CMD processes.
An exact native launcher in another runtime root also prevents this host-wide
shutdown; it is not killed or silently treated as unrelated. Concurrent runtimes
on one host need a broader ownership/safety contract before relaxing that rule.

The `stopping` fence rejects reserved replacement entry, recycling and actual
Node/Unreal spawn even if the monitor subsequently dies or shutdown fails.
Same-boot ordinary entry cannot reopen it. Only a new normal entry with all
stored actor/Node identities dead and positive OS boot time strictly newer
than the recorded monitor birth can create a fresh launch generation.

The terminal action is local Windows shutdown; Dev d1's current
`InstanceInitiatedShutdownBehavior` is `stop`. Actual EC2 stopped state, rather
than a successful shutdown command, is the hosted acceptance criterion.
The token, ticket cutoff, recycle marker and request provenance remain intact.
At the deadline, an exact live replacement Node retains the existing agent's
shutdown/recovery authority. Ambiguous state, an unclassified Node or an
unavailable mutex can deny shutdown beyond the deadline, so 601 seconds is
not an unconditional stop guarantee. This narrow safeguard does not supervise
a live but hung agent or survive an external kill of both recycler and monitor.
Such cases require separate work.

### Operational handling

| Observation | Operational response |
| --- | --- |
| Monitor fault says local shutdown requested | Retain the matching lease, marker and actor births; verify actual EC2 Stopped separately before requesting a fresh boot. The diagnostic alone proves a declared request. |
| Live or unclassified Node, failed discovery, or unavailable mutex | Preserve process and recovery state. Collect exact identities and logs for operator review; the monitor intentionally refuses destructive action. |
| Both recycler and monitor externally lost, or a live hung agent | Treat as uncovered automatic recovery. Use the existing authorized operational lifecycle after checking session ownership; never clear state or manufacture Ready to bypass the fence. |
| Old Task Scheduler run has result -1 | Corroborate its cancelled original launcher from ownership evidence. The numeric task result alone does not establish success or failure. |
| Runtime update from a leased Git checkout | Do not use this artifact canary as migration approval. The unsupported relocation requires its own pre-activation ownership design. |

## Deployment and rollback gates

The maintenance audit found regressions introduced by early ownership:
the synchronous boot CMD could block update validation, and re-resolving its
active-junction invocation after activation could misclassify that live owner
as dead. Artifact pruning could also remove its physical source release when
only junction paths appeared in process command lines. Explicit maintenance
handoff and source-release retention are implemented and checked before packaging.
Same-runtime Unreal updates, changed-runtime validation, provisioning transfer,
handoff failure and legacy rollback must pass separately.

Maintenance captures the physical source root and the direct PowerShell child of
the exact starting CMD before activation. Liveness pins the original lexical CMD
invocation as well as PID, birth and Windows executable; retargeting an active
junction does not turn that live owner into a dead actor. Under the same lifecycle
mutex, transfer requires current source ownership, no live recovery, and actual
source/target Node and tiny native-producer absence. It revokes the old generation
and reserves the exact target CMD with a normal or validation grant. Failed spawn
or pinning leaves the revoked handoff durable; it never restores old ownership.

The original BAT captures the maintenance exit code and exits from its already
parsed block before calling a telemetry label on terminal success or failure.
This matters when an update retargets its junction to a BAT with different label
positions. Same-root nonterminal continuation retains its telemetry. Update
failure schedules the existing delayed stop (1,800 seconds) and returns the hold
code. Provisioning retries within its existing bootstrap budget (normally 900
seconds), or returns failure through the existing task retry path; it does not
gain an immediate-stop guarantee. A revoked source cannot continue config/spawn
even if provisioning subsequently retries a same-root installation.

Installer pruning protects the captured physical source bundle before activation.
Malformed or unclassifiable lease state skips pruning with a warning. This read
does not grant launch or kill authority. A leased source may reserve an older
runtime with neither lease helper present, clearing the inherited generation.
That legacy validation is explicitly unclaimed and must use the existing runtime
validation and provider stop; a partial helper pair is rejected.

A leased Git source relocated into an archive and replaced by a junction is
currently rejected before handoff mutation because its captured physical root no
longer identifies the source directory. That migration needs a separate
pre-activation ownership protocol. Existing unleased migration remains unchanged;
this canary must not be taken as acceptance of leased Git-to-artifact migration.

Install a coherent immutable bundle on stopped Dev d1 only, then use a fresh
normal request. Do not trust-migrate an existing unleased Node process. Every
new helper must ship in the bundle. Older rollback bundles remain installable;
the installer contract is not changed to require the new helper filenames.

Rollback uses immutable runtime `pixelstreaming-runtime-20261011-003` after
normal session teardown and confirmed EC2 stopped state. Do not clear recovery
markers, ticket cutoffs, completion tokens or manually manufacture Ready.
The durable lease is ignored by old code and retained for diagnostics; a
future leased boot validates process births rather than trusting its old PIDs.

## Validation record

Verified local checks comprise the PowerShell 5.1
[lease harness](../SignallingWebServer/platform_scripts/powershell/test_stack_launch_lease.ps1)
(129 assertions), the maintenance unit harness (30 assertions), 106 Node tests
and 18 Jest tests, plus the focused
[monitor harness](../SignallingWebServer/platform_scripts/powershell/test_stack_recycle_monitor.ps1)
and [launcher policy harness](../SignallingWebServer/platform_scripts/powershell/test_stack_launcher_policy.ps1).
Hosted gates remain separate from these local checks.

The final [maintenance process evidence](evidence/recovery-maintenance-local-20261012.json)
records five real Windows CMD/PowerShell 5.1 scenarios and 50 passing assertions
against unchanged hashes for seven runtime scripts, the harness and BAT. It
exercises the actual validation function, provisioning transfer helper and BAT
maintenance blocks, including different target layouts, retained revoked ownership
on pin failure, and legacy rollback/return. No fixture process or directory
remained. Cloud installation, native Node/Unreal and media were not exercised.

The pre-maintenance real Windows entry/spawn/monitor matrix passed 39 cases
and 234 assertions with unchanged hashes for all 17 owning sources and its
harness, zero surviving fixture processes and unconditional fake shutdown.
It covered stale dispatch and PID/birth mismatch rejection before mutation,
failure cleanup, exact reserved-child grants, incomplete startup repair,
markerless recovery, Git handoff, original argument/exit behavior, recycler
death, tiny native-shell orphan races and final marker/Node rechecks.
The final [integrated process ledger](evidence/recovery-concurrency-local-20261012.json)
passed the same 39 cases and 238 assertions (215 behavioral, 22 source/harness,
one cleanup) against unchanged hashes for all 21 runtime sources and the final
harness. No fixture process or directory survived. Shutdown was unconditionally
fake in every disposable monitor-module copy.

The [verification history](evidence/recovery-concurrency-history-20261012.json)
retains the first integrated rerun's missed fake shutdown at its after-producers
checkpoint. Its cause remains unclassified because the pre-cleanup raw state was
not retained. The diagnostic repeat and final run both passed; final tracing
recorded no exception, an unchanged intent marker and `ShutdownRequested`.
No waits or assertions were weakened. The scoped Dev tests now cover ordinary
startup, recovery, a healthy scheduler retry, recycler loss at the default
deadline, retained-state reboot and a rollback/reapply round trip. The legacy
maintenance limitations below prevent an unqualified production-safety
conclusion.

## Immutable candidate and observed Dev timings

Runtime `pixelstreaming-runtime-20261012-001` packages source
`75768d8f199d28fca2bbb6a0336e53a548268ee0`. Its 146,890,542-byte ZIP has SHA256
`ec305a90308cc6d4e9e89316eddbfd1f9bcc8827a65fbc51ec65a7ccc5beb2a9`.
The full uploaded ZIP and manifest were independently read back and verified.
All 21 accepted launcher/monitor production files match the packaged source;
the compiled recycle state and idle-stop modules match the rebuilt outputs.
No mutable lease, marker or fixture state is packaged. See the
[artifact receipt](evidence/recovery-artifact-20261012.json).

The initial stopped-d1 canary job `5107bb53-1c86-48fc-b6cb-cc15296b59e5`
succeeded, validated the native runtime and stopped the provider target.
The following request cycles used API `e9756bf7838e9bbd899aaa35118fbbb81ef48d33`,
Web `5bc95c6c06cb2bb7e635b505a0598b22cd8a56a8`,
Unreal `ScaleWorld_20261008b.zip` and the unchanged 15-second Dev trigger.

| Cycle | Path actually observed | Click to trusted API Ready |
| --- | --- | ---: |
| 19–21 baseline | Cold recovery with original-launcher overlap | 123.951 s mean |
| 22 candidate | Normal cold startup; no recovery transition | 108.872 s |
| 23 candidate | Real cold recovery; helper-only injection missed, zero kills | 144.769 s |
| 24 candidate | Real cold recovery; compound injection aborted before any kill | 148.261 s |
| 25 candidate | Real cold recovery; identity guard aborted before any kill | 146.986 s |
| 26 candidate | Real cold recovery; pre-launch intent changed before any kill | 147.910 s |
| 27 candidate | Exact helper-only loss; monitor shutdown and request failure | No Ready |
| 28 candidate | Fresh boot recovering the retained failed operation | 145.563 s |
| 93 candidate | Ordinary cold startup after rollback/reapply; no recovery | 111.101 s |

Cycle 22 is a different path from the recovery baseline and cannot establish
15 seconds of savings. Cycles 23–26 show a 146.982-second recovery mean, or an
observed 23.031-second increase over the earlier overlap mean. This is a small,
instrumented sample, not an estimate of an independently proven exclusive
recovery baseline or a speed benefit. All four fault-injection attempts must remain
classified as uncovered; successful ordinary recovery is not monitor-failure
coverage. The runtime remained frozen while the outside-repository fault tooling
was diagnosed. Those guards also add instrumentation load, so these are healthy
recovery observations under fault-guard instrumentation, not clean performance
controls. The product holds its ownership lock through pre-entry cancellation
and replacement pinning; acquiring that lock before helper death would miss
the pre-entry fault window by construction. Cycle 26 instead rejected a
pre-launch intent that advanced during read-only screening, before any kill.

Cycle 93 is the final restored-candidate health check. It is another ordinary
startup without a recovery transition, so it does not measure savings against
the earlier recovery baseline. No startup speed gain is established by this
reliability iteration.

The [normal cycle 22 receipt](evidence/recovery-normal22-hosted-20261012.json)
records a harmless demand retry, unchanged Node/Shipping identities, unchanged
lease/config bytes and no new stack journal. ScheduledTasks CIM returned bad
seconds on this host; the exact named Task Scheduler COM registration supplies
the demand-run chronology. Real recovery cancels its original task CMD, which
can leave the previous task result at signed -1/unsigned 4294967295. That result
alone is neither retry failure nor proof of safe cancellation; the ownership
trace must corroborate the original run before a new demand retry is tested.

Cycle 25 independently corroborated the original task CMD birth and its
cancelled COM result, then demanded the exact named task once. The fresh COM
run completed with result 0. Exact Node/Shipping births, lease/config bytes and
task XML were unchanged, with zero new startup-stack journals. Sustained media
remained usable for nearly eight minutes before normal End Session. This is a
healthy completed-stack retry test, not a failure-monitor test.

## Hosted recycler-loss and retained-state recovery

Cycle 27 used a separately reviewed helper-only injector. It killed only the
exact recycler PID/birth, confirmed its exit, then observed zero scoped runtime
Nodes, a live exact monitor and unchanged lease/intent. It did not kill source
actors, change markers, shorten the deadline or request shutdown. One known
outer launcher CMD remained in the sampled producer inventory; this is not
evidence of full source quiescence. Source Node absence was observed rather
than attributed to natural exit or to the injector.

The matching generation/helper/monitor fault record declared
`recycle_replacement_node_absent_at_deadline` and `local_os_shutdown_requested`
at 05:12:23.6297864 UTC. Windows System event 1074 declared the canonical
System32 `shutdown.exe` 49.0044 milliseconds later, and event 6006 followed at
05:12:32.7960715. Independent EC2 reads first observed Stopping at
05:12:40.8819055 and Stopped at 05:17:20.1895597. There was no user cancellation
or admin/fleet/release action before that stop. These correlated records support
monitor-triggered shutdown and separately prove provider stop; the event alone
does not uniquely identify its caller. The default 601-second budget was kept.
Its exact deadline is not persisted; the action falls within the deadline bounds
derived from retained helper/monitor births.

The API failed the pending request when the provider stopped, with no Ready or
connection acknowledgement. During the failure wait, the request page continued
to say to keep the page open while warming up, with an indeterminate bar and no
numeric estimate. It eventually showed the failed-request message and permitted
a new request. Failure detection and explanation are separate API/Web follow-up
work; neither was changed in this runtime canary.

Cycle 28 used Request ScaleWorld after confirmed stop, preserving the failed
lease, recycle intent and ticket cutoff. The new boot reclaimed ownership and
reached trusted API Ready in 145.563 seconds from the click. It acknowledged a
real connection and streamed 2240 by 1260 video for over two minutes, with input
enabled and zero displayed packet loss or dropped frames at the final sample.
Normal End Session completed at 05:28:43.5702148 UTC. Independent EC2 reads
first observed Stopped at 05:34:07.3038628; all three Dev targets were verified
stopped at 05:34:10.1171207. The operation-correlated application log records
the agent's successful acknowledgement/marker-clear branch; it is not an
independent API event-store or token-completion receipt. See the
[failure receipt](evidence/recovery-failure27-hosted-20261012.json) and
[retained-state boot receipt](evidence/recovery-retained28-hosted-20261012.json).
Maintenance rollback/reapply evidence and its limitations are recorded below.

On cycle 28, the page showed 48% and “Ready in about 1 minute” at 93.501
seconds, with 52.062 seconds remaining to API Ready. At 104.791 seconds it
showed 54% and the same estimate, with 40.772 seconds remaining. At 132.113
seconds it showed 94%, “Verifying stream” and “Ready in less than 1 minute,”
with 13.450 seconds remaining. These coarse estimates fit this successful
sample. They do not establish calibration across regions or failure paths.

Hosted acceptance must demonstrate old-producer cancellation, exclusively
replacement-owned Unreal, unchanged cutoff/hold/reset acknowledgement,
sustained usable media, harmless scheduler retries, normal End Session and
verified stopped Dev targets. Timing changes are reported even if safety
increases startup time. Neither local process fixtures nor compilation prove
hosted lifecycle or media reliability. Stage/Prod promotion remains outside
this iteration.

## Hosted maintenance round trip and remaining migration risk

After normal teardown and confirmed stop, cycle 91 rolled only Dev d1 from
candidate `20261012-001` to legacy `20261011-003`. Native validation succeeded
at 05:41:08.5249609 UTC; independent EC2 reads first observed Stopped at
05:46:26.4205898. All 41 retained observer records were recovered; the planned
observation was interrupted by shutdown. The bounded startup
collection has seven journals with no omissions, rejected records or partial
tails. The source release was retained while sampled source actors were live.
Their first observed absence followed the first provider Stopping observation,
so exit before shutdown is unproved. Legacy validation produced two Node births
and one Shipping birth, with Shipping surviving across the legacy Node recovery.
This validates the observed rollback and provider stop; it is not proof of a
fresh full native replacement or of ownership enforcement by the older runtime.
See the [rollback receipt](evidence/recovery-maintenance91-hosted-20261012.json).

Cycle 92 reapplied the identical candidate to stopped d1. Validation succeeded
at 05:53:31.6991802 UTC; independent EC2 reads first observed Stopped at
05:58:47.8210580, and all three Dev targets were stopped at 05:58:51.4084134.
The entire 34-record observer and all four startup journals were recovered on
the next boot. Target validation had a completed lease with exact owner and Node
PID/birth pins and Shipping ancestry. Node's observed active-alias executable
path mapped to the captured target pointer; a separate OS canonical-path proof
was not captured. The original legacy normal journal recorded terminal
`update_control.completed` with exit 10 and no subsequent normal startup phase.
The [reapply receipt](evidence/recovery-maintenance92-hosted-20261012.json)
retains the exact sampled process identities and pointer-mapping qualifications.

The older installer nevertheless removed its physical source release while
its exact original CMD and updater were still sampled alive. Its existing prune
logic relies on literal physical paths in command lines, and its BAT calls a
telemetry label after junction retargeting before handling terminal exit. Both
versions preserve the caller's exit code; the risk is source retention and BAT
continuation across changed layouts. Candidate source-retention and terminal
exit handling cannot retrofit an installer already running from legacy 003.
This successful pair does not establish safe migration from every installed
legacy version, under retention pressure, or with different BAT layouts.

### Recommended next reliability iteration

Keep the candidate confined to Dev while designing an explicit legacy migration
step that protects the physical source until its launcher and updater have
exited, and prevents the old BAT from resuming through a retargeted file. Validate
that path using the actual installed legacy versions, journal chronology,
exact actor births, target ownership, native media and provider stop before
wider promotion. Leased Git-to-artifact relocation remains unsupported and
requires a separate pre-activation design. Live hung agents, simultaneous loss
of helper and monitor, and ambiguous identity remain operator-handled cases.

API/Web failure messaging is separate follow-up work: surface a recovery fault
and a clear delayed-start explanation earlier than provider stop, without
weakening admission, marker acknowledgement or lifecycle authority. No estimate
or progress-bar code changed in this reliability iteration.

## Final restored-runtime health check

Cycle 93 used Request ScaleWorld from confirmed stopped Dev capacity after
reapply, with no fault injection or direct task retry. The completed observer
contains 19 records, and all three startup journals are normal with recovery
required false and no omissions or rejected records. One fresh generation
progressed from starting to completed. Node and Shipping ancestry were
co-captured with exact births under its owner. The prior-boot ticket cutoff
remained unchanged; it was not a recovery cutoff created by this request.

API Ready arrived in 111.101 seconds from the click and connection acknowledgement
followed. The final player sample showed 2240 by 1260 video at 30 FPS, over
147 seconds of playback, input enabled and zero displayed packet loss or dropped
frames. Normal End Session completed at 06:12:27.0185271 UTC. At 91.625 seconds,
the page showed 75% and “Ready in about 1 minute”; API Ready was actually
19.476 seconds away. Sparse UI observations do not measure exact refresh delay.

Independent EC2 reads first observed d1 Stopped at 06:17:49.9060269 UTC; all
three Dev instances were verified stopped at 06:17:50.3510596. d1 retains
`pixelstreaming-runtime-20261012-001`; the other two instances retain their
previous runtimes and drains. Stage and Prod were not deployed. See the
[final normal-session receipt](evidence/recovery-normal93-hosted-20261012.json).
