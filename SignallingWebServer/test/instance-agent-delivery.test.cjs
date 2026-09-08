// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const logModule = require('../dist/session-log-artifacts');
const screenshotModule = require('../dist/session-screenshot-artifacts');
const { wireInstanceAgent } = require('../dist/instance-agent');

function deferred() {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
}
async function settle() {
    for (let index = 0; index < 30; index++) await new Promise(resolve => setImmediate(resolve));
}
async function harness(t, options = {}) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-agent-delivery-'));
    const originals = { fetch: global.fetch, setInterval: global.setInterval, clearInterval: global.clearInterval,
        setTimeout: global.setTimeout, clearTimeout: global.clearTimeout,
        logFactory: logModule.createSessionLogArtifactManager,
        screenshotFactory: screenshotModule.createSessionScreenshotArtifactManager };
    const intervals = [], timeouts = [], batches = [], heartbeats = [], messages = [];
    const state = { warmHoldEnabled: true, drainEnabled: false, shutdownRequested: false, policyVersion: 'initial' };
    const h = { state, batches, heartbeats, messages, intervals, timeouts,
        eventReply: async batch => Response.json({ acceptedCount: batch.length, commands: [], desiredState: state }),
        heartbeatReply: async () => Response.json({ commands: [], desiredState: state }),
        commandTransitions: [],
        logDrains: 0, screenshotDrains: 0 };
    global.setInterval = (callback, delay) => { const timer = { callback, delay, unref() { this.unreferenced = true; } }; intervals.push(timer); return timer; };
    global.clearInterval = timer => { if (timer) timer.cleared = true; };
    global.setTimeout = (callback, delay) => { const timer = { callback, delay, unref() { this.unreferenced = true; } }; timeouts.push(timer); return timer; };
    global.clearTimeout = timer => { if (timer) timer.cleared = true; };
    logModule.createSessionLogArtifactManager = managerOptions => {
        h.logOptions = managerOptions;
        return { cleanStartupLogs() {}, cleanStartupQueue() {},
            drainQueue: async () => { h.logDrains++; await options.logDrain?.(h); },
            captureAndUpload: async () => { await options.logCapture?.(h); } };
    };
    screenshotModule.createSessionScreenshotArtifactManager = managerOptions => {
        h.screenshotOptions = managerOptions;
        return { cleanStartupScreenshots() {}, cleanStartupQueue() {}, attachSessionContext() {},
            startSession() {},
            completeSessionAndUpload: async () => { await options.screenshotCapture?.(h); return { status: 'captured' }; },
            drainQueue: async () => { h.screenshotDrains++; await options.screenshotDrain?.(h); },
            captureAndUpload: async () => {} };
    };
    global.fetch = async (url, init = {}) => {
        const route = new URL(url).pathname;
        if (route === '/agent/bootstrap') return Response.json({ agentToken: 'test-token',
            heartbeatIntervalSeconds: 10, commands: h.bootstrapCommands ?? [], desiredState: state });
        if (route === '/agent/entitlement-manifest') return Response.json({});
        if (route === '/agent/events/batch') {
            const batch = JSON.parse(init.body).events;
            batches.push(batch);
            return h.eventReply(batch, init);
        }
        if (route === '/agent/heartbeat') {
            heartbeats.push(JSON.parse(init.body));
            return h.heartbeatReply(init);
        }
        if (route.startsWith('/agent/commands/')) { h.commandTransitions.push({ route, body: JSON.parse(init.body) }); return Response.json({ accepted: true, commandStatus: 'completed' }); }
        if (route === '/agent/artifacts/register') return options.registerReply(h, init);
        throw new Error('Network disabled in agent fixture: ' + route);
    };
    t.after(async () => {
        await options.release?.();
        await settle();
        Object.assign(global, { fetch: originals.fetch, setInterval: originals.setInterval,
            clearInterval: originals.clearInterval, setTimeout: originals.setTimeout, clearTimeout: originals.clearTimeout });
        logModule.createSessionLogArtifactManager = originals.logFactory;
        screenshotModule.createSessionScreenshotArtifactManager = originals.screenshotFactory;
        fs.rmSync(directory, { recursive: true, force: true });
    });
    options.beforeWire?.(directory);
    options.configure?.(h);
    h.client = wireInstanceAgent({ playerRegistry: { count: () => 0, get: () => undefined, has: () => false, on() {} } }, {
        enabled: true, apiBaseUrl: 'https://agent.test', instanceId: 'i-test', region: 'eu-north-1',
        requireIdentityProof: false, heartbeatMs: 10000,
        desiredStatePath: path.join(directory, 'desired.json'),
        runtimeEntitlementManifestPath: path.join(directory, 'manifest.json'), logger: message => messages.push(message),
        ...options.agentOptions
    });
    h.queue = id => h.client.recordSessionNetworkPath({ sessionRequestId: id, usesTurn: false });
    h.poll = async () => {
        const timer = intervals.find(timer => !timer.cleared && !timer.unreferenced);
        assert.ok(timer, 'heartbeat timer exists');
        timer.callback();
        await settle();
    };
    await settle();
    batches.length = 0;
    return h;
}

