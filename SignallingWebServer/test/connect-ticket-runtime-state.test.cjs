// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const crypto = require('node:crypto');

const { createConnectTicketRuntimeGate } = require('../dist/connect-ticket-runtime-state.js');
const { createPlayerVerifyClient } = require('../dist/ConnectTicketAuth.js');
const {
    applyInstanceAgentControlResponse,
    canExecuteAcknowledgedInstanceCommand,
    normalizeInstanceAgentReconnectGraceWindowForReport,
    wireInstanceAgent
} = require('../dist/instance-agent.js');
const {
    isInstanceAgentCommandExpired,
    writeInstanceAgentCommandJournalSnapshot
} = require('../dist/instance-agent-command-state.js');
const {
    clearInstanceAgentRecycleMarkerSnapshot,
    isInstanceAgentRecycleReplacementProof,
    readInstanceAgentRecycleMarkerSnapshot,
    resolveInstanceAgentRecycleMarkerPath,
    writeInstanceAgentRecycleMarkerSnapshot
} = require('../dist/instance-agent-recycle-state.js');
const { resolveFirstViewerTimeoutStopReason, wireViewerIdleStop } = require('../dist/viewer-idle-stop.js');
const {
    appendInstanceAgentReconnectGraceElapsedEvidence,
    readInstanceAgentReconnectGraceElapsedEvidenceJournal
} = require('../dist/instance-agent-reconnect-grace-evidence-state.js');
const { createSessionLogArtifactManager } = require('../dist/session-log-artifacts.js');

function signConnectTicket(payload, signingKey) {
    const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const headerSegment = encode({ alg: 'HS256', typ: 'JWT' });
    const payloadSegment = encode(payload);
    const signingInput = `${headerSegment}.${payloadSegment}`;
    const signature = crypto.createHmac('sha256', signingKey).update(signingInput).digest('base64url');
    return `${signingInput}.${signature}`;
}

function createViewerIdleHarness(graceMs = 1_234) {
    const listeners = { added: [], removed: [] };
    const playerId = 'managed-player';
    const player = {
        scaleWorldSessionId: '11111111-1111-4111-8111-111111111111',
        scaleWorldSessionRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        scaleWorldSessionIdentityValidated: true,
        scaleWorldActiveSessionIdValidated: true,
        protocol: { disconnect() {} }
    };
    const players = new Map([[playerId, player]]);
    const scheduledTimeouts = [];
    const publishedWindows = [];
    const elapsedEvidences = [];
    const originalSetTimeout = global.setTimeout;
    global.setTimeout = (callback, delay) => {
        const timer = { callback, delay };
        scheduledTimeouts.push(timer);
        return timer;
    };

    const server = {
        playerRegistry: {
            count: () => players.size,
            get: (id) => players.get(id),
            has: (id) => players.has(id),
            on(event, listener) {
                listeners[event].push(listener);
            }
        }
    };
    const instanceAgentClient = {
        getDesiredState: () => ({
            warmHoldEnabled: true,
            drainEnabled: false,
            shutdownRequested: false,
            policyVersion: 'test'
        }),
        getActiveCommand: () => null,
        addDesiredStateListener() {},
        addCommandListener() {},
        isReconnectGraceRecoveryRecyclePending: () => false,
        addReconnectGraceRecoveryListener() {},
        acknowledgeCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
        startCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
        completeCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
        failCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
        captureSessionLogArtifact: async () => undefined,
        captureSessionScreenshotArtifact: async () => undefined,
        setReconnectGraceWindow(window) {
            publishedWindows.push(window ? { ...window } : null);
        },
        recordReconnectGraceElapsedEvidence(evidence) {
            elapsedEvidences.push({ ...evidence });
            return true;
        },
        requestFastPolling() {}
    };

    wireViewerIdleStop(server, {
        graceMs,
        resetGraceMs: 60_000,
        firstViewerGraceMs: 60_000,
        idleStatusHeartbeatMs: 0,
        maintenanceRefreshMs: 0,
        desiredStateRefreshMs: 0,
        instanceAgentClient,
        connectTicketRuntimeGate: {
            markTeardownStarted: () => true,
            getDurableManagedViewerEvidenceStatus: () => 'present'
        },
        logger: () => undefined
    });
    for (const listener of listeners.added) listener(playerId);

    return {
        playerId,
        player,
        players,
        listeners,
        scheduledTimeouts,
        publishedWindows,
        elapsedEvidences,
        restoreTimers() {
            global.setTimeout = originalSetTimeout;
        },
        removeViewer() {
            for (const listener of listeners.removed) listener(playerId);
            players.delete(playerId);
        },
        reconnectViewer() {
            players.set(playerId, player);
            for (const listener of listeners.added) listener(playerId);
        }
    };
}

test('live reconnect-grace report is accepted only for the matching zero-viewer lifecycle', () => {
    const window = {
        lastViewerDisconnectedAtUtc: '2026-08-29T18:37:47.000Z',
        reconnectGraceExpiresAtUtc: '2026-08-29T18:42:47.000Z'
    };

    assert.deepEqual(
        normalizeInstanceAgentReconnectGraceWindowForReport(window, 'reconnect_grace', 0),
        window
    );
    assert.deepEqual(
        normalizeInstanceAgentReconnectGraceWindowForReport(window, 'idle_shutdown_pending', 0),
        window
    );
    assert.equal(normalizeInstanceAgentReconnectGraceWindowForReport(window, 'ready', 0), null);
    assert.equal(normalizeInstanceAgentReconnectGraceWindowForReport(window, 'resetting', 0), null);
    assert.equal(normalizeInstanceAgentReconnectGraceWindowForReport(window, 'reconnect_grace', 1), null);
});

