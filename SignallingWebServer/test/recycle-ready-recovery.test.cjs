// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');
const { createCommercialRuntimeStatusPublisher } = require('../dist/commercial-runtime-status.js');
const { wireViewerIdleStop } = require('../dist/viewer-idle-stop.js');
const { writeInstanceAgentRecycleMarkerSnapshot, readInstanceAgentRecycleMarkerSnapshot,
    clearInstanceAgentRecycleMarkerSnapshot,
    normalizeInstanceAgentRecycleMarkerSnapshot,
    readInstanceAgentRecycleSourceLaunchIdentity,
    resolveInstanceAgentRecycleMarkerPath } = require('../dist/instance-agent-recycle-state.js');

function harness(t, phase = 'replacement_started', desiredToken, recycleId = 'recovered-operation', schemaVersion = 2) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-recycle-ready-'));
    const desiredStatePath = path.join(directory, 'desired.json');
    const markerPath = resolveInstanceAgentRecycleMarkerPath(desiredStatePath);
    const originalEnvironment = { base: process.env.SCALEWORLD_INSTALL_BASE, generation: process.env.SCALEWORLD_STACK_LAUNCH_GENERATION };
    const generationId = '33333333-3333-4333-8333-333333333333';
    const sourceCreationUtc = '2026-10-12T10:00:00.1234560Z';
    process.env.SCALEWORLD_INSTALL_BASE = directory;
    process.env.SCALEWORLD_STACK_LAUNCH_GENERATION = generationId;
    const leasePath = path.join(directory, 'state', 'stack-launch-lease.json');
    const pin = { pid: process.pid, creationUtc: sourceCreationUtc, executablePath: process.execPath, name: 'node.exe' };
    const lease = { schemaVersion: 1, generationId, phase: 'starting', repoRoot: process.cwd(), activeNode: pin, completedNode: null };
    fs.mkdirSync(path.dirname(leasePath), { recursive: true });
    fs.writeFileSync(leasePath, JSON.stringify(lease));
    const token = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const marker = writeInstanceAgentRecycleMarkerSnapshot(markerPath, {
        phase, requestedAtUtc: '2026-10-11T10:00:00.000Z',
        replacementStartedAtUtc: phase === 'replacement_started' ? '2026-10-11T10:00:01.000Z' : undefined,
        reason: 'post_session_cleanup', recycleId, sourcePid: process.pid + 10000,
        recycleRequestedToken: token, sessionRequestId: 'original-request'
    }, () => {});
    // The current writer emits schema2. Seed an old on-disk schema1 marker
    // explicitly to exercise migration through the real runtime reader.
    if (schemaVersion === 1) {
        marker.schemaVersion = 1;
        fs.writeFileSync(markerPath, JSON.stringify(marker), 'utf8');
    }
    const originals = { setTimeout, clearTimeout, setInterval, clearInterval, now: Date.now, spawn: childProcess.spawn };
    const h = { timers: [], updates: [], launches: [], launchHandlers: [], recovery: true, now: 100000, readyCalls: 0 };
    global.setTimeout = (callback, delay) => {
        const timer = { callback, delay, cleared: false, unref() {} };
        h.timers.push(timer); return timer;
    };
    global.clearTimeout = timer => { if (timer) timer.cleared = true; };
    global.setInterval = () => ({ unref() {} });
    global.clearInterval = () => {};
    Date.now = () => h.now;
    childProcess.spawn = (...args) => {
        const handlers = {};
        h.launches.push(args); h.launchHandlers.push(handlers);
        return { on(event, callback) { handlers[event] = callback; }, unref() {} };
    };
    t.after(() => {
        Object.assign(global, { setTimeout: originals.setTimeout, clearTimeout: originals.clearTimeout,
            setInterval: originals.setInterval, clearInterval: originals.clearInterval });
        Date.now = originals.now; childProcess.spawn = originals.spawn;
        for (const [key, value] of [['SCALEWORLD_INSTALL_BASE', originalEnvironment.base], ['SCALEWORLD_STACK_LAUNCH_GENERATION', originalEnvironment.generation]]) {
            if (value === undefined) delete process.env[key]; else process.env[key] = value;
        }
        fs.rmSync(directory, { recursive: true, force: true });
    });
    const gate = {
        getReconnectGraceEvidenceJournalBlockReason: () => null,
        getCommercialRecoveryReadyNotBeforeEpochSeconds: () => 110,
        isCommercialRecoveryRequired: () => h.recovery,
        getRecycleTokenCompletionStatus: () => h.recovery ? 'open' : 'completed',
        getDurableManagedViewerEvidenceStatus: () => 'none', markTeardownStarted: () => true
    };
    h.agent = {
        recordRuntimeStatus(update) {
            if (update.status === 'ready') {
                h.readyCalls++;
                if (h.now > 110000) h.recovery = false;
            }
        },
        getDesiredState: () => ({ warmHoldEnabled: true, drainEnabled: false, shutdownRequested: false,
            recycleRequestedToken: phase === 'replacement_started' ? token : desiredToken, policyVersion: 'test' }),
        getActiveCommand: () => null,
        addDesiredStateListener() {}, addCommandListener() {},
        isReconnectGraceRecoveryRecyclePending: () => true,
        addReconnectGraceRecoveryListener(listener) { h.recover = listener; },
        captureSessionLogArtifact: async () => {}, captureSessionScreenshotArtifact: async () => {},
        setReconnectGraceWindow() {}, recordReconnectGraceElapsedEvidence: () => true, requestFastPolling() {}
    };
    h.publisher = createCommercialRuntimeStatusPublisher({ publish: async update => {
        h.updates.push(update); return true;
    } }, gate, h.agent);
    h.rewire = () => wireViewerIdleStop({ playerRegistry: { count: () => 0, get: () => undefined, has: () => false, on() {} } }, {
        enabled: true, graceMs: 0, resetGraceMs: 0, firstViewerGraceMs: 0,
        maintenanceRefreshMs: 0, maintenanceTagKey: '', desiredStateRefreshMs: 0,
        desiredStatePath, instanceAgentClient: h.agent, connectTicketRuntimeGate: gate,
        runtimeStatusPublisher: h.publisher, logger: () => {}
    });
    h.rewire();
    return Object.assign(h, { markerPath, marker, token, leasePath, lease, pin, generationId, sourceCreationUtc });
}

