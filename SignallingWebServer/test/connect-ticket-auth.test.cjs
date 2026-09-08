// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const { once } = require('node:events');
const WebSocket = require('ws');
const { Logger } = require('@epicgames-ps/lib-pixelstreamingsignalling-ue5.8');
const { createPlayerVerifyClient } = require('../dist/ConnectTicketAuth.js');
Logger.silent = true;

const key = 'synthetic-auth-test-signing-key-at-least-thirty-two-characters';
const host = 'route-a.stream.example.test';
const codecPolicy = { version: 1, snapshotId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', policyHash: 'A'.repeat(64), allowedCodecs: ['VP9'], defaultCodec: 'VP9', allowSwitching: false };
const identity = { codecPolicy, sessionRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', activeSessionId: '11111111-1111-4111-8111-111111111111' };
function settings(mode, runtimeGate) {
    return { mode, issuer: 'issuer', audience: 'audience', signingKey: key, instanceId: 'i-test', routeHostSuffix: 'stream.example.test', clockSkewSeconds: 0, runtimeGate };
}
function claims() {
    const now = Math.floor(Date.now() / 1000);
    return { iss: 'issuer', aud: 'audience', instanceId: 'i-test', routeKey: 'route-a', exp: now + 60, iat: now, ...identity };
}
function ticket(header, payload) {
    const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const input = encode(header) + '.' + encode(payload);
    return input + '.' + crypto.createHmac('sha256', key).update(input).digest('base64url');
}
function request(token) {
    return { headers: { host }, url: '/?ct=' + encodeURIComponent(token), scaleWorldConnectTicketIdentityValidated: true, scaleWorldValidatedConnectTicketIdentity: { sessionRequestId: 'stale-identity' } };
}
function verify(mode, token, gate, req = request(token)) {
    const results = [];
    assert.doesNotThrow(() => createPlayerVerifyClient(settings(mode, gate))({ req }, (...args) => results.push(args)));
    assert.equal(results.length, 1);
    return { result: results[0], req };
}
function assertUnvalidated(req) {
    assert.equal(req.scaleWorldConnectTicketIdentityValidated, false);
    assert.equal(req.scaleWorldValidatedConnectTicketIdentity, undefined);
}

for (const mode of ['soft', 'enforce']) {
    test(mode + ': non-object JWT headers and payloads cannot throw or establish managed identity', () => {
        for (const value of [null, [], ['HS256'], true, 1, 'text']) {
            for (const token of [ticket(value, claims()), ticket({ alg: 'HS256' }, value)]) {
                const { result, req } = verify(mode, token);
                assert.equal(result[0], mode === 'soft');
                if (mode === 'enforce') assert.equal(result[1], 401);
                assertUnvalidated(req);
            }
        }
    });

    test(mode + ': malformed/missing tickets preserve validation mode without trusted identity', () => {
        for (const token of ['', 'missing.segments', '!.!.!', 'bnVsbA.e30.invalid', 'eyJhbGciOiJIUzI1NiJ9.e30.invalid']) {
            const { result, req } = verify(mode, token);
            assert.equal(result[0], mode === 'soft');
            if (mode === 'enforce') assert.equal(result[1], 401);
            assertUnvalidated(req);
        }
    });

    test(mode + ': runtime verifier exceptions reject exactly once and can recover on the next request', () => {
        for (const failingHook of ['getReconnectGraceEvidenceJournalBlockReason', 'rejectReasonForTicket', 'recordManagedViewerAdmission']) {
            const gate = { getReconnectGraceEvidenceJournalBlockReason: () => null, rejectReasonForTicket: () => null, recordManagedViewerAdmission: () => null };
            gate[failingHook] = () => { throw new Error('synthetic-private-runtime-error'); };
            const token = ticket({ alg: 'HS256' }, claims());
            const { result, req } = verify(mode, token, gate);
            assert.deepEqual(result, [false, 503, 'Connect ticket verification is temporarily unavailable.']);
            assertUnvalidated(req);
            gate[failingHook] = () => null;
            const recovered = verify(mode, token, gate);
            assert.deepEqual(recovered.result, [true]);
            assert.deepEqual(recovered.req.scaleWorldValidatedConnectTicketIdentity, identity);
        }
    });

    test(mode + ': invalid request URLs reject without escaping the websocket verifier', () => {
        const req = request('synthetic-private-ticket');
        req.url = 'http://[';
        const { result } = verify(mode, '', undefined, req);
        assert.deepEqual(result, [false, 503, 'Connect ticket verification is temporarily unavailable.']);
        assertUnvalidated(req);
    });

    test(mode + ': real websocket listener remains usable after a malformed JWT', { timeout: 10000 }, async (context) => {
        const server = new WebSocket.Server({ port: 0, host: '127.0.0.1', verifyClient: createPlayerVerifyClient(settings(mode)) });
        context.after(() => { for (const client of server.clients) client.terminate(); return new Promise(resolve => server.close(resolve)); });
        const admissions = [];
        server.on('connection', (socket, req) => { admissions.push(req); socket.send('admitted'); });
        await once(server, 'listening');
        const base = 'ws://127.0.0.1:' + server.address().port + '/?ct=';
        const malformed = new WebSocket(base + ticket(null, claims()), { headers: { Host: host } });
        malformed.on('error', () => {});
        const firstOutcome = new Promise(resolve => {
            malformed.once('message', () => resolve(101));
            malformed.once('unexpected-response', (_req, response) => { response.resume(); malformed.terminate(); resolve(response.statusCode); });
        });
        assert.equal(await firstOutcome, mode === 'soft' ? 101 : 401);
        malformed.terminate();
        if (mode === 'soft') assertUnvalidated(admissions[0]);
        const valid = new WebSocket(base + ticket({ alg: 'HS256' }, claims()), { headers: { Host: host } });
        valid.on('error', () => {});
        await once(valid, 'message');
        assert.deepEqual(admissions.at(-1).scaleWorldValidatedConnectTicketIdentity, identity);
        valid.terminate();
    });
}

test('off mode remains an explicit bypass and does not install a ticket parser', () => {
    assert.equal(createPlayerVerifyClient(settings('off')), undefined);
});

test('startup configuration errors and completion callback errors are not swallowed', () => {
    assert.throws(() => createPlayerVerifyClient({ ...settings('enforce'), signingKey: '' }), /signing_key/);
    const verifier = createPlayerVerifyClient(settings('enforce'));
    const callbackFailure = new Error('caller callback failure');
    let calls = 0;
    assert.throws(() => verifier({ req: request(ticket({ alg: 'HS256' }, claims())) }, () => { calls++; throw callbackFailure; }), error => error === callbackFailure);
    assert.equal(calls, 1);
});