test('viewer reconnect cancels one immutable live reconnect-grace pair and publishes null', () => {
    const harness = createViewerIdleHarness();
    try {
        harness.removeViewer();
        const startedWindow = harness.publishedWindows.at(-1);
        assert.ok(startedWindow);
        assert.equal(
            Date.parse(startedWindow.reconnectGraceExpiresAtUtc) -
                Date.parse(startedWindow.lastViewerDisconnectedAtUtc),
            1_234
        );

        harness.reconnectViewer();

        assert.equal(harness.publishedWindows.at(-1), null);
        assert.deepEqual(harness.publishedWindows[0], startedWindow);
        assert.equal(harness.elapsedEvidences.length, 0);
    } finally {
        harness.restoreTimers();
    }
});

test('grace expiry records durable evidence and clears live telemetry before reset begins', () => {
    const harness = createViewerIdleHarness();
    const originalExistsSync = fs.existsSync;
    try {
        harness.removeViewer();
        const graceTimer = harness.scheduledTimeouts.find((timer) => timer.delay === 1_234);
        assert.ok(graceTimer);
        fs.existsSync = () => false;

        graceTimer.callback();

        assert.equal(harness.elapsedEvidences.length, 1);
        assert.equal(harness.publishedWindows.at(-1), null);
        assert.equal(
            harness.elapsedEvidences[0].reconnectGraceExpiresAtUtc,
            harness.publishedWindows[0].reconnectGraceExpiresAtUtc
        );
    } finally {
        fs.existsSync = originalExistsSync;
        harness.restoreTimers();
    }
});

test('durable elapsed evidence replays independently without recreating a live window', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-reconnect-grace-evidence-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const journalPath = path.join(stateDirectory, 'reconnect-grace-evidence.json');
    const evidence = {
        evidenceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        sessionRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        activeSessionId: '11111111-1111-4111-8111-111111111111',
        lastViewerDisconnectedAtUtc: '2026-08-29T18:37:47.000Z',
        reconnectGraceExpiresAtUtc: '2026-08-29T18:42:47.000Z',
        phase: 'elapsed'
    };

    assert.deepEqual(
        appendInstanceAgentReconnectGraceElapsedEvidence(journalPath, evidence, () => undefined),
        [evidence]
    );
    assert.deepEqual(
        readInstanceAgentReconnectGraceElapsedEvidenceJournal(journalPath, () => undefined),
        [evidence]
    );
    assert.equal(normalizeInstanceAgentReconnectGraceWindowForReport(null, 'ready', 0), null);
});

test('managed viewer evidence survives restart and rotates only after durable recovery', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-connect-ticket-gate-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));

    let nowEpochSeconds = 1_000;
    const gate = createConnectTicketRuntimeGate({
        statePath: path.join(stateDirectory, 'connect-ticket-runtime-state.json'),
        desiredStatePath: path.join(stateDirectory, 'instance-agent-desired-state.json'),
        commandJournalPath: path.join(stateDirectory, 'instance-agent-active-command.json'),
        admissionClockSkewSeconds: 5,
        nowEpochSeconds: () => nowEpochSeconds,
        logger: () => undefined
    });
    const requestA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const requestB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const activeSessionA = '11111111-1111-4111-8111-111111111111';
    const activeSessionB = '22222222-2222-4222-8222-222222222222';

    assert.equal(
        gate.rejectReasonForTicket({
            issuedAtEpochSeconds: 999,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestA
        }),
        null
    );
    assert.equal(
        gate.recordManagedViewerAdmission({
            sessionRequestId: requestA,
            activeSessionId: activeSessionA
        }),
        null
    );
    assert.equal(gate.getDurableManagedViewerEvidenceStatus(), 'present');

    // A Wilbur-only restart must recover request A's ownership and viewer-use evidence. The
    // evidence disqualifies an exact no-viewer classification, but carries no disconnect time.
    const recoveredGate = createConnectTicketRuntimeGate({
        statePath: path.join(stateDirectory, 'connect-ticket-runtime-state.json'),
        desiredStatePath: path.join(stateDirectory, 'instance-agent-desired-state.json'),
        commandJournalPath: path.join(stateDirectory, 'instance-agent-active-command.json'),
        admissionClockSkewSeconds: 5,
        nowEpochSeconds: () => nowEpochSeconds,
        logger: () => undefined
    });
    assert.equal(recoveredGate.getDurableManagedViewerEvidenceStatus(), 'present');
    assert.equal(
        recoveredGate.rejectReasonForTicket({
            issuedAtEpochSeconds: 999,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestA
        }),
        null
    );
    assert.match(
        recoveredGate.rejectReasonForTicket({
            issuedAtEpochSeconds: 999,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestB
        }) ?? '',
        /different managed session/i
    );

    assert.equal(
        recoveredGate.markTeardownStarted({
            occurredAtUtc: '1970-01-01T00:16:40.000Z',
            reason: 'test_teardown'
        }),
        true
    );
    nowEpochSeconds = 1_001;
    assert.equal(recoveredGate.prepareCommercialRecoveryAfterReset(), 1_011);
    assert.notEqual(
        recoveredGate.rejectReasonForTicket({
            issuedAtEpochSeconds: 1_012,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestB
        }),
        null
    );

    nowEpochSeconds = 1_011;
    assert.equal(recoveredGate.completeCommercialRecoveryAfterReset(), false);
    nowEpochSeconds = 1_012;
    assert.equal(recoveredGate.completeCommercialRecoveryAfterReset(), true);
    assert.equal(recoveredGate.getDurableManagedViewerEvidenceStatus(), 'none');

    assert.match(
        recoveredGate.rejectReasonForTicket({
            issuedAtEpochSeconds: 1_000,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestA
        }) ?? '',
        /before this session teardown began/i
    );
    assert.equal(
        recoveredGate.rejectReasonForTicket({
            issuedAtEpochSeconds: 1_012,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestB
        }),
        null
    );
    assert.equal(
        recoveredGate.recordManagedViewerAdmission({
            sessionRequestId: requestB,
            activeSessionId: activeSessionB
        }),
        null
    );
    assert.equal(recoveredGate.getDurableManagedViewerEvidenceStatus(), 'present');

    // A no-op completion when no recovery latch is set must not release request B.
    assert.equal(recoveredGate.completeCommercialRecoveryAfterReset(), true);
    assert.match(
        recoveredGate.rejectReasonForTicket({
            issuedAtEpochSeconds: 1_013,
            expiresAtEpochSeconds: 1_100,
            sessionRequestId: requestA
        }) ?? '',
        /different managed session/i
    );

    const durableState = JSON.parse(
        fs.readFileSync(path.join(stateDirectory, 'connect-ticket-runtime-state.json'), 'utf8')
    );
    assert.equal(durableState.rejectTicketsIssuedAtOrBeforeEpochSeconds, 1_006);
    assert.equal(durableState.commercialRecoveryRequired, undefined);
    assert.equal(durableState.commercialRecoveryReadyNotBeforeEpochSeconds, undefined);
    assert.equal(durableState.managedViewerSessionRequestId, requestB);
    assert.equal(durableState.managedViewerActiveSessionId, activeSessionB);
    assert.equal(typeof durableState.managedViewerFirstAdmittedAtUtc, 'string');
});