test('waiting for an existing replacement cannot cancel Ready recovery on repeated recovery notifications', async t => {
    const h = harness(t);
    await h.publisher.publish({ status: 'ready', source: 'signalling-server', reason: 'replacement_ready' });
    h.recover();
    for (let retry = 0; retry < 3; retry++) {
        const timer = h.timers.find(timer => timer.delay === 5000 && !timer.cleared);
        if (timer) { timer.cleared = true; timer.callback(); }
        h.recover();
        await new Promise(resolve => setImmediate(resolve));
    }
    const release = h.timers.find(timer => timer.delay === 11000 && !timer.cleared);
    assert.ok(release, 'original commercial Ready release survives retries');
    h.now = 111000; release.callback();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(h.recovery, false);
    assert.equal(h.updates.at(-1).status, 'ready');
    assert.equal(h.launches.length, 0);
});

test('real replacement regression cancels pending Ready and ignores stale Ready heartbeats', async t => {
    const h = harness(t);
    await h.publisher.publish({ status: 'ready', source: 'signalling-server' });
    await h.publisher.publish({ status: 'unhealthy', source: 'signalling-server' });
    h.now = 111000;
    await h.publisher.publish({ status: 'ready', source: 'signalling-server', heartbeatOnly: true });
    assert.equal(h.readyCalls, 1);
    assert.equal(h.recovery, true);
    assert.ok(h.timers.filter(timer => timer.delay === 11000).every(timer => timer.cleared));
});

test('relaunching a recovered intent preserves its operation, token and request provenance', async t => {
    const h = harness(t, 'intent');
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    const marker = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(h.launches.length, 1);
    assert.equal(marker.recycleId, h.marker.recycleId);
    assert.equal(marker.recycleRequestedToken, h.token);
    assert.equal(marker.sessionRequestId, 'original-request');
    assert.equal(marker.requestedAtUtc, h.marker.requestedAtUtc);
    assert.equal(marker.sourcePid, process.pid);
    const helperArguments = h.launches[0][1];
    assert.equal(helperArguments.filter(argument => argument === '-ExpectedRecycleIdBase64').length, 1);
    const encodedRecycleId = helperArguments[helperArguments.indexOf('-ExpectedRecycleIdBase64') + 1];
    assert.equal(Buffer.from(encodedRecycleId, 'base64').toString('utf8'), marker.recycleId);
    assert.equal(helperArguments[helperArguments.indexOf('-SourcePid') + 1], String(process.pid));
    assert.match(marker.helperLaunchId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    assert.equal(helperArguments[helperArguments.indexOf('-ExpectedHelperLaunchId') + 1], marker.helperLaunchId);
    assert.equal(marker.sourceLaunchGenerationId, h.generationId);
    assert.equal(marker.sourceCreationUtc, h.sourceCreationUtc);
    assert.equal(helperArguments[helperArguments.indexOf('-ExpectedLaunchGenerationId') + 1], h.generationId);
    assert.equal(helperArguments[helperArguments.indexOf('-ExpectedSourceCreationUtc') + 1], h.sourceCreationUtc);
});

test('recovering the same intent with the same source PID creates a fresh helper dispatch without rebinding provenance', async t => {
    const h = harness(t, 'intent');
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    const first = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    h.rewire();
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    const second = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(h.launches.length, 2);
    assert.notEqual(second.helperLaunchId, first.helperLaunchId);
    for (const field of ['sourcePid', 'recycleId', 'recycleRequestedToken', 'sessionRequestId', 'requestedAtUtc', 'reason']) {
        assert.equal(second[field], first[field], `${field} remains operation provenance`);
    }
    assert.equal(h.launches[1][1][h.launches[1][1].indexOf('-ExpectedHelperLaunchId') + 1], second.helperLaunchId);
    h.launchHandlers[0].error(new Error('delayed prior dispatch failure'));
    const retained = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(retained.helperLaunchId, second.helperLaunchId, 'late callback cannot erase the new same-operation dispatch');
    assert.equal(clearInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {}, second.recycleId, 'not-a-uuid'), false);
    assert.equal(clearInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {}, second.recycleId, first.helperLaunchId), false);
    assert.equal(clearInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {}, second.recycleId, second.helperLaunchId), true);
});

