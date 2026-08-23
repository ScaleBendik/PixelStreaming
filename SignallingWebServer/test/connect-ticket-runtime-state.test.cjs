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
    isInstanceAgentRecycleReplacementProof,
    readInstanceAgentRecycleMarkerSnapshot,
    writeInstanceAgentRecycleMarkerSnapshot
} = require('../dist/instance-agent-recycle-state.js');
const { resolveFirstViewerTimeoutStopReason } = require('../dist/viewer-idle-stop.js');

function signConnectTicket(payload, signingKey) {
    const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const headerSegment = encode({ alg: 'HS256', typ: 'JWT' });
    const payloadSegment = encode(payload);
    const signingInput = `${headerSegment}.${payloadSegment}`;
    const signature = crypto.createHmac('sha256', signingKey).update(signingInput).digest('base64url');
    return `${signingInput}.${signature}`;
}

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
                commandJournalPath: path.join(
                    stateDirectory,
                    'instance-agent-active-command.json'
                ),
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
    assert.equal(
        resolveFirstViewerTimeoutStopReason('present'),
        'managed-viewer-history-continuity-lost'
    );
    assert.equal(
        resolveFirstViewerTimeoutStopReason('unavailable'),
        'managed-viewer-evidence-unavailable'
    );
});
