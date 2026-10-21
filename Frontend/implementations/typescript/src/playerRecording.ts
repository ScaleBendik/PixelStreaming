import type { PixelStreaming } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8';
import type { RecordingSource } from './localRecording';
import { installRecordingControl } from './recordingControl';

/** Record media already admitted by Wilbur; local recording has no commercial tier gate. */
export function installPlayerRecording(options: {
    stream: PixelStreaming;
    controls: HTMLElement;
    modalParent: HTMLElement;
    setModalInput: (open: boolean) => void;
}) {
    const { stream } = options;
    let observedConnection: RTCPeerConnection | null = null;
    let watchedConnection: RTCPeerConnection | null = null;
    let observedCodec = '';
    let disconnected = false;
    let disposed = false;
    const connection = () => stream.webRtcController.peerConnectionController?.peerConnection ?? null;
    const getSource = (): RecordingSource | null => {
        const controller = stream.webRtcController.peerConnectionController;
        const peer = controller?.peerConnection;
        if (disposed || disconnected || !peer || !controller.videoTrack ||
            observedConnection !== peer || controller.videoTrack.readyState !== 'live' ||
            !['connected', 'completed'].includes(peer.iceConnectionState)) return null;
        return {
            connection: peer,
            videoTrack: controller.videoTrack,
            audioTrack: controller.audioTrack?.readyState === 'live' ? controller.audioTrack : undefined,
            codec: observedCodec,
            eligible: true
        };
    };
    const beforeRecord = async () => {
        const source = getSource();
        if (!source?.audioTrack) return;
        const player = stream.webRtcController;
        const sinks = [player.streamController.audioElement, player.videoPlayer.getVideoElement()];
        const sink = sinks.find(element =>
            (element.srcObject as MediaStream | null)?.getAudioTracks?.().includes(source.audioTrack!));
        if (!sink) throw new Error('Audio is not ready. Start session playback, then try recording again.');
        // Chromium must pull the received audio to produce recorder chunks.
        // Call play within the Record gesture; preserve the user's mute/volume.
        if (sink.paused) {
            try { await sink.play(); }
            catch { throw new Error('Could not start session audio. Resume playback, then try recording again.'); }
        }
    };
    const control = installRecordingControl({ ...options, getSource, beforeRecord });
    const refresh = () => { if (!disposed) control.refresh(); };
    const watchConnection = () => {
        const peer = connection();
        if (watchedConnection === peer) return;
        watchedConnection?.removeEventListener('connectionstatechange', refresh);
        watchedConnection?.removeEventListener('iceconnectionstatechange', refresh);
        watchedConnection?.removeEventListener('track', refresh);
        watchedConnection = peer;
        peer?.addEventListener('connectionstatechange', refresh);
        peer?.addEventListener('iceconnectionstatechange', refresh);
        peer?.addEventListener('track', refresh);
    };
    const reset = () => {
        observedConnection = null;
        observedCodec = '';
        watchConnection();
        refresh();
    };
    const connected = () => { disconnected = false; watchConnection(); refresh(); };
    const disconnect = () => { disconnected = true; reset(); };
    const onStats = (event: { data: { aggregatedStats: {
        inboundVideoStats: { codecId: string; framesDecoded: number; bytesReceived: number };
        codecs: Map<string, { mimeType: string }>;
    } } }) => {
        const stats = event.data.aggregatedStats;
        const inbound = stats.inboundVideoStats;
        // The library fences stats callbacks by peer generation before emitting this event.
        observedConnection = connection();
        observedCodec = inbound.framesDecoded > 0 && inbound.bytesReceived > 0
            ? stats.codecs.get(inbound.codecId)?.mimeType?.replace(/^video\//i, '').toUpperCase() ?? ''
            : '';
        watchConnection();
        refresh();
    };
    stream.addEventListener('statsReceived', onStats);
    stream.addEventListener('webRtcConnecting', reset);
    stream.addEventListener('webRtcConnected', connected);
    stream.addEventListener('webRtcDisconnected', disconnect);
    stream.addEventListener('webRtcFailed', disconnect);
    stream.signallingProtocol.transport.addListener('open', reset);
    watchConnection();
    return {
        beforeLeave: () => control.beforeLeave(),
        dispose: () => {
            disposed = true;
            stream.removeEventListener('statsReceived', onStats);
            stream.removeEventListener('webRtcConnecting', reset);
            stream.removeEventListener('webRtcConnected', connected);
            stream.removeEventListener('webRtcDisconnected', disconnect);
            stream.removeEventListener('webRtcFailed', disconnect);
            stream.signallingProtocol.transport.removeListener('open', reset);
            watchedConnection?.removeEventListener('connectionstatechange', refresh);
            watchedConnection?.removeEventListener('iceconnectionstatechange', refresh);
            watchedConnection?.removeEventListener('track', refresh);
            control.dispose();
        }
    };
}
