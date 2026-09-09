import { WebRtcPlayerController } from './WebRtcPlayerController';
import { AggregatedStats } from '../PeerConnectionController/AggregatedStats';

test('reports the first decoded codec and changes, while continuing ordinary stats delivery', () => {
    const send = jest.fn();
    const onStats = jest.fn();
    const controller = Object.assign(Object.create(WebRtcPlayerController.prototype), {
        config: { scaleWorldCodecPolicy: { selectedCodec: 'VP9', availableCodecs: ['VP9'] } },
        codecMediaGeneration: 0,
        sendSignallingMessage: send,
        pixelStreaming: { _onVideoStats: onStats }
    }) as WebRtcPlayerController;
    const stats = (codec: string, frames: number) => ({
        inboundVideoStats: { codecId: 'video', framesDecoded: frames, bytesReceived: frames * 1000 },
        codecs: new Map([['video', { mimeType: `video/${codec}` }]])
    }) as unknown as AggregatedStats;
    controller.handleVideoStats(stats('VP9', 0));
    expect(send).not.toHaveBeenCalled();
    for (let i = 1; i <= 720; i++) controller.handleVideoStats(stats('VP9', i));
    expect(send).toHaveBeenCalledTimes(1);
    controller.handleVideoStats(stats('H264', 721));
    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[1][0].codec).toBe('H264');
    expect(onStats).toHaveBeenCalledTimes(722);
});
