// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const test = require('node:test');
const WebSocket = require('ws');

async function freePort() {
    const server = net.createServer();
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    await new Promise((resolve) => server.close(resolve));
    return port;
}

async function waitFor(predicate, describe) {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
        if (await predicate()) return;
        await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error('Timed out waiting for ' + describe);
}

async function startWilbur(t, overrides = {}) {
    const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'scaleworld-ue58-test-'));
    t.after(() => fs.rm(folder, { recursive: true, force: true }));
    const playerPort = await freePort();
    const streamerPort = await freePort();
    const sfuPort = await freePort();
    await fs.writeFile(path.join(folder, 'player.html'), '<html>upgrade test</html>');
    const config = {
        player_port: playerPort,
        streamer_port: streamerPort,
        sfu_port: sfuPort,
        serve: false,
        rest_api: true,
        http_root: folder,
        homepage: 'player.html',
        log_folder: path.join(folder, 'logs'),
        log_level_console: 'debug',
        log_level_file: 'debug',
        log_config: true,
        runtime_status: false,
        instance_agent: false,
        viewer_idle_stop: false,
        instance_agent_desired_state_path: path.join(folder, 'state', 'desired.json'),
        ...overrides
    };
    const configPath = path.join(folder, 'config.json');
    await fs.writeFile(configPath, JSON.stringify(config));
    const child = spawn(process.execPath, ['dist/index.js', '--config_file', configPath], {
        cwd: path.resolve(__dirname, '..'), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, AWS_EC2_METADATA_DISABLED: 'true' }
    });
    let output = '';
    child.stdout.on('data', (data) => { output += data.toString(); });
    child.stderr.on('data', (data) => { output += data.toString(); });
    let spawnError;
    child.on('error', (error) => { spawnError = error; });
    t.after(async () => {
        if (child.exitCode === null && !spawnError) {
            const closed = once(child, 'close');
            child.kill();
            await closed;
        }
    });
    const baseUrl = 'http://127.0.0.1:' + playerPort;
    await waitFor(async () => {
        if (spawnError) throw spawnError;
        if (child.exitCode !== null) throw new Error('Wilbur failed: ' + output);
        try { return (await fetch(baseUrl + '/api/status')).ok; } catch { return false; }
    }, 'Wilbur REST API');
    return { baseUrl, playerPort, streamerPort, output: () => output };
}

function connect(t, url, options) {
    const socket = new WebSocket(url, options);
    const messages = [];
    socket.on('message', (data) => messages.push(JSON.parse(data.toString())));
    socket.on('error', () => {});
    t.after(() => socket.terminate());
    return { socket, messages };
}

function signTicket(payload, key) {
    const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const input = encode({ alg: 'HS256', typ: 'JWT' }) + '.' + encode(payload);
    return input + '.' + crypto.createHmac('sha256', key).update(input).digest('base64url');
}

test('REST-only Wilbur starts without serving the player or changing keepalive defaults', { timeout: 20000 }, async (t) => {
    const wilbur = await startWilbur(t);
    assert.equal((await fetch(wilbur.baseUrl + '/player.html')).status, 404);
    assert.equal((await fetch(wilbur.baseUrl + '/')).status, 404);
    const status = await (await fetch(wilbur.baseUrl + '/api/status')).json();
    assert.equal(status.player_count, 0);
    const configResponse = await fetch(wilbur.baseUrl + '/api/config');
    assert.equal(configResponse.status, 200);
    const snapshot = await configResponse.json();
    assert.equal(snapshot.config.streamerPort, wilbur.streamerPort);
    assert.equal(Object.hasOwn(snapshot.config, 'httpServer'), false);
    assert.equal(Object.hasOwn(snapshot.config, 'playerWsOptions'), false);
    assert.match(wilbur.output(), /\[player-keepalive\] Enabled/);
    assert.match(wilbur.output(), /"player_keepalive_timeout": "0"/);
});

