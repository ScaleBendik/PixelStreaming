# Recovery launcher ownership

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
No waits or assertions were weakened. This permits a scoped Dev canary, not an
unqualified production-safety conclusion. Packaging and hosted acceptance remain
pending.

Hosted acceptance must demonstrate old-producer cancellation, exclusively
replacement-owned Unreal, unchanged cutoff/hold/reset acknowledgement,
sustained usable media, harmless scheduler retries, normal End Session and
verified stopped Dev targets. Timing changes are reported even if safety
increases startup time. Neither local process fixtures nor compilation prove
hosted lifecycle or media reliability. Stage/Prod promotion remains outside
this iteration.