for (const acceptedCount of [100, 50, 0, 'failed request']) {
    test('event acknowledgement ' + acceptedCount + ' cannot remove new arrivals after overflow', async t => {
        const held = deferred();
        const h = await harness(t, { release: () => held.resolve(Response.json({ acceptedCount, commands: [] })) });
        for (let i = 0; i < 100; i++) h.queue('old-' + i);
        h.eventReply = () => held.promise;
        await h.poll();
        assert.equal(h.batches.length, 1);
        assert.equal(h.batches[0].length, 100);
        h.queue('new-unsent');
        await h.poll();
        assert.equal(h.batches.length, 1, 'only one event batch may be in flight');
        if (typeof acceptedCount === 'number') held.resolve(Response.json({ acceptedCount, commands: [], desiredState: h.state }));
        else held.reject(new Error('synthetic transport failure'));
        await settle();
        h.batches.length = 0;
        h.eventReply = async batch => Response.json({ acceptedCount: batch.length, commands: [], desiredState: h.state });
        await h.poll();
        const delivered = h.batches.flat().filter(event => event.eventType === 'session_network_path');
        const firstRetained = Math.max(1, typeof acceptedCount === 'number' ? acceptedCount : 0);
        assert.deepEqual(delivered.map(event => event.metadata.sessionRequestId),
            [...Array.from({ length: 100 - firstRetained }, (_, i) => 'old-' + (i + firstRetained)), 'new-unsent']);
        assert.ok(h.batches.every(batch => batch.length <= 100));
    });
}

test('failed event upload preserves retry order and cannot suppress heartbeats', async t => {
    const held = deferred();
    const h = await harness(t, { release: () => held.resolve(Response.json({ acceptedCount: 0 })) });
    h.queue('a'); h.queue('b');
    h.eventReply = () => held.promise;
    await h.poll();
    h.queue('c');
    const before = h.heartbeats.length;
    await h.poll();
    assert.ok(h.heartbeats.length > before, 'healthy control continues during a stalled event request');
    held.reject(new Error('synthetic transport failure'));
    await settle();
    h.eventReply = async () => new Response('unavailable', { status: 503 });
    await h.poll();
    h.queue('d');
    h.eventReply = async batch => Response.json({ acceptedCount: batch.length, commands: [], desiredState: {} });
    await h.poll();
    assert.deepEqual(h.batches.at(-1).filter(event => event.eventType === 'session_network_path')
        .map(event => event.metadata.sessionRequestId), ['a', 'b', 'c', 'd']);
});

for (const kind of ['log', 'screenshot', 'registration']) {
    test('stalled ' + kind + ' artifact work cannot block heartbeat or command delivery', async t => {
        const held = deferred();
        const options = { release: () => held.resolve(Response.json({ artifactId: 'test', sessionRequestId: 'session' })) };
        if (kind === 'log') options.logDrain = () => held.promise;
        if (kind === 'screenshot') options.screenshotDrain = () => held.promise;
        if (kind === 'registration') {
            options.logDrain = h => h.logOptions.registerArtifact({ instanceId: 'i-test', region: 'eu-north-1' });
            options.registerReply = () => held.promise;
        }
        const h = await harness(t, options);
        const received = [];
        h.client.addCommandListener(command => received.push(command));
        h.heartbeatReply = async () => Response.json({ desiredState: { shutdownRequested: true }, commands: [{
            instanceCommandId: 'command-new', instanceId: 'i-test', region: 'eu-north-1', commandType: 'shutdown',
            idempotencyKey: 'test', requestedAtUtc: new Date().toISOString(), timeoutAtUtc: new Date(Date.now() + 60000).toISOString()
        }] });
        const before = h.heartbeats.length;
        await h.poll(); await h.poll();
        assert.ok(h.heartbeats.length >= before + 2);
        assert.ok(received.length >= 1, 'heartbeat commands are delivered while artifact transport is pending');
        assert.equal(kind === 'screenshot' ? h.screenshotDrains : h.logDrains, 1, 'artifact workers do not overlap');
    });
}

