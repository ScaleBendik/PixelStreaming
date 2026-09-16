const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { RuntimeRecovery } = require('../dist/runtime-recovery.js');
const { createConnectTicketRuntimeGate } = require('../dist/connect-ticket-runtime-state.js');

test('recovery context survives a Wilbur restart but never inherits an unreconciled prior-boot owner', t => {
    const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-recovery-owner-'));
    t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
    const options = { desiredStatePath: path.join(folder, 'desired.json'),
        nowEpochSeconds: () => 2000, hostBootEpochSeconds: 1000, logger() {} };
    const identity = { sessionRequestId: randomUUID() };
    const gate = createConnectTicketRuntimeGate(options);
    assert.equal(gate.getManagedViewerIdentity(), null);
    assert.equal(gate.recordManagedViewerAdmission(identity), null);
    assert.equal(gate.getManagedViewerIdentity().sessionRequestId, identity.sessionRequestId);
    assert.equal(createConnectTicketRuntimeGate(options).getManagedViewerIdentity().sessionRequestId, identity.sessionRequestId);
    assert.equal(createConnectTicketRuntimeGate({ ...options, hostBootEpochSeconds: 3000 }).getManagedViewerIdentity(), null);
    gate.markTeardownStarted();
    assert.equal(gate.getManagedViewerIdentity(), null);
});

test('watchdog evidence survives restart, acknowledgement removes only submitted events, and notices are session fenced', t => {
    const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-recovery-'));
    t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
    const desired = path.join(folder, 'desired.json');
    const recovery = new RuntimeRecovery(desired, () => {});
    const request = randomUUID();
    recovery.context(request, false);
    function event(kind = 'unexpected_exit') {
        const value = { eventType: 'runtime_fault', occurredAtUtc: new Date(Date.now() - 1000).toISOString(),
            metadata: { runtimeFaultEvidenceVersion: '1', evidenceId: randomUUID(), sessionRequestId: request,
                runtimeGeneration: recovery.generation, faultKind: kind, phase: 'restart_requested' } };
        fs.writeFileSync(path.join(recovery.directory, value.metadata.evidenceId + '.json'), JSON.stringify(value));
        fs.writeFileSync(path.join(recovery.directory, 'notice.json'), JSON.stringify(value));
        return value;
    }
    const first = event();
    const restarted = new RuntimeRecovery(desired, () => {});
    assert.deepEqual(restarted.batch(), [first]);
    const second = event('unresponsive');
    restarted.acknowledge([first]);
    assert.deepEqual(restarted.batch(), [second]);
    assert.equal(restarted.notice().kind, 'unresponsive', 'API acknowledgement does not clear an active notice');
    restarted.context(randomUUID(), false);
    assert.equal(restarted.notice(), null, 'replacement session cannot inherit prior fault');
    restarted.context(request, false);
    restarted.mediaReceived(request);
    assert.equal(restarted.notice(), null, 'real media clears the notice');
    assert.equal(restarted.batch().filter(e => e.metadata.phase === 'media_restored').length, 1);
    restarted.mediaReceived(request);
    assert.equal(restarted.batch().filter(e => e.metadata.phase === 'media_restored').length, 1);
    restarted.context(request, true);
    assert.equal(restarted.notice(), null, 'normal teardown is suppressed');
});