test('TURN generation preserves split ICE policies, config-first ordering and signed admission', { timeout: 20000 }, async (t) => {
    const signingKey = 'local-test-signing-key-with-at-least-32-characters';
    const turnSecret = 'local-test-turn-secret-must-never-appear-in-logs';
    const wilbur = await startWilbur(t, {
        serve: true,
        auth_mode: 'enforce', auth_issuer: 'upgrade-test', auth_audience: 'upgrade-test',
        auth_signing_key: signingKey, auth_instance_id: 'i-upgrade-test',
        auth_route_host_suffix: 'stream.example.test',
        turn_secret: turnSecret, turn_ttl: 600,
        peer_options: { iceServers: [{ urls: 'stun:shared.example.test' }] },
        peer_options_player: { iceTransportPolicy: 'relay', iceServers: [{ urls: 'turn:player.example.test' }] },
        peer_options_streamer: { iceTransportPolicy: 'all', iceServers: [{ urls: 'turn:streamer.example.test' }] }
    });
    const html = await fetch(wilbur.baseUrl + '/player.html');
    assert.equal(html.status, 200);
    assert.match(html.headers.get('cache-control'), /no-store/);
    const denied = connect(t, 'ws://127.0.0.1:' + wilbur.playerPort, {
        headers: { Host: 'upgrade.stream.example.test' }
    });
    const rejection = await new Promise((resolve, reject) => {
        denied.socket.once('unexpected-response', (_request, response) => { response.resume(); resolve(response.statusCode); });
        denied.socket.once('open', () => reject(new Error('Unsigned connection was admitted')));
    });
    assert.equal(rejection, 401);
    assert.deepEqual(denied.messages, []);
    denied.socket.terminate();
    const streamer = connect(t, 'ws://127.0.0.1:' + wilbur.streamerPort);
    await waitFor(() => streamer.messages.length >= 2, 'streamer handshake');
    assert.deepEqual(streamer.messages.slice(0, 2).map((message) => message.type), ['config', 'identify']);
    const streamerOptions = streamer.messages[0].peerConnectionOptions;
    assert.equal(streamerOptions.iceTransportPolicy, 'all');
    assert.equal(streamerOptions.iceServers[0].urls, 'turn:streamer.example.test');
    const now = Math.floor(Date.now() / 1000);
    const ticket = signTicket({
        iss: 'upgrade-test', aud: 'upgrade-test', instanceId: 'i-upgrade-test',
        routeKey: 'upgrade', iat: now, nbf: now - 1, exp: now + 60
    }, signingKey);
    const player = connect(t, 'ws://127.0.0.1:' + wilbur.playerPort + '/?ct=' + ticket, {
        headers: { Host: 'upgrade.stream.example.test' }
    });
    await waitFor(() => player.messages.some((message) => message.type === 'config'), 'authenticated player config');
    const playerOptions = player.messages.find((message) => message.type === 'config').peerConnectionOptions;
    assert.equal(playerOptions.iceTransportPolicy, 'relay');
    assert.equal(playerOptions.iceServers[0].urls, 'turn:player.example.test');
    for (const options of [playerOptions, streamerOptions]) {
        const ice = options.iceServers[0];
        assert.equal(ice.credential, crypto.createHmac('sha1', turnSecret).update(ice.username).digest('base64'));
    }
    assert.ok(Number(playerOptions.iceServers[0].username.split(':')[0]) < now + 700);
    assert.ok(Number(streamerOptions.iceServers[0].username.split(':')[0]) > now + 86400 * 365);
    assert.equal(streamer.messages.filter((message) => message.type === 'config').length, 1);
    for (const [kind, secret] of Object.entries({ signingKey, turnSecret, ticket, turnCredential: playerOptions.iceServers[0].credential })) {
        assert.ok(!wilbur.output().includes(secret), 'sensitive ' + kind + ' appeared in Wilbur output');
    }
});
