import type { PixelStreaming } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8';

export function recoveryMessage(kind: unknown, phase: unknown): string {
    const description = kind === 'unexpected_exit'
        ? 'ScaleWorld stopped unexpectedly.'
        : kind === 'unresponsive' ? 'The ScaleWorld stream stopped responding.'
            : kind === 'media_stalled' ? 'Video has stopped arriving from ScaleWorld.' : 'The stream is taking longer than expected.';
    const action = phase === 'restart_requested' ? ' Automatic recovery is being attempted.'
        : phase === 'restart_failed' ? ' The recovery attempt could not start.' : '';
    return description + action + ' If it does not return within a couple of minutes, end your session in the session manager and start a new one.';
}

/** Informational only: browser silence never authorizes a server restart or declares a crash. */
export function installRuntimeRecovery(stream: PixelStreaming, managerUrl: string | null) {
    let disposed = false;
    let enabled = true;
    let lastFrame = Date.now();
    let receivedFrame = false;
    let intentionalFreeze = false;
    let generation = 0;
    let overlay: HTMLDivElement | undefined;
    let frame: { video: HTMLVideoElement; id: number } | undefined;
    let pending = false;
    let notice: { kind?: unknown; phase?: unknown } | null = null;
    let fallbackSource: HTMLVideoElement['srcObject'] = null;
    let fallbackFrames = 0;
    const hide = () => { overlay?.remove(); overlay = undefined; };
    const clearFrame = () => {
        generation++;
        if (frame) frame.video.cancelVideoFrameCallback?.(frame.id);
        frame = undefined;
    };
    const watchFrames = () => {
        clearFrame();
        const ownGeneration = generation;
        const video = stream.webRtcController.videoPlayer.getVideoElement();
        const source = video.srcObject;
        if (!source || !video.requestVideoFrameCallback) return;
        const presented = () => {
            if (disposed || ownGeneration !== generation || video.srcObject !== source) return;
            lastFrame = Date.now();
            receivedFrame = true;
            hide();
            frame = { video, id: video.requestVideoFrameCallback(presented) };
        };
        frame = { video, id: video.requestVideoFrameCallback(presented) };
    };
    const reset = () => {
        enabled = true; lastFrame = Date.now(); receivedFrame = false; intentionalFreeze = false; notice = null; hide(); clearFrame();
    };
    const cancel = () => { enabled = false; hide(); clearFrame(); };
    const show = (message: string) => {
        if (overlay?.dataset['message'] === message) return;
        hide();
        overlay = document.createElement('div');
        overlay.dataset['message'] = message;
        overlay.setAttribute('role', 'status');
        overlay.setAttribute('aria-live', 'polite');
        overlay.style.cssText = 'position:absolute;inset:0;z-index:10001;display:flex;flex-direction:column;' +
            'align-items:center;justify-content:center;gap:20px;padding:32px;background:rgba(0,0,0,.88);' +
            'color:white;font:18px/1.5 sans-serif;text-align:center;text-transform:none';
        const text = document.createElement('p');
        text.textContent = message;
        text.style.cssText = 'max-width:620px;margin:0';
        overlay.appendChild(text);
        const retry = document.createElement('button');
        retry.textContent = 'Retry connection';
        retry.style.cssText = 'padding:12px 20px;font:inherit;cursor:pointer';
        retry.addEventListener('click', () => stream.reconnect());
        overlay.appendChild(retry);
        if (managerUrl) {
            const link = document.createElement('a');
            link.href = managerUrl; link.textContent = 'Open session manager'; link.style.color = '#65cfff';
            overlay.appendChild(link);
        }
        stream.videoElementParent.appendChild(overlay);
    };
    const tick = async () => {
        if (disposed || !enabled || document.hidden || pending) return;
        const ownGeneration = generation;
        pending = true;
        try {
            const response = await fetch('/api/runtime-recovery', { cache: 'no-store', signal: AbortSignal.timeout(2_000) });
            if (response.ok) {
                const result = await response.json();
                if (ownGeneration === generation) notice = result.recovery;
            }
        } catch { /* Old/unreachable runtimes still get the local, unconfirmed interruption notice. */ }
        finally { pending = false; }
        if (disposed || !enabled || document.hidden || ownGeneration !== generation) return;
        const video = stream.webRtcController.videoPlayer.getVideoElement();
        if (!video.requestVideoFrameCallback && video.getVideoPlaybackQuality) {
            const frames = video.getVideoPlaybackQuality().totalVideoFrames;
            if (video.srcObject !== fallbackSource) { fallbackSource = video.srcObject; fallbackFrames = frames; }
            else if (frames > fallbackFrames) { lastFrame = Date.now(); receivedFrame = true; hide(); }
            fallbackFrames = frames;
        }
        const confirmed = notice?.kind === 'unexpected_exit' || notice?.kind === 'unresponsive';
        // FreezeFrame and click-to-play deliberately stop presentation. Only an
        // independent watchdog fault should override those normal player states.
        if (!confirmed && (intentionalFreeze || (video.srcObject && video.paused))) {
            lastFrame = Date.now(); hide(); return;
        }
        const silentMs = Date.now() - lastFrame;
        if (silentMs >= (confirmed ? 3_000 : 20_000)) show(recoveryMessage(confirmed ? notice?.kind : receivedFrame ? 'media_stalled' : null, notice?.phase));
    };
    const freeze = ({ data }: { data: { isValid: boolean; shouldShowPlayOverlay: boolean } }) => {
        intentionalFreeze = data.isValid && !data.shouldShowPlayOverlay;
        if (intentionalFreeze) { lastFrame = Date.now(); hide(); }
    };
    const unfreeze = () => { intentionalFreeze = false; lastFrame = Date.now(); watchFrames(); };
    const visible = () => { if (!document.hidden) { lastFrame = Date.now(); watchFrames(); } };
    stream.addEventListener('videoInitialized', watchFrames);
    stream.addEventListener('loadFreezeFrame', freeze);
    stream.addEventListener('hideFreezeFrame', unfreeze);
    stream.signallingProtocol.transport.addListener('open', reset);
    document.addEventListener('visibilitychange', visible);
    const timer = setInterval(() => { void tick(); }, 3_000);
    watchFrames();
    return { cancel, dispose: () => {
        disposed = true; cancel(); clearInterval(timer);
        stream.removeEventListener('videoInitialized', watchFrames);
        stream.removeEventListener('loadFreezeFrame', freeze);
        stream.removeEventListener('hideFreezeFrame', unfreeze);
        stream.signallingProtocol.transport.removeListener('open', reset);
        document.removeEventListener('visibilitychange', visible);
    } };
}