test('invalid durable managed-viewer evidence blocks startup', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-connect-ticket-gate-invalid-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const statePath = path.join(stateDirectory, 'connect-ticket-runtime-state.json');
    fs.writeFileSync(
        statePath,
        JSON.stringify({
            rejectTicketsIssuedAtOrBeforeEpochSeconds: 0,
            managedViewerSessionRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        })
    );

    assert.throws(
        () =>
            createConnectTicketRuntimeGate({
                statePath,
                desiredStatePath: path.join(stateDirectory, 'instance-agent-desired-state.json'),
                commandJournalPath: path.join(stateDirectory, 'instance-agent-active-command.json'),
                logger: () => undefined
            }),
        /invalid or unreadable/i
    );
});

test('managed WebSocket admission is rejected when viewer evidence is not durable', () => {
    const signingKey = 'test-signing-key-that-is-longer-than-thirty-two-bytes';
    const sessionRequestId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const activeSessionId = '11111111-1111-4111-8111-111111111111';
    const nowEpochSeconds = Math.floor(Date.now() / 1000);
    const ticket = signConnectTicket(
        {
            iss: 'test-issuer',
            aud: 'test-audience',
            exp: nowEpochSeconds + 60,
            iat: nowEpochSeconds,
            instanceId: 'i-test',
            routeKey: 'route-a',
            sessionRequestId,
            activeSessionId
        },
        signingKey
    );
    let recordedIdentity = null;
    const verifyClient = createPlayerVerifyClient({
        mode: 'enforce',
        issuer: 'test-issuer',
        audience: 'test-audience',
        signingKey,
        instanceId: 'i-test',
        routeHostSuffix: 'stream.test.example',
        clockSkewSeconds: 0,
        runtimeGate: {
            getReconnectGraceEvidenceJournalBlockReason: () => null,
            rejectReasonForTicket: () => null,
            recordManagedViewerAdmission: (identity) => {
                recordedIdentity = identity;
                return 'Durable viewer evidence write failed.';
            }
        }
    });
    const request = {
        headers: { host: 'route-a.stream.test.example' },
        url: `/?ct=${ticket}`
    };
    let result = null;

    verifyClient({ req: request }, (accepted, statusCode, message) => {
        result = { accepted, statusCode, message };
    });

    assert.deepEqual(recordedIdentity, { sessionRequestId, activeSessionId });
    assert.deepEqual(result, {
        accepted: false,
        statusCode: 503,
        message: 'Durable viewer evidence write failed.'
    });
    assert.equal(request.scaleWorldConnectTicketIdentityValidated, false);
    assert.equal(request.scaleWorldValidatedConnectTicketIdentity, undefined);
});

test('pre-launch recycle intent is not replacement proof after a process restart', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-recycle-marker-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const markerPath = path.join(stateDirectory, 'instance-agent-recycle-marker.json');
    const intent = writeInstanceAgentRecycleMarkerSnapshot(
        markerPath,
        {
            phase: 'intent',
            requestedAtUtc: '2026-08-21T10:00:00.000Z',
            reason: 'test_recycle',
            recycleId: 'recycle-a',
            sourcePid: 1234
        },
        () => undefined
    );

    assert.equal(isInstanceAgentRecycleReplacementProof(intent, 5678), false);
    const replacement = writeInstanceAgentRecycleMarkerSnapshot(
        markerPath,
        {
            ...intent,
            phase: 'replacement_started',
            replacementStartedAtUtc: '2026-08-21T10:00:01.000Z'
        },
        () => undefined
    );
    assert.equal(isInstanceAgentRecycleReplacementProof(replacement, 1234), false);
    assert.equal(isInstanceAgentRecycleReplacementProof(replacement, 5678), true);
    assert.equal(
        isInstanceAgentRecycleReplacementProof(
            readInstanceAgentRecycleMarkerSnapshot(markerPath, () => undefined),
            5678
        ),
        true
    );
});

