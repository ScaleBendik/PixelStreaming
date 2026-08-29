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
    normalizeInstanceAgentReconnectGraceWindowForReport
} = require('../dist/instance-agent.js');
const {
    isInstanceAgentCommandExpired,
    writeInstanceAgentCommandJournalSnapshot
} = require('../dist/instance-agent-command-state.js');
const {
    isInstanceAgentRecycleReplacementProof,
    readInstanceAgentRecycleMarkerSnapshot,
    writeInstanceAgentRecycleMarkerSnapshot
} = require('../dist/instance-agent-recycle-state.js');
const { resolveFirstViewerTimeoutStopReason, wireViewerIdleStop } = require('../dist/viewer-idle-stop.js');
const {
    appendInstanceAgentReconnectGraceElapsedEvidence,
    readInstanceAgentReconnectGraceElapsedEvidenceJournal
} = require('../dist/instance-agent-reconnect-grace-evidence-state.js');

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
