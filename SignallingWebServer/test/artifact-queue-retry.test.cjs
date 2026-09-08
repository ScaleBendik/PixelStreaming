// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { createSessionLogArtifactManager } = require('../dist/session-log-artifacts');
const { createSessionScreenshotArtifactManager } = require('../dist/session-screenshot-artifacts');

for (const [kind, factory] of [['log', createSessionLogArtifactManager], ['screenshot', createSessionScreenshotArtifactManager]]) {
    test(kind + ' artifact retries remain durable, single-flight and bounded on failure', async t => {
        const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-artifact-retry-'));
        t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
        const queuePath = path.join(directory, 'queue');
        const sourceFolder = path.join(directory, 'source');
        fs.mkdirSync(sourceFolder, { recursive: true });
        const calls = [];
        let release;
        let fail = true;
        const held = new Promise(resolve => { release = resolve; });
        t.after(() => release());
        const manager = factory({ enabled: true, bucketName: 'synthetic-bucket', queuePath,
            sourceFolder, logFolder: sourceFolder, includeWatchdogLogs: false, includeUnrealLogs: false,
            getCurrentInstanceIdentity: async () => ({ instanceId: 'i-test', region: 'eu-north-1' }),
            registerArtifact: async request => {
                calls.push(request.objectKey);
                if (calls.length === 1) await held;
                if (fail) throw new Error('synthetic registration timeout');
            }, logger: () => {} });
        for (let index = 0; index < 4; index++) {
            const id = 'artifact-' + index;
            const localPath = path.join(queuePath, id + '.bundle');
            fs.writeFileSync(localPath, 'synthetic bundle');
            fs.writeFileSync(path.join(queuePath, id + '.json'), JSON.stringify({
                id, localPath, status: 'pending_registration', attempts: 0,
                createdAtUtc: new Date().toISOString(), updatedAtUtc: new Date().toISOString(),
                bucketName: 'synthetic-bucket', objectKey: id,
                request: { instanceId: 'i-test', region: 'eu-north-1', objectKey: id,
                    sessionRequestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', metadata: {} }
            }));
        }
        const first = manager.drainQueue();
        const overlapping = manager.drainQueue();
        for (let index = 0; index < 10; index++) await new Promise(resolve => setImmediate(resolve));
        assert.equal(calls.length, 1, 'a pending registration is not submitted twice');
        release();
        await Promise.all([first, overlapping]);
        assert.deepEqual(calls, ['artifact-0', 'artifact-1', 'artifact-2']);
        assert.equal(fs.readdirSync(queuePath).filter(name => name.endsWith('.json')).length, 4);
        for (let index = 0; index < 4; index++) {
            const record = JSON.parse(fs.readFileSync(path.join(queuePath, 'artifact-' + index + '.json')));
            assert.equal(record.attempts, index < 3 ? 1 : 0);
            assert.equal(fs.existsSync(record.localPath), true);
            assert.equal(record.request.sessionRequestId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
        }
        fail = false;
        await manager.drainQueue();
        await manager.drainQueue();
        assert.deepEqual(calls.slice(3), ['artifact-0', 'artifact-1', 'artifact-2', 'artifact-3']);
        assert.equal(fs.readdirSync(queuePath).filter(name => name.endsWith('.json')).length, 0);
    });
}