test('tokenless passive recycle marker never adopts an unchanged newer desired recycle token', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-tokenless-marker-new-token-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const desiredStatePath = path.join(stateDirectory, 'instance-agent-desired-state.json');
    const markerPath = path.join(stateDirectory, 'instance-agent-recycle-marker.json');
    const desiredRecycleToken = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const desiredState = {
        warmHoldEnabled: true,
        drainEnabled: false,
        shutdownRequested: false,
        recycleRequestedToken: desiredRecycleToken,
        policyVersion: 'token-b',
        updatedAtUtc: '2026-08-30T01:00:02.000Z'
    };
    const marker = writeInstanceAgentRecycleMarkerSnapshot(
        markerPath,
        {
            phase: 'replacement_started',
            requestedAtUtc: '2026-08-30T01:00:00.000Z',
            replacementStartedAtUtc: '2026-08-30T01:00:01.000Z',
            reason: 'passive_post_session_cleanup',
            recycleId: 'passive-recycle-a',
            sourcePid: process.pid + 10_000
        },
        () => undefined
    );
    assert.equal(marker.recycleRequestedToken, undefined);
    assert.equal(isInstanceAgentRecycleReplacementProof(marker), true);

    const listeners = { added: [], removed: [] };
    const scheduledTimeouts = [];
    const recycleTokenChecks = [];
    const teardownStarts = [];
    let desiredStateListener = null;
    const originalSetTimeout = global.setTimeout;
    global.setTimeout = (callback, delay) => {
        const timer = { callback, delay };
        scheduledTimeouts.push(timer);
        return timer;
    };

    try {
        wireViewerIdleStop(
            {
                playerRegistry: {
                    count: () => 0,
                    get: () => undefined,
                    has: () => false,
                    on(event, listener) {
                        listeners[event].push(listener);
                    }
                }
            },
            {
                firstViewerGraceMs: 0,
                resetGraceMs: 0,
                idleStatusHeartbeatMs: 0,
                maintenanceRefreshMs: 0,
                desiredStateRefreshMs: 0,
                desiredStatePath,
                instanceAgentClient: {
                    getDesiredState: () => desiredState,
                    getActiveCommand: () => null,
                    addDesiredStateListener(listener) {
                        desiredStateListener = listener;
                    },
                    addCommandListener() {},
                    isReconnectGraceRecoveryRecyclePending: () => false,
                    addReconnectGraceRecoveryListener() {},
                    acknowledgeCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
                    startCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
                    completeCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
                    failCommand: async () => ({ accepted: false, commandStatus: 'missing' }),
                    captureSessionLogArtifact: async () => undefined,
                    captureSessionScreenshotArtifact: async () => undefined,
                    setReconnectGraceWindow() {},
                    recordReconnectGraceElapsedEvidence: () => true,
                    requestFastPolling() {}
                },
                connectTicketRuntimeGate: {
                    markTeardownStarted(options) {
                        teardownStarts.push(options);
                        return false;
                    },
                    getDurableManagedViewerEvidenceStatus: () => 'none',
                    getRecycleTokenCompletionStatus(token) {
                        recycleTokenChecks.push(token);
                        return 'open';
                    }
                },
                logger: () => undefined
            }
        );

        assert.equal(typeof desiredStateListener, 'function');
        desiredStateListener(desiredState, { source: 'unchanged-token-b' });
        assert.equal(teardownStarts.length, 0);
        assert.equal(scheduledTimeouts.length, 0);

        assert.equal(
            clearInstanceAgentRecycleMarkerSnapshot(markerPath, () => undefined, marker.recycleId),
            true
        );
        desiredStateListener(desiredState, { source: 'unchanged-token-b-after-marker-cleanup' });

        assert.equal(teardownStarts.length, 1);
        assert.equal(teardownStarts[0].reason, 'stack_recycle_launch');
        assert.equal(scheduledTimeouts.length, 1);
        assert.ok(recycleTokenChecks.filter((token) => token === desiredRecycleToken).length >= 2);
    } finally {
        global.setTimeout = originalSetTimeout;
    }
});

