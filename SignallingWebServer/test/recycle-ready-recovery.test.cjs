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
    resolveInstanceAgentRecycleMarkerPath } = require('../dist/instance-agent-recycle-state.js');

function harness(t, phase = 'replacement_started', desiredToken) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-recycle-ready-'));
    const desiredStatePath = path.join(directory, 'desired.json');
    const markerPath = resolveInstanceAgentRecycleMarkerPath(desiredStatePath);
    const token = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const marker = writeInstanceAgentRecycleMarkerSnapshot(markerPath, {
        phase, requestedAtUtc: '2026-10-11T10:00:00.000Z',
        replacementStartedAtUtc: phase === 'replacement_started' ? '2026-10-11T10:00:01.000Z' : undefined,
        reason: 'post_session_cleanup', recycleId: 'recovered-operation', sourcePid: process.pid + 10000,
        recycleRequestedToken: token, sessionRequestId: 'original-request'
    }, () => {});
    const originals = { setTimeout, clearTimeout, setInterval, clearInterval, now: Date.now, spawn: childProcess.spawn };
    const h = { timers: [], updates: [], launches: [], recovery: true, now: 100000, readyCalls: 0 };
    global.setTimeout = (callback, delay) => {
        const timer = { callback, delay, cleared: false, unref() {} };
        h.timers.push(timer); return timer;
    };
    global.clearTimeout = timer => { if (timer) timer.cleared = true; };
    global.setInterval = () => ({ unref() {} });
    global.clearInterval = () => {};
    Date.now = () => h.now;
    childProcess.spawn = (...args) => { h.launches.push(args); return { on() {}, unref() {} }; };
    t.after(() => {
        Object.assign(global, { setTimeout: originals.setTimeout, clearTimeout: originals.clearTimeout,
            setInterval: originals.setInterval, clearInterval: originals.clearInterval });
        Date.now = originals.now; childProcess.spawn = originals.spawn;
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
    wireViewerIdleStop({ playerRegistry: { count: () => 0, get: () => undefined, has: () => false, on() {} } }, {
        enabled: true, graceMs: 0, resetGraceMs: 0, firstViewerGraceMs: 0,
        maintenanceRefreshMs: 0, maintenanceTagKey: '', desiredStateRefreshMs: 0,
        desiredStatePath, instanceAgentClient: h.agent, connectTicketRuntimeGate: gate,
        runtimeStatusPublisher: h.publisher, logger: () => {}
    });
    return Object.assign(h, { markerPath, marker, token });
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
});

test('a newer desired-state token cannot take over an already committed recovered intent', async t => {
    const h = harness(t, 'intent', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    h.recover();
    await new Promise(resolve => setImmediate(resolve));
    const marker = readInstanceAgentRecycleMarkerSnapshot(h.markerPath, () => {});
    assert.equal(h.launches.length, 1);
    assert.equal(marker.recycleRequestedToken, h.token);
    assert.equal(marker.sessionRequestId, 'original-request');
});
