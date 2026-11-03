import { Config } from '../Config/Config';
import { PixelStreaming } from '../PixelStreaming/PixelStreaming';
import { BaseMessage, MessageHelpers, Messages } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';
import { mockRTCRtpReceiver, unmockRTCRtpReceiver } from '../__test__/mockRTCRtpReceiver';
import { mockWebSocket, unmockWebSocket } from '../__test__/mockWebSocket';
import { mockRTCPeerConnection, unmockRTCPeerConnection } from '../__test__/mockRTCPeerConnection';
import { mockHTMLMediaElement, mockMediaStream, unmockMediaStream } from '../__test__/mockMediaStream';

beforeEach(() => {
    jest.useFakeTimers();
    mockRTCRtpReceiver();
    mockMediaStream();
    mockHTMLMediaElement({ ableToPlay: true });
});
afterEach(() => {
    unmockRTCRtpReceiver();
    unmockMediaStream();
    unmockWebSocket();
    unmockRTCPeerConnection();
    jest.clearAllTimers();
    jest.useRealTimers();
    jest.restoreAllMocks();
});

function fixture(redundant = true) {
    const [, socket] = mockWebSocket();
    const [, rtc] = mockRTCPeerConnection();
    const player = new PixelStreaming(new Config({ initialSettings: { ss: 'ws://localhost:24680/', AutoConnect: true } }));
    const send = jest.spyOn(player.webRtcController.protocol, 'sendMessage').mockImplementation(() => {});
    socket.triggerOnOpen?.();
    socket.triggerOnMessage?.({ type: 'config',
        peerConnectionOptions: { iceServers: [{ urls: [
            'turn:primary.test:3478?transport=udp',
            redundant ? 'turn:fallback.test:3478?transport=udp' : 'turns:primary.test:443?transport=tcp'
        ] }] }
    } as BaseMessage);
    socket.triggerOnMessage?.(MessageHelpers.createMessage(Messages.streamerList, { ids: ['streamer'] }));
    const state = (generation: number) => socket.triggerOnMessage?.({
        type: 'scaleWorldCodecState', selectedCodec: 'H264', availableCodecs: ['H264'],
        mediaGeneration: generation, status: generation ? 'restarting' : 'negotiating'
    } as BaseMessage);
    state(0);
    expect(player.webRtcController).toMatchObject({ enableAutoReconnect: true, activeSubscribedStreamerId: 'streamer' });
    expect(player.webRtcController.peerConfig.iceServers).toHaveLength(1);
    send.mockClear();
    return { player, send, state, ice: (value: RTCIceConnectionState) => rtc.triggerIceConnectionStateChange?.(value) };
}

test('redundant ICE failure retries the authenticated subscription twice, with generation fencing', () => {
    const h = fixture();
    const retired = h.player.webRtcController.peerConnectionController;
    h.ice('failed'); h.ice('failed');
    expect(h.send).toHaveBeenCalledTimes(1);
    expect(h.send).toHaveBeenLastCalledWith(expect.objectContaining({ type: 'subscribe', streamerId: 'streamer' }));
    h.state(1);
    retired.onIceConnectionStateChange(new Event('iceconnectionstatechange'));
    expect(h.send).toHaveBeenCalledTimes(1);
    h.ice('failed');
    expect(h.send).toHaveBeenCalledTimes(2);
    h.state(2); h.ice('failed');
    expect(h.send).toHaveBeenCalledTimes(2);
    expect(h.player.webRtcController.protocol.isConnected()).toBe(true);
    h.player.disconnect();
});

test('transient disconnection recovers without retry; sustained loss retries and end cancels queued recovery', () => {
    const h = fixture();
    h.ice('disconnected'); jest.advanceTimersByTime(9_000); h.ice('connected');
    jest.advanceTimersByTime(2_000);
    expect(h.send).not.toHaveBeenCalled();
    h.ice('disconnected'); jest.advanceTimersByTime(10_000);
    expect(h.send).toHaveBeenCalledTimes(1);
    h.state(1); h.ice('disconnected'); h.player.disconnect();
    h.send.mockClear(); jest.advanceTimersByTime(15_000);
    expect(h.send).not.toHaveBeenCalled();
});

test('multiple transports on one relay do not enable automatic TURN recovery', () => {
    const h = fixture(false);
    h.ice('failed'); h.ice('disconnected'); jest.advanceTimersByTime(15_000);
    expect(h.send).not.toHaveBeenCalled();
    h.player.disconnect();
});