test('tokenful reset completion retries marker durability and survives acceptance until Ready reconciliation', async (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-reset-completion-reconcile-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const desiredStatePath = path.join(stateDirectory, 'instance-agent-desired-state.json');
    const markerPath = resolveInstanceAgentRecycleMarkerPath(desiredStatePath);
    const recycleToken = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const desiredWithRecycle = {
        warmHoldEnabled: true,
        drainEnabled: false,
        shutdownRequested: false,
        recycleRequestedToken: recycleToken,
        policyVersion: 'resetting-token'
    };
    const desiredAfterReady = {
        warmHoldEnabled: true,
        drainEnabled: false,
        shutdownRequested: false,
        policyVersion: 'ready-token-cleared'
    };
    fs.writeFileSync(desiredStatePath, JSON.stringify(desiredWithRecycle));
    writeInstanceAgentRecycleMarkerSnapshot(
        markerPath,
        {
            phase: 'replacement_started',
            requestedAtUtc: '2026-08-30T01:10:00.000Z',
            replacementStartedAtUtc: '2026-08-30T01:10:01.000Z',
            reason: 'post_session_cleanup',
            recycleId: 'recycle-ready-heartbeat',
            sourcePid: process.pid + 10_000,
            recycleRequestedToken: recycleToken
        },
        () => undefined
    );

    const originalFetch = global.fetch;
    const originalSetTimeout = global.setTimeout;
    const originalSetInterval = global.setInterval;
    const originalClearInterval = global.clearInterval;
    const originalRenameSync = fs.renameSync;
    const eventUploads = [];
    const requestPaths = [];
    let commercialRecoveryRequired = true;
    let commercialRecoveryCompletionCalls = 0;
    let failFirstCompletionMarkerRewrite = true;
    global.setTimeout = (callback, delay) => ({ callback, delay });
    global.setInterval = (callback, delay) => ({ callback, delay });
    global.clearInterval = () => undefined;
    fs.renameSync = (sourcePath, destinationPath) => {
        if (failFirstCompletionMarkerRewrite && path.resolve(destinationPath) === path.resolve(markerPath)) {
            const candidate = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
            if (candidate.resetCompletedAtUtc) {
                failFirstCompletionMarkerRewrite = false;
                const error = new Error('Simulated transient completion-marker rename failure.');
                error.code = 'EIO';
                throw error;
            }
        }
        return originalRenameSync(sourcePath, destinationPath);
    };
    global.fetch = async (url, init = {}) => {
        const requestPath = new URL(url).pathname;
        if (requestPath.startsWith('/agent/')) {
            requestPaths.push(requestPath);
        }
        if (requestPath === '/agent/bootstrap') {
            return new Response(
                JSON.stringify({
                    agentToken: 'test-agent-token',
                    tokenExpiresAtUtc: '2026-08-30T02:10:00.000Z',
                    heartbeatIntervalSeconds: 3600,
                    commands: [],
                    desiredState: desiredWithRecycle
                }),
                { status: 200, headers: { 'Content-Type': 'application/json' } }
            );
        }

        if (requestPath === '/agent/events/batch') {
            const body = JSON.parse(init.body);
            const resetCompletion = body.events.find((event) => event.eventType === 'reset_completed');
            assert.ok(resetCompletion);
            assert.equal(fs.existsSync(markerPath), true);
            eventUploads.push(resetCompletion);
            const desiredState = eventUploads.length === 1 ? desiredWithRecycle : desiredAfterReady;
            return new Response(
                JSON.stringify({
                    acceptedCount: body.events.length,
                    commands: [],
                    desiredState
                }),
                { status: 200, headers: { 'Content-Type': 'application/json' } }
            );
        }

        if (requestPath === '/agent/heartbeat') {
            const body = JSON.parse(init.body);
            assert.equal(body.currentRuntimeStatus, 'ready');
            assert.equal(body.runtimeReady, true);
            assert.equal(fs.existsSync(markerPath), true);
            return new Response(
                JSON.stringify({
                    tokenExpiresAtUtc: '2026-08-30T02:10:00.000Z',
                    heartbeatIntervalSeconds: 3600,
                    commands: [],
                    desiredState: desiredAfterReady
                }),
                { status: 200, headers: { 'Content-Type': 'application/json' } }
            );
        }

        throw new Error(`Unexpected instance-agent request: ${requestPath}`);
    };

    try {
        const client = wireInstanceAgent(
            {
                playerRegistry: {
                    count: () => 0,
                    get: () => undefined,
                    has: () => false,
                    on() {}
                }
            },
            {
                enabled: true,
                apiBaseUrl: 'https://instance-agent.test',
                instanceId: 'i-reset-completion-test',
                region: 'eu-north-1',
                heartbeatMs: 3_600_000,
                desiredStatePath,
                connectTicketRuntimeGate: {
                    getReconnectGraceEvidenceJournalBlockReason: () => null,
                    setReconnectGraceEvidenceJournalBlock() {},
                    markTeardownStarted: () => true,
                    isCommercialRecoveryRequired: () => commercialRecoveryRequired,
                    prepareCommercialRecoveryAfterReset: () => 0,
                    completeCommercialRecoveryAfterReset(token) {
                        assert.equal(token, recycleToken);
                        commercialRecoveryCompletionCalls += 1;
                        commercialRecoveryRequired = false;
                        return true;
                    },
                    getRecycleTokenCompletionStatus: () => 'completed',
                    getCommercialRecoveryReadyNotBeforeEpochSeconds: () => null
                },
                logger: () => undefined
            }
        );
        assert.ok(client);
        client.recordRuntimeStatus({
            status: 'ready',
            reason: 'replacement_runtime_ready',
            source: 'test',
            version: 'test-runtime'
        });
        assert.equal(commercialRecoveryRequired, false);
        assert.equal(commercialRecoveryCompletionCalls, 1);
        assert.equal(failFirstCompletionMarkerRewrite, false);
        assert.equal(
            readInstanceAgentRecycleMarkerSnapshot(markerPath, () => undefined).resetCompletedAtUtc,
            undefined
        );

        client.recordRuntimeStatus({
            status: 'ready',
            reason: 'replacement_runtime_ready',
            source: 'test',
            version: 'test-runtime',
            heartbeatOnly: true
        });
        const retriedCompletionMarker = readInstanceAgentRecycleMarkerSnapshot(markerPath, () => undefined);
        assert.ok(retriedCompletionMarker.resetCompletedAtUtc);
        assert.equal(commercialRecoveryCompletionCalls, 1);

        for (let attempt = 0; attempt < 100 && fs.existsSync(markerPath); attempt += 1) {
            await new Promise((resolve) => setImmediate(resolve));
        }

        assert.deepEqual(requestPaths, [
            '/agent/bootstrap',
            '/agent/events/batch',
            '/agent/heartbeat',
            '/agent/events/batch'
        ]);
        assert.equal(eventUploads.length, 2);
        assert.equal(eventUploads[0].metadata.recycleRequestedToken, recycleToken);
        assert.equal(eventUploads[1].metadata.recycleRequestedToken, recycleToken);
        assert.equal(eventUploads[1].occurredAtUtc, eventUploads[0].occurredAtUtc);
        assert.equal(eventUploads[0].occurredAtUtc, retriedCompletionMarker.resetCompletedAtUtc);
        assert.equal(commercialRecoveryCompletionCalls, 1);
        assert.equal(fs.existsSync(markerPath), false);
    } finally {
        global.fetch = originalFetch;
        global.setTimeout = originalSetTimeout;
        global.setInterval = originalSetInterval;
        global.clearInterval = originalClearInterval;
        fs.renameSync = originalRenameSync;
    }
});

