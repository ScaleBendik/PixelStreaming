const test = require('node:test');
const assert = require('node:assert/strict');
const { VideoQpIndicator } = require('../dist/cjs/UI/VideoQpIndicator.js');
const { Application } = require('../dist/cjs/Application/Application.js');

function element() {
    const attributes = new Map();
    return {
        style: {},
        classList: { add() {} },
        appendChild() {},
        setAttributeNS(_namespace, name, value) { attributes.set(name, value); },
        getAttribute(name) { return attributes.get(name); }
    };
}

function createIndicator(t, config) {
    const savedDocument = Object.getOwnPropertyDescriptor(globalThis, 'document');
    Object.defineProperty(globalThis, 'document', {
        configurable: true,
        value: { createElement: element, createElementNS: element }
    });
    const indicator = new VideoQpIndicator(config);
    indicator.rootElement;
    t.after(() => {
        indicator.setConnected(false);
        if (savedDocument) Object.defineProperty(globalThis, 'document', savedDocument);
        else delete globalThis.document;
    });
    return indicator;
}

function createApplication(indicator) {
    const application = Object.create(Application.prototype);
    application.videoQpIndicator = indicator;
    application.showOpeningStreamOverlay = () => {};
    application.showErrorOverlay = () => {};
    return application;
}

function stats(mimeType) {
    return {
        inboundVideoStats: { codecId: 'inbound-video', bitrate: 15000 },
        codecs: new Map([['inbound-video', { mimeType }]])
    };
}

test('AV1 at 15 Mbps is not rated using the H.264 QP thresholds', (t) => {
    const indicator = createIndicator(t);
    const application = createApplication(indicator);
    application.onWebRtcConnected();
    application.onVideoEncoderAvgQP(100);
    application.onStatsReceived(stats('video/AV1'));

    assert.equal(indicator.color, '#b0b0b0');
    assert.match(indicator.qualityText.innerHTML, /AV1 QP: 100 \(quality not rated\)/);
    assert.doesNotMatch(indicator.qualityText.innerHTML, /Poor|Blocky|Clear/);
});

test('the same raw QP has a H.264 heuristic but no VP9 or unknown-codec rating', (t) => {
    const indicator = createIndicator(t);
    indicator.setConnected(true);
    indicator.updateQpTooltip(40);
    assert.match(indicator.qualityText.innerHTML, /Unknown codec.*quality not rated/);
    indicator.updateVideoCodec('video/H264');
    assert.equal(indicator.color, 'red');
    assert.match(indicator.qualityText.innerHTML, /High H.264 quantization/);
    indicator.updateVideoCodec('video/VP9');
    assert.equal(indicator.color, '#b0b0b0');
    assert.match(indicator.qualityText.innerHTML, /VP9 QP: 40.*quality not rated/);
    indicator.updateVideoCodec(undefined);
    assert.match(indicator.qualityText.innerHTML, /Unknown codec.*quality not rated/);
});

test('valid QP zero is distinct from disconnected and missing or invalid telemetry', (t) => {
    const indicator = createIndicator(t);
    assert.match(indicator.qualityText.innerHTML, /Not connected/);
    indicator.setConnected(true);
    indicator.updateVideoCodec('video/H264');
    assert.match(indicator.qualityText.innerHTML, /Waiting for encoder statistics/);
    indicator.updateQpTooltip(0);
    assert.equal(indicator.color, 'lime');
    assert.match(indicator.qualityText.innerHTML, /QP 0/);
    for (const invalid of [NaN, Infinity, -1]) {
        indicator.updateQpTooltip(invalid);
        assert.equal(indicator.color, '#b0b0b0');
        assert.match(indicator.qualityText.innerHTML, /Waiting for encoder statistics/);
    }
});

test('H.264 retains the existing color threshold boundaries', (t) => {
    const indicator = createIndicator(t);
    indicator.setConnected(true);
    indicator.updateVideoCodec('video/H264');
    for (const [qp, color] of [[26, 'lime'], [27, 'orange'], [35, 'orange'], [36, 'red']]) {
        indicator.updateQpTooltip(qp);
        assert.equal(indicator.color, color, `H.264 QP ${qp}`);
    }
});

test('a hidden low-QP H.264 icon becomes visible for high QP and unrated codecs', (t) => {
    const indicator = createIndicator(t, { hideWhenGood: true });
    indicator.setConnected(true);
    indicator.updateVideoCodec('video/H264');
    indicator.updateQpTooltip(20);
    assert.equal(indicator.qualityStatus.style.opacity, '0');
    indicator.updateQpTooltip(40);
    assert.equal(indicator.qualityStatus.style.opacity, '1');
    indicator.updateQpTooltip(20);
    indicator.updateVideoCodec('video/AV1');
    assert.equal(indicator.qualityStatus.style.opacity, '1');
});

test('disconnect and a replacement connection cannot inherit the previous codec or QP', (t) => {
    const indicator = createIndicator(t);
    const application = createApplication(indicator);
    application.onWebRtcConnected();
    application.onStatsReceived(stats('video/H264'));
    application.onVideoEncoderAvgQP(40);
    assert.equal(indicator.color, 'red');

    // Also exercise the early return used during an initial auto-connect retry.
    application.isInitialAutoConnectPending = true;
    application.onDisconnect('', false);
    assert.match(indicator.qualityText.innerHTML, /Not connected/);
    application.onWebRtcConnected();
    assert.match(indicator.qualityText.innerHTML, /Waiting for encoder statistics/);
    application.onVideoEncoderAvgQP(100);
    assert.match(indicator.qualityText.innerHTML, /Unknown codec.*quality not rated/);
    application.onStatsReceived(stats('video/AV1'));
    assert.match(indicator.qualityText.innerHTML, /AV1 QP: 100.*quality not rated/);
});

test('connection attempts and failures clear the indicator even without a disconnect event', (t) => {
    const indicator = createIndicator(t);
    const application = createApplication(indicator);
    for (const boundary of ['onWebRtcConnecting', 'onWebRtcFailed']) {
        application.onWebRtcConnected();
        application.onStatsReceived(stats('video/H264'));
        application.onVideoEncoderAvgQP(40);
        application[boundary]();
        assert.match(indicator.qualityText.innerHTML, /Not connected/);
        application.onWebRtcConnected();
        application.onVideoEncoderAvgQP(40);
        assert.match(indicator.qualityText.innerHTML, /Unknown codec.*quality not rated/);
    }
});
