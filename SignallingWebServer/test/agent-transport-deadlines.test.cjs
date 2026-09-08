// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const test = require('node:test');
const { fetchWithDeadline } = require('../dist/instance-agent-transport');
const { execArtifactFile } = require('../dist/artifact-process');

async function serverFixture(t, handler) {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    t.after(() => {
        server.closeAllConnections();
        return new Promise(resolve => server.close(resolve));
    });
    return 'http://127.0.0.1:' + server.address().port;
}

test('agent deadline aborts stalled response headers and permits a later healthy request', { timeout: 5000 }, async t => {
    const url = await serverFixture(t, (req, res) => {
        if (req.url === '/healthy') res.end('healthy');
    });
    await assert.rejects(fetchWithDeadline(url + '/stalled', {}, 100), error => /Timeout|Abort/.test(error.name));
    assert.equal(await (await fetchWithDeadline(url + '/healthy', {}, 1000)).text(), 'healthy');
});

test('agent deadline remains active after headers, including failed-response bodies', { timeout: 5000 }, async t => {
    const url = await serverFixture(t, (_req, res) => {
        res.writeHead(503, { 'Content-Type': 'application/json' });
        res.flushHeaders();
    });
    const response = await fetchWithDeadline(url, {}, 150);
    assert.equal(response.status, 503);
    await assert.rejects(response.text(), error => /Timeout|Abort/.test(error.name));
});

test('agent deadline preserves caller cancellation', { timeout: 5000 }, async t => {
    const url = await serverFixture(t, () => {});
    const controller = new AbortController();
    const request = fetchWithDeadline(url, { signal: controller.signal }, 2000);
    controller.abort();
    await assert.rejects(request, error => /Abort/.test(error.name));
});

test('stalled artifact child is terminated before a subsequent invocation', { timeout: 5000 }, async () => {
    await assert.rejects(
        execArtifactFile(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {}, 100),
        error => error.killed === true
    );
    const result = await execArtifactFile(process.execPath, ['-e', "process.stdout.write('healthy')"], {}, 2000);
    assert.equal(result.stdout, 'healthy');
});