test('completed recycle token survives marker cleanup and process restart while a new token remains open', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-completed-recycle-token-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const desiredStatePath = path.join(stateDirectory, 'instance-agent-desired-state.json');
    const runtimeStatePath = path.join(stateDirectory, 'connect-ticket-runtime-state.json');
    const commandPath = path.join(stateDirectory, 'instance-agent-active-command.json');
    const markerPath = path.join(stateDirectory, 'instance-agent-recycle-marker.json');
    const completedToken = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const newToken = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    let now = 1_000;
    const gateOptions = {
        statePath: runtimeStatePath,
        desiredStatePath,
        commandJournalPath: commandPath,
        nowEpochSeconds: () => now,
        logger: () => undefined
    };
    const gate = createConnectTicketRuntimeGate(gateOptions);
    assert.equal(gate.markTeardownStarted({ occurredAtUtc: new Date(now * 1_000).toISOString() }), true);
    const readyNotBefore = gate.prepareCommercialRecoveryAfterReset();
    assert.ok(Number.isInteger(readyNotBefore));
    now = readyNotBefore + 1;
    assert.equal(gate.completeCommercialRecoveryAfterReset(completedToken), true);
    assert.equal(gate.getRecycleTokenCompletionStatus(completedToken), 'completed');
    assert.equal(gate.getRecycleTokenCompletionStatus(completedToken.replaceAll('-', '')), 'completed');
    assert.equal(gate.getRecycleTokenCompletionStatus(newToken), 'open');

    const marker = writeInstanceAgentRecycleMarkerSnapshot(
        markerPath,
        {
            phase: 'replacement_started',
            requestedAtUtc: '2026-08-29T23:53:23.818Z',
            replacementStartedAtUtc: '2026-08-29T23:53:26.638Z',
            resetCompletedAtUtc: '2026-08-29T23:54:18.008Z',
            reason: 'post_session_cleanup',
            recycleId: 'recycle-completed',
            sourcePid: 1234,
            recycleRequestedToken: completedToken
        },
        () => undefined
    );
    assert.equal(marker.schemaVersion, 2);
    assert.equal(marker.resetCompletedAtUtc, '2026-08-29T23:54:18.008Z');
    assert.equal(
        clearInstanceAgentRecycleMarkerSnapshot(markerPath, () => undefined, 'wrong-recycle'),
        false
    );
    assert.equal(fs.existsSync(markerPath), true);
    assert.equal(
        clearInstanceAgentRecycleMarkerSnapshot(markerPath, () => undefined, marker.recycleId),
        true
    );

    fs.writeFileSync(
        desiredStatePath,
        JSON.stringify({
            warmHoldEnabled: true,
            drainEnabled: false,
            shutdownRequested: false,
            recycleRequestedToken: completedToken.replaceAll('-', ''),
            policyVersion: 'completed-token-restart'
        })
    );
    const restartedGate = createConnectTicketRuntimeGate(gateOptions);
    assert.equal(restartedGate.isCommercialRecoveryRequired(), false);
    assert.equal(restartedGate.getRecycleTokenCompletionStatus(completedToken), 'completed');
    assert.equal(
        restartedGate.rejectReasonForTicket({
            issuedAtEpochSeconds: now + 1,
            expiresAtEpochSeconds: now + 100
        }),
        null
    );

    fs.writeFileSync(
        desiredStatePath,
        JSON.stringify({
            warmHoldEnabled: true,
            drainEnabled: false,
            shutdownRequested: false,
            recycleRequestedToken: newToken.replaceAll('-', ''),
            policyVersion: 'new-token-restart'
        })
    );
    const newTokenGate = createConnectTicketRuntimeGate(gateOptions);
    assert.equal(newTokenGate.getRecycleTokenCompletionStatus(newToken), 'open');
    assert.equal(newTokenGate.isCommercialRecoveryRequired(), true);
});

test('incomplete recycle token stays retryable and transient fence reads recover without restart', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-recycle-token-retry-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const desiredStatePath = path.join(stateDirectory, 'instance-agent-desired-state.json');
    const runtimeStatePath = path.join(stateDirectory, 'connect-ticket-runtime-state.json');
    const token = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    let now = 2_000;
    const gate = createConnectTicketRuntimeGate({
        statePath: runtimeStatePath,
        desiredStatePath,
        commandJournalPath: path.join(stateDirectory, 'instance-agent-active-command.json'),
        nowEpochSeconds: () => now,
        logger: () => undefined
    });
    assert.equal(gate.markTeardownStarted({ occurredAtUtc: new Date(now * 1_000).toISOString() }), true);
    const readyNotBefore = gate.prepareCommercialRecoveryAfterReset();
    assert.ok(Number.isInteger(readyNotBefore));
    now = readyNotBefore;
    assert.equal(gate.completeCommercialRecoveryAfterReset(token), false);
    assert.equal(gate.getRecycleTokenCompletionStatus(token), 'open');
    now += 1;
    assert.equal(gate.completeCommercialRecoveryAfterReset(token), true);
    assert.equal(gate.getRecycleTokenCompletionStatus(token), 'completed');

    fs.writeFileSync(
        desiredStatePath,
        JSON.stringify({
            warmHoldEnabled: true,
            drainEnabled: false,
            shutdownRequested: false,
            recycleRequestedToken: token.replaceAll('-', ''),
            policyVersion: 'transient-fence-read'
        })
    );
    const durableState = fs.readFileSync(runtimeStatePath, 'utf8');
    fs.writeFileSync(runtimeStatePath, '{invalid');
    assert.equal(gate.getRecycleTokenCompletionStatus(token), 'unavailable');
    assert.match(
        gate.rejectReasonForTicket({
            issuedAtEpochSeconds: now + 1,
            expiresAtEpochSeconds: now + 100
        }) ?? '',
        /fence|invalid|unreadable/i
    );
    fs.writeFileSync(runtimeStatePath, durableState);
    assert.equal(gate.getRecycleTokenCompletionStatus(token), 'completed');
    assert.equal(
        gate.rejectReasonForTicket({
            issuedAtEpochSeconds: now + 1,
            expiresAtEpochSeconds: now + 100
        }),
        null
    );
});

test('recovered viewer-use evidence can only disqualify exact no-viewer classification', () => {
    assert.equal(resolveFirstViewerTimeoutStopReason('none'), 'no-viewer-ever-connected');
    assert.equal(resolveFirstViewerTimeoutStopReason('present'), 'managed-viewer-history-continuity-lost');
    assert.equal(resolveFirstViewerTimeoutStopReason('unavailable'), 'managed-viewer-evidence-unavailable');
});

test('instance commands fail closed when their timeout is invalid or elapsed', () => {
    const nowEpochMs = Date.parse('2026-08-24T20:00:00.000Z');
    assert.equal(isInstanceAgentCommandExpired({}, nowEpochMs), false);
    assert.equal(
        isInstanceAgentCommandExpired({ timeoutAtUtc: '2026-08-24T20:00:01.000Z' }, nowEpochMs),
        false
    );
    assert.equal(
        isInstanceAgentCommandExpired({ timeoutAtUtc: '2026-08-24T20:00:00.000Z' }, nowEpochMs),
        true
    );
    assert.equal(isInstanceAgentCommandExpired({ timeoutAtUtc: 'invalid' }, nowEpochMs), true);
});