test('operation-only completion cleanup remains compatible with a dispatch-aware marker', async t => {
    const h = harness(t, 'intent');
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    const marker = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(clearInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {}, marker.recycleId), true);
    assert.equal(fs.existsSync(h.markerPath), false);
});

test('old recycle markers remain readable while present dispatch identities are normalized and validated', () => {
    const legacy = { schemaVersion: 1, phase: 'intent', requestedAtUtc: '2026-10-11T10:00:00.000Z',
        reason: 'cleanup', recycleId: 'original-operation', sourcePid: 1234 };
    assert.equal(normalizeInstanceAgentRecycleMarkerSnapshot(legacy).helperLaunchId, undefined);
    const helperLaunchId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    const dispatched = normalizeInstanceAgentRecycleMarkerSnapshot({ ...legacy, schemaVersion: 2, helperLaunchId });
    assert.equal(dispatched.helperLaunchId, helperLaunchId.toLowerCase());
    for (const invalid of ['', null, 1234, 'not-a-uuid', '00000000-0000-0000-0000-000000000000']) {
        assert.equal(normalizeInstanceAgentRecycleMarkerSnapshot({ ...legacy, schemaVersion: 2, helperLaunchId: invalid }), null);
    }
    const sourceLaunchGenerationId = '33333333-3333-4333-8333-333333333333';
    const sourceCreationUtc = '2026-10-12T10:00:00.1234560Z';
    const pinned = normalizeInstanceAgentRecycleMarkerSnapshot({ ...legacy, schemaVersion: 2, sourceLaunchGenerationId, sourceCreationUtc });
    assert.equal(pinned.sourceCreationUtc, sourceCreationUtc, 'exact CIM fraction digits cannot be truncated by JS Date');
    assert.equal(normalizeInstanceAgentRecycleMarkerSnapshot({ ...legacy, sourceLaunchGenerationId }), null);
    assert.equal(normalizeInstanceAgentRecycleMarkerSnapshot({ ...legacy, sourceCreationUtc }), null);
    assert.equal(normalizeInstanceAgentRecycleMarkerSnapshot({ ...legacy, sourceLaunchGenerationId, sourceCreationUtc: '2026-10-12T10:00:00.123Z' }), null);
});

