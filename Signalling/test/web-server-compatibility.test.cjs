// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const { Logger: CommonLogger } = require('@epicgames-ps/lib-pixelstreamingcommon-ue5.8');
const { Logger } = require('../dist/cjs/Logger.js');
CommonLogger.InitLogging(0, false);
Logger.silent = true;
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const express = require('express');
const { WebServer } = require('../dist/cjs/WebServer.js');

async function serve(context, overrides = {}) {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'signalling-web-compat-'));
    context.after(() => fs.rm(root, { recursive: true, force: true }));
    await fs.writeFile(path.join(root, 'player.html'), '<html>runtime-player</html>');
    await fs.writeFile(path.join(root, 'player.hash.js'), 'runtime-script');
    const app = express();
    // A consumer can install HTTP authorization before constructing WebServer. Verify that
    // a static/CORS merge cannot bypass that middleware for documents or API responses.
    app.use((req, res, next) => {
        if (req.headers.authorization !== 'Bearer valid-ticket') return res.status(401).end();
        next();
    });
    const server = new WebServer(app, {
        httpPort: 0, root, homepageFile: 'player.html', serveStatic: true,
        cors: { enabled: true, allowedOrigins: ['https://manager.example.test'] },
        ...overrides
    });
    context.after(async () => {
        server.httpServer.closeAllConnections();
        await new Promise((resolve, reject) => server.httpServer.close(error => error ? reject(error) : resolve()));
    });
    app.get('/api/status', (_req, res) => res.json({ healthy: true }));
    await once(server.httpServer, 'listening');
    return 'http://127.0.0.1:' + server.httpServer.address().port;
}

const headers = { Authorization: 'Bearer valid-ticket', Origin: 'https://manager.example.test' };

test('protected HTML stays uncached and CORS applies to homepage, static files, and later API routes', async (context) => {
    const base = await serve(context);
    assert.equal((await fetch(base + '/player.html')).status, 401);
    for (const route of ['/', '/player.html']) {
        const response = await fetch(base + route, { headers });
        assert.equal(response.status, 200);
        assert.match(response.headers.get('cache-control'), /no-store/);
        assert.equal(response.headers.get('access-control-allow-origin'), headers.Origin);
        assert.match(await response.text(), /runtime-player/);
    }
    const script = await fetch(base + '/player.hash.js', { headers });
    assert.equal(script.status, 200);
    assert.equal(script.headers.get('access-control-allow-origin'), headers.Origin);
    assert.doesNotMatch(script.headers.get('cache-control'), /no-store/);
    const api = await fetch(base + '/api/status', { headers });
    assert.equal(api.headers.get('access-control-allow-origin'), headers.Origin);
    assert.deepEqual(await api.json(), { healthy: true });
});

test('REST-only serving exposes no static files and rate-limits routes while allowing CORS preflight', async (context) => {
    const base = await serve(context, { serveStatic: false, perMinuteRateLimit: 3 });
    assert.equal((await fetch(base + '/player.html', { headers })).status, 404);
    assert.equal((await fetch(base + '/', { headers })).status, 404);
    assert.equal((await fetch(base + '/api/status', { headers })).status, 200);
    assert.equal((await fetch(base + '/api/status', { headers })).status, 429);
    const preflight = await fetch(base + '/api/status', {
        method: 'OPTIONS', headers: { ...headers, 'Access-Control-Request-Method': 'GET' }
    });
    assert.equal(preflight.status, 204);
    assert.equal(preflight.headers.get('access-control-allow-origin'), headers.Origin);
    assert.equal((await fetch(base + '/api/status')).status, 401);
});