test('only accepted or already-open command acknowledgements authorize execution', () => {
    const transition = (accepted, commandStatus) => ({
        accepted,
        commandStatus,
        recordedAtUtc: '2026-08-24T20:00:00.000Z'
    });
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(true, 'Acked')), true);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(false, 'Acked')), true);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(false, 'Running')), true);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(true, 'Pending')), false);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(true, 'Completed')), false);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(false, 'Pending')), false);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(false, 'Completed')), false);
    assert.equal(canExecuteAcknowledgedInstanceCommand(transition(false, 'TimedOut')), false);
});

test('expired recovered teardown command does not recreate the commercial recovery latch', (context) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-expired-command-gate-'));
    context.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const commandJournalPath = path.join(stateDirectory, 'instance-agent-active-command.json');
    writeInstanceAgentCommandJournalSnapshot(
        commandJournalPath,
        {
            instanceCommandId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            instanceId: 'i-expired',
            region: 'eu-north-1',
            sessionRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            commandType: 'Shutdown',
            idempotencyKey: 'shutdown:expired',
            requestedAtUtc: '2020-01-01T00:00:00.000Z',
            timeoutAtUtc: '2020-01-01T00:05:00.000Z',
            status: 'acked',
            attemptNumber: 1,
            ackedAtUtc: '2020-01-01T00:00:01.000Z'
        },
        () => undefined
    );

    const gate = createConnectTicketRuntimeGate({
        statePath: path.join(stateDirectory, 'connect-ticket-runtime-state.json'),
        desiredStatePath: path.join(stateDirectory, 'instance-agent-desired-state.json'),
        commandJournalPath,
        logger: () => undefined
    });

    assert.equal(gate.isCommercialRecoveryRequired(), false);
});

for (const responseSource of ['bootstrap', 'heartbeat']) {
    test(`${responseSource} installs current desired state before recovered evidence acknowledgement`, () => {
        const evidence = {
            evidenceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            sessionRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            instanceId: 'i-recovery',
            region: 'eu-north-1',
            lastViewerDisconnectedAtUtc: '2026-08-24T10:30:00.000Z',
            reconnectGraceExpiresAtUtc: '2026-08-24T10:35:00.000Z',
            observedAtUtc: '2026-08-24T10:35:01.000Z'
        };
        const response = {
            commands: [],
            desiredState: {
                warmHoldEnabled: true,
                drainEnabled: false,
                shutdownRequested: false
            },
            acknowledgedReconnectGraceElapsedEvidenceId: evidence.evidenceId
        };
        const callOrder = [];
        let currentDesiredState = { shutdownRequested: true };
        let recoveryAction = null;

        applyInstanceAgentControlResponse(response, responseSource, evidence, {
            applyCommands(_commands, source) {
                callOrder.push(`commands:${source}`);
            },
            applyDesiredState(desiredState, source) {
                callOrder.push(`desired:${source}`);
                currentDesiredState = desiredState;
            },
            handleReconnectGraceElapsedEvidenceResponse(submittedEvidence, acknowledgedEvidenceId) {
                callOrder.push(`ack:${responseSource}`);
                assert.equal(submittedEvidence, evidence);
                assert.equal(acknowledgedEvidenceId, evidence.evidenceId);
                recoveryAction = currentDesiredState.shutdownRequested ? 'stop' : 'reset';
            }
        });

        assert.deepEqual(callOrder, [
            `commands:${responseSource}`,
            `desired:${responseSource}`,
            `ack:${responseSource}`
        ]);
        assert.equal(recoveryAction, 'reset');
    });
}

test('recovered evidence acknowledgement retains authoritative shutdown intent', () => {
    let currentDesiredState = { shutdownRequested: false };
    let recoveryAction = null;

    applyInstanceAgentControlResponse(
        {
            commands: [],
            desiredState: { shutdownRequested: true },
            acknowledgedReconnectGraceElapsedEvidenceId: 'evidence-shutdown'
        },
        'heartbeat',
        {
            evidenceId: 'evidence-shutdown',
            sessionRequestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            instanceId: 'i-recovery',
            region: 'eu-north-1',
            lastViewerDisconnectedAtUtc: '2026-08-24T10:30:00.000Z',
            reconnectGraceExpiresAtUtc: '2026-08-24T10:35:00.000Z',
            observedAtUtc: '2026-08-24T10:35:01.000Z'
        },
        {
            applyCommands() {},
            applyDesiredState(desiredState) {
                currentDesiredState = desiredState;
            },
            handleReconnectGraceElapsedEvidenceResponse() {
                recoveryAction = currentDesiredState.shutdownRequested ? 'stop' : 'reset';
            }
        }
    );

    assert.equal(recoveryAction, 'stop');
});

function normalizeLifecycleLogPath(filePath) {
    const resolved = path.resolve(filePath);
    return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
}

function captureLifecycleLogFingerprint(filePath, kind = 'wilbur_log') {
    const stat = fs.statSync(filePath);
    return {
        kind,
        normalizedPath: normalizeLifecycleLogPath(filePath),
        sizeBytes: stat.size,
        modifiedAtUtc: stat.mtime.toISOString(),
        fileIdentity: `${stat.dev}:${stat.ino}:${stat.birthtimeMs}`
    };
}