test('source lease capture rejects missing, stale, malformed and ambiguous process pins without mutating state', async t => {
    const h = harness(t, 'intent');
    const originalMarker = fs.readFileSync(h.markerPath, 'utf8');
    const originalLease = JSON.stringify(h.lease);
    assert.deepEqual(readInstanceAgentRecycleSourceLaunchIdentity(), { sourceLaunchGenerationId: h.generationId, sourceCreationUtc: h.sourceCreationUtc });
    const cases = [
        { ...h.lease, generationId: '44444444-4444-4444-8444-444444444444' },
        { ...h.lease, phase: 'recycling' },
        { ...h.lease, schemaVersion: 2 },
        { ...h.lease, repoRoot: path.dirname(process.cwd()) },
        { ...h.lease, activeNode: null },
        { ...h.lease, activeNode: { ...h.pin, pid: process.pid + 1 } },
        { ...h.lease, activeNode: { ...h.pin, name: 'cmd.exe' } },
        { ...h.lease, activeNode: { ...h.pin, executablePath: h.markerPath } },
        { ...h.lease, activeNode: { ...h.pin, creationUtc: 'invalid' } },
        { ...h.lease, completedNode: { ...h.pin, creationUtc: '2026-10-12T10:00:00.1234570Z' } }
    ];
    for (const lease of cases) {
        const bytes = JSON.stringify(lease);
        fs.writeFileSync(h.leasePath, bytes);
        assert.equal(readInstanceAgentRecycleSourceLaunchIdentity(), null);
        assert.equal(fs.readFileSync(h.leasePath, 'utf8'), bytes, 'capture cannot mutate the lease');
    }
    for (const bytes of ['{broken', 'x'.repeat(32769), JSON.stringify([h.lease])]) {
        fs.writeFileSync(h.leasePath, bytes);
        assert.equal(readInstanceAgentRecycleSourceLaunchIdentity(), null);
    }
    fs.unlinkSync(h.leasePath);
    assert.equal(readInstanceAgentRecycleSourceLaunchIdentity(), null);
    fs.writeFileSync(h.leasePath, originalLease);
    delete process.env.SCALEWORLD_STACK_LAUNCH_GENERATION;
    assert.equal(readInstanceAgentRecycleSourceLaunchIdentity(), null);
    process.env.SCALEWORLD_STACK_LAUNCH_GENERATION = h.generationId;
    fs.writeFileSync(h.leasePath, JSON.stringify({ ...h.lease, phase: 'completed', activeNode: null, completedNode: h.pin }));
    assert.deepEqual(readInstanceAgentRecycleSourceLaunchIdentity(), { sourceLaunchGenerationId: h.generationId, sourceCreationUtc: h.sourceCreationUtc });
    assert.equal(fs.readFileSync(h.markerPath, 'utf8'), originalMarker, 'pin lookup cannot rewrite the existing intent');
});

test('an unavailable source pin leaves old intent untouched until the normal retry can capture the exact birth', async t => {
    const h = harness(t, 'intent');
    fs.writeFileSync(h.leasePath, JSON.stringify({ ...h.lease, activeNode: null }));
    const originalBytes = fs.readFileSync(h.markerPath, 'utf8');
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(h.launches.length, 0);
    assert.equal(fs.readFileSync(h.markerPath, 'utf8'), originalBytes);
    const retry = h.timers.find(timer => timer.delay === 5000 && !timer.cleared);
    assert.ok(retry, 'normal retry remains scheduled without helper failure escalation');
    fs.writeFileSync(h.leasePath, JSON.stringify(h.lease));
    retry.cleared = true; retry.callback();
    await new Promise(resolve => setImmediate(resolve));
    const marker = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(h.launches.length, 1);
    assert.equal(marker.sourceCreationUtc, h.sourceCreationUtc);
    assert.equal(marker.sourceLaunchGenerationId, h.generationId);
    assert.equal(marker.recycleId, h.marker.recycleId);
});

for (const schemaVersion of [1, 2]) {
    test(`old schema${schemaVersion} intent without nonce preserves opaque identity and provenance while creating safe helper dispatch`, async t => {
        const recycleId = 'operation & "quoted" | < > ^ %PATH% ! (\u03bb\u00f8)';
        const h = harness(t, 'intent', undefined, recycleId, schemaVersion);
        const original = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
        assert.equal(original.schemaVersion, schemaVersion);
        assert.equal(original.helperLaunchId, undefined);
        h.recover();
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(h.launches.length, 1);
        const helperArguments = h.launches[0][1];
        const encodedRecycleId = helperArguments[helperArguments.indexOf('-ExpectedRecycleIdBase64') + 1];
        assert.match(encodedRecycleId, /^[A-Za-z0-9+/]+={0,2}$/);
        assert.equal(Buffer.from(encodedRecycleId, 'base64').toString('utf8'), recycleId);
        assert.equal(helperArguments.includes(recycleId), false);
        const current = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
        assert.equal(current.schemaVersion, 2);
        assert.match(current.helperLaunchId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
        assert.equal(helperArguments[helperArguments.indexOf('-ExpectedHelperLaunchId') + 1], current.helperLaunchId);
        assert.equal(helperArguments[helperArguments.indexOf('-ExpectedLaunchGenerationId') + 1], h.generationId);
        assert.equal(helperArguments[helperArguments.indexOf('-ExpectedSourceCreationUtc') + 1], h.sourceCreationUtc);
        assert.match(h.sourceCreationUtc, /^[0-9TZ:.-]+$/);
        assert.equal(current.sourcePid, process.pid);
        for (const field of ['recycleId', 'recycleRequestedToken', 'sessionRequestId', 'requestedAtUtc', 'reason']) {
            assert.equal(current[field], original[field], `${field} survives schema migration`);
        }
    });
}

test('a newer desired-state token cannot take over an already committed recovered intent', async t => {
    const h = harness(t, 'intent', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    const marker = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(h.launches.length, 1);
    assert.equal(marker.recycleRequestedToken, h.token);
    assert.equal(marker.sessionRequestId, 'original-request');
});