test('late event control state cannot overwrite newer heartbeat state', async t => {
    const held = deferred();
    const h = await harness(t, { release: () => held.resolve(Response.json({ acceptedCount: 0 })) });
    h.queue('event');
    h.eventReply = () => held.promise;
    await h.poll();
    h.heartbeatReply = async () => Response.json({ commands: [], desiredState: { shutdownRequested: true, policyVersion: 'new' } });
    await h.poll();
    assert.equal(h.client.getDesiredState().shutdownRequested, true);
    held.resolve(Response.json({ acceptedCount: 100, commands: [], desiredState: { shutdownRequested: false, policyVersion: 'old' } }));
    await settle();
    assert.equal(h.client.getDesiredState().shutdownRequested, true);
    assert.equal(h.client.getDesiredState().policyVersion, 'new');
});

for (const invalidate of [false, true]) {
    test('recovered completion preserves capture ordering and rechecks control ownership: ' + invalidate, async t => {
        const { writeInstanceAgentCommandJournalSnapshot } = require('../dist/instance-agent-command-state');
        const held = deferred();
        const command = { instanceCommandId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            instanceId: 'i-test', region: 'eu-north-1', commandType: 'recycleToWarm',
            idempotencyKey: 'recovered', requestedAtUtc: new Date().toISOString(),
            timeoutAtUtc: new Date(Date.now() + 60000).toISOString(), status: 'running', attemptNumber: 1 };
        let captures = 0, screenshotCaptures = 0;
        const h = await harness(t, {
            release: () => held.resolve(),
            beforeWire(directory) {
                writeInstanceAgentCommandJournalSnapshot(path.join(directory, 'instance-agent-active-command.json'), command, () => {});
            },
            configure(h) {
                h.bootstrapCommands = [command];
                h.heartbeatReply = async () => Response.json({ commands: [command], desiredState: h.state });
                h.eventReply = async batch => Response.json({ acceptedCount: batch.length, commands: [command], desiredState: h.state });
            },
            agentOptions: { connectTicketRuntimeGate: { isCommercialRecoveryRequired: () => false,
                getReconnectGraceEvidenceJournalBlockReason: () => null,
                setReconnectGraceEvidenceJournalBlock() {},
                markTeardownStarted: () => true,
                getRecycleTokenCompletionStatus: () => 'completed' } },
            logCapture: async () => { captures++; await held.promise; },
            screenshotCapture: async () => { screenshotCaptures++; }
        });
        // Bootstrap must retain the recovered command before a Ready heartbeat can finalize it.
        h.client.recordRuntimeStatus({ status: 'ready', reason: 'replacement_ready', source: 'test' });
        await h.poll();
        assert.equal(captures, 1, h.messages.join('\n'));
        assert.equal(screenshotCaptures, 0, 'screenshots wait for log capture');
        assert.equal(h.commandTransitions.length, 0, 'completion waits for capture');
        if (invalidate) {
            h.heartbeatReply = async () => Response.json({ commands: [], desiredState: { shutdownRequested: true } });
            h.eventReply = async batch => Response.json({ acceptedCount: batch.length, commands: [], desiredState: { shutdownRequested: true } });
        }
        const before = h.heartbeats.length;
        await h.poll();
        assert.ok(h.heartbeats.length > before);
        assert.equal(captures, 1, 'recovery workers do not overlap while capture is pending');
        held.resolve();
        await settle();
        assert.equal(screenshotCaptures, 1);
        assert.equal(h.commandTransitions.filter(item => item.route === '/agent/commands/complete').length, invalidate ? 0 : 1);
    });
}