function createLifecycleLogArtifactHarness(context, overrides = {}) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'scaleworld-log-retention-'));
    const queuePath = path.join(root, 'queue');
    const logFolder = path.join(root, 'logs');
    fs.mkdirSync(logFolder, { recursive: true });
    context.after(() => fs.rmSync(root, { recursive: true, force: true }));

    const manager = createSessionLogArtifactManager({
        enabled: true,
        bucketName: 'test-artifact-bucket',
        objectPrefix: 'test-artifacts',
        queuePath,
        logFolder,
        includeWilburLogs: true,
        includeWatchdogLogs: false,
        includeUnrealLogs: false,
        includeStackRecycleLog: false,
        includeRuntimeStatusSnapshot: false,
        cleanupSessionLogsAfterUpload: true,
        cleanupLifecycleLogsOnStartup: true,
        awsCliExecutor: async (_executable, args) => ({
            stdout: args[0] === 's3api' ? '{}' : '',
            stderr: ''
        }),
        registerArtifact: async () => undefined,
        logger: () => undefined,
        ...overrides
    });
    assert.ok(manager);

    return { root, queuePath, logFolder, manager };
}

function enqueueLifecycleLogArtifact(queuePath, logPath, capturedLogFiles) {
    const id = crypto.randomUUID();
    const createdAtUtc = new Date().toISOString();
    const bundlePath = path.join(queuePath, 'bundles', `${id}.diagnostic-bundle.tar.gz`);
    fs.mkdirSync(path.dirname(bundlePath), { recursive: true });
    fs.writeFileSync(bundlePath, 'test bundle');
    const record = {
        id,
        status: 'pending_upload',
        createdAtUtc,
        updatedAtUtc: createdAtUtc,
        attempts: 0,
        localPath: bundlePath,
        bucketName: 'test-artifact-bucket',
        objectKey: `test/${id}.diagnostic-bundle.tar.gz`,
        request: {
            instanceId: 'i-log-test',
            region: 'eu-north-1',
            artifactType: 'diagnostic_bundle',
            bucketName: 'test-artifact-bucket',
            objectKey: `test/${id}.diagnostic-bundle.tar.gz`,
            metadata: { logPath: path.basename(logPath) }
        }
    };
    if (capturedLogFiles !== undefined) {
        record.capturedLogFiles = capturedLogFiles;
    }
    fs.writeFileSync(path.join(queuePath, `${id}.json`), JSON.stringify(record));
}

test('startup cleanup preserves active lifecycle logs', (context) => {
    const { logFolder, manager, root } = createLifecycleLogArtifactHarness(context, {
        watchdogLogPath: path.join(os.tmpdir(), `scaleworld-watchdog-${crypto.randomUUID()}.log`)
    });
    const serverLog = path.join(logFolder, 'server-2026-08-30.log');
    const auditLog = path.join(logFolder, '.audit.json');
    const watchdogLog = path.join(root, 'scaleworld-watchdog.log');
    fs.writeFileSync(serverLog, 'server-active');
    fs.writeFileSync(auditLog, 'audit-active');
    fs.writeFileSync(watchdogLog, 'watchdog-active');

    manager.cleanStartupLogs();

    assert.equal(fs.readFileSync(serverLog, 'utf8'), 'server-active');
    assert.equal(fs.readFileSync(auditLog, 'utf8'), 'audit-active');
    assert.equal(fs.readFileSync(watchdogLog, 'utf8'), 'watchdog-active');
});

test('successful upload prunes an exact unchanged captured lifecycle log', async (context) => {
    const { logFolder, queuePath, manager } = createLifecycleLogArtifactHarness(context);
    const logPath = path.join(logFolder, 'server-2026-08-30.log');
    fs.writeFileSync(logPath, 'captured generation A');
    enqueueLifecycleLogArtifact(queuePath, logPath, [captureLifecycleLogFingerprint(logPath)]);

    await manager.drainQueue();

    assert.equal(fs.statSync(logPath).size, 0);
});

test('successful upload skips a captured lifecycle log that was appended after capture', async (context) => {
    const { logFolder, queuePath, manager } = createLifecycleLogArtifactHarness(context);
    const logPath = path.join(logFolder, 'server-2026-08-30.log');
    fs.writeFileSync(logPath, 'captured generation A');
    const fingerprint = captureLifecycleLogFingerprint(logPath);
    enqueueLifecycleLogArtifact(queuePath, logPath, [fingerprint]);
    fs.appendFileSync(logPath, '\nreplacement activity');

    await manager.drainQueue();

    assert.match(fs.readFileSync(logPath, 'utf8'), /replacement activity/);
});

test('generation A upload cannot prune a replacement generation B file at the same path', async (context) => {
    const { logFolder, queuePath, manager, root } = createLifecycleLogArtifactHarness(context);
    const logPath = path.join(logFolder, 'server-2026-08-30.log');
    fs.writeFileSync(logPath, 'generation-A');
    const fingerprint = captureLifecycleLogFingerprint(logPath);
    enqueueLifecycleLogArtifact(queuePath, logPath, [fingerprint]);

    fs.unlinkSync(logPath);
    fs.writeFileSync(path.join(root, 'file-id-spacer.log'), 'spacer');
    fs.writeFileSync(logPath, 'generation-B');
    const capturedMtime = new Date(fingerprint.modifiedAtUtc);
    fs.utimesSync(logPath, capturedMtime, capturedMtime);

    await manager.drainQueue();

    assert.equal(fs.readFileSync(logPath, 'utf8'), 'generation-B');
});

test('legacy queue records without captured fingerprints never trigger broad log pruning', async (context) => {
    const { logFolder, queuePath, manager } = createLifecycleLogArtifactHarness(context);
    const capturedLog = path.join(logFolder, 'server-2026-08-30.log');
    const unrelatedLog = path.join(logFolder, 'server-2026-08-29.log');
    fs.writeFileSync(capturedLog, 'legacy captured content');
    fs.writeFileSync(unrelatedLog, 'must survive');
    enqueueLifecycleLogArtifact(queuePath, capturedLog, undefined);

    await manager.drainQueue();

    assert.equal(fs.readFileSync(capturedLog, 'utf8'), 'legacy captured content');
    assert.equal(fs.readFileSync(unrelatedLog, 'utf8'), 'must survive');
});
