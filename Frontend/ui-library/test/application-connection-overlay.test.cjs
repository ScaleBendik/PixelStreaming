const assert = require('node:assert/strict');
const test = require('node:test');

const { Application } = require('../dist/cjs/Application/Application.js');

function createOverlay() {
    return {
        visible: false,
        showCount: 0,
        hideCount: 0,
        text: '',
        show() {
            this.visible = true;
            this.showCount += 1;
        },
        hide() {
            this.visible = false;
            this.hideCount += 1;
        },
        update(text) {
            this.text = text;
        }
    };
}

function createApplication() {
    const application = Object.create(Application.prototype);
    application.hasPresentedMediaForCurrentConnection = false;
    application.isConnectionProgressOverlayActive = false;
    application.isInitialAutoConnectPending = false;
    application.currentOverlay = null;
    application.disconnectOverlay = createOverlay();
    application.connectOverlay = createOverlay();
    application.playOverlay = createOverlay();
    application.infoOverlay = createOverlay();
    application.errorOverlay = createOverlay();
    application.afkOverlay = createOverlay();
    application.stream = {
        config: {
            isFlagEnabled: () => true
        }
    };
    application.statsPanel = undefined;
    return application;
}

test('SDP negotiation remains visible while no playback or media evidence exists', () => {
    const application = createApplication();

    application.onWebRtcSdp();

    assert.equal(application.currentOverlay, application.infoOverlay);
    assert.equal(application.infoOverlay.visible, true);
    assert.equal(application.infoOverlay.text, 'WebRTC Connection Negotiated');
});

test('connection progress may repaint after play starts but before a frame is presented', () => {
    const application = createApplication();

    application.onWebRtcSdp();
    application.onPlayStream();
    application.onWebRtcConnected();
    application.onWebRtcSdp();

    assert.equal(application.currentOverlay, application.infoOverlay);
    assert.equal(application.infoOverlay.visible, true);
    assert.equal(application.infoOverlay.text, 'WebRTC Connection Negotiated');
    assert.equal(application.infoOverlay.showCount, 3);
});

test('current-generation presented-frame evidence clears progress and latches it off', () => {
    const application = createApplication();

    application.onWebRtcSdp();
    application.onMediaPresented();
    application.onWebRtcConnecting();
    application.onWebRtcConnected();
    application.onWebRtcSdp();

    assert.equal(application.currentOverlay, null);
    assert.equal(application.infoOverlay.visible, false);
    assert.equal(application.infoOverlay.showCount, 1);
});

test('a repeated current-generation media proof clears a progress overlay repainted by late ordering', () => {
    const application = createApplication();

    application.onMediaPresented();
    // Simulate an out-of-order callback clearing the UI latch without a new transport generation.
    application.hasPresentedMediaForCurrentConnection = false;
    application.onWebRtcSdp();
    assert.equal(application.infoOverlay.visible, true);

    application.onMediaPresented();

    assert.equal(application.currentOverlay, null);
    assert.equal(application.infoOverlay.visible, false);
});

test('presented-frame evidence repairs a visible progress overlay with stale bookkeeping', () => {
    const application = createApplication();

    application.infoOverlay.show();
    application.currentOverlay = null;
    application.isConnectionProgressOverlayActive = true;
    application.onMediaPresented();

    assert.equal(application.currentOverlay, null);
    assert.equal(application.infoOverlay.visible, false);
});

test('repeated media proof preserves a later generic informational overlay', () => {
    const application = createApplication();

    application.onWebRtcSdp();
    application.onMediaPresented();
    application.showTextOverlay('Waiting for a streamer to become available.');
    application.onMediaPresented();

    assert.equal(application.currentOverlay, application.infoOverlay);
    assert.equal(application.infoOverlay.visible, true);
    assert.equal(application.infoOverlay.text, 'Waiting for a streamer to become available.');
});

test('disconnect plus reconnect resets the media latch for the next connection', () => {
    const application = createApplication();

    application.onMediaPresented();
    application.onDisconnect('transport lost', true);
    assert.equal(application.currentOverlay, application.disconnectOverlay);

    application.onWebRtcAutoConnect();
    application.onWebRtcSdp();

    assert.equal(application.currentOverlay, application.infoOverlay);
    assert.equal(application.infoOverlay.visible, true);
    assert.equal(application.infoOverlay.text, 'WebRTC Connection Negotiated');
});

test('late progress does not replace autoplay or playback error overlays', () => {
    const rejectedApplication = createApplication();
    rejectedApplication.onPlayStreamRejected(new Error('autoplay rejected'));
    rejectedApplication.onMediaPresented();
    rejectedApplication.onWebRtcSdp();
    assert.equal(rejectedApplication.currentOverlay, rejectedApplication.playOverlay);

    const failedApplication = createApplication();
    failedApplication.onPlayStreamError('decoder error');
    failedApplication.onMediaPresented();
    failedApplication.onWebRtcConnected();
    assert.equal(failedApplication.currentOverlay, failedApplication.errorOverlay);
    assert.equal(failedApplication.errorOverlay.text, 'decoder error');
});
