import type { PixelStreaming } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8';

type Resolution = { width: number; height: number };
const RECOVERY_TIMEOUT_MS = 30_000;

/** Blueprint responses are notifications, never session or authorization authority. */
export function parseResolutionApplied(response: string): Resolution | null {
    if (response.length > 512) return null;
    try {
        const value = JSON.parse(response);
        if (!value || value.type !== 'resolutionApplied' ||
            !Number.isInteger(value.width) || !Number.isInteger(value.height) ||
            value.width < 1 || value.height < 1 || value.width > 8192 || value.height > 8192) {
            return null;
        }
        return { width: value.width, height: value.height };
    } catch { return null; }
}

/** One ordinary reconnect; success requires a presented frame from the replacement video source. */
export function installResolutionRecovery(stream: PixelStreaming, onResolutionApplied: () => void = () => {}): { cancel: () => void; dispose: () => void } {
    let target: Resolution | null = null;
    let completed: Resolution | null = null;
    let waiting = false;
    let generation = 0;
    let connected = false;
    let replacementSource: HTMLVideoElement['srcObject'] = null;
    let oldSource: HTMLVideoElement['srcObject'] = null;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let frame: { video: HTMLVideoElement; id: number } | undefined;
    let overlay: HTMLDivElement | undefined;
    let disposed = false;
    const video = () => stream.webRtcController.videoPlayer.getVideoElement();
    const clearFrame = () => {
        if (frame) frame.video.cancelVideoFrameCallback?.(frame.id);
        frame = undefined;
    };
    const clearWait = () => {
        clearTimeout(timer);
        timer = undefined;
        clearFrame();
        waiting = false;
        generation++;
    };
    const removeOverlay = () => { overlay?.remove(); overlay = undefined; };
    const cancel = () => { clearWait(); target = null; removeOverlay(); };
    const show = (failed: boolean) => {
        removeOverlay();
        overlay = document.createElement('div');
        overlay.setAttribute('role', 'status');
        overlay.setAttribute('aria-live', 'polite');
        overlay.style.cssText = 'position:fixed;inset:0;z-index:10000;display:flex;flex-direction:column;' +
            'align-items:center;justify-content:center;gap:16px;background:rgba(0,0,0,.85);color:white;' +
            'font:18px sans-serif;text-align:center;padding:24px';
        const text = document.createElement('p');
        text.textContent = failed
            ? 'The stream did not return at the requested resolution. Retry, or return to the session manager.'
            : 'Applying resolution…';
        overlay.appendChild(text);
        if (failed) {
            const retry = document.createElement('button');
            retry.textContent = 'Retry connection';
            retry.style.cssText = 'padding:12px 20px;font:inherit;cursor:pointer';
            retry.addEventListener('click', () => { if (target && !disposed) begin(target); });
            overlay.appendChild(retry);
        }
        document.body.appendChild(overlay);
    };
    const fail = () => { clearWait(); if (target && !disposed) show(true); };
    const armFrame = () => {
        if (!waiting || !connected || !replacementSource || frame) return;
        const currentVideo = video();
        if (currentVideo.srcObject !== replacementSource ||
            typeof currentVideo.requestVideoFrameCallback !== 'function') return;
        const capturedGeneration = generation;
        const capturedSource = replacementSource;
        const id = currentVideo.requestVideoFrameCallback((_now, metadata) => {
            if (capturedGeneration !== generation || !waiting ||
                currentVideo.srcObject !== capturedSource) return;
            frame = undefined;
            if (target && metadata.width === target.width && metadata.height === target.height) {
                completed = target;
                cancel();
                return;
            }
            armFrame();
        });
        frame = { video: currentVideo, id };
    };
    function begin(resolution: Resolution) {
        clearWait();
        target = resolution;
        waiting = true;
        connected = false;
        replacementSource = null;
        oldSource = video().srcObject;
        show(false);
        timer = setTimeout(fail, RECOVERY_TIMEOUT_MS);
        try { stream.reconnect(); } catch { fail(); }
    }
    const onResponse = (response: string) => {
        const resolution = parseResolutionApplied(response);
        if (!resolution || disposed) return;
        onResolutionApplied();
        if (waiting) {
            // Rapid Blueprint notifications coalesce into the latest dimensions without another viewer.
            target = resolution;
            return;
        }
        if (target) return; // Failed operations require an explicit Retry, not message-driven loops.
        if (completed?.width === resolution.width && completed?.height === resolution.height &&
            video().videoWidth === resolution.width && video().videoHeight === resolution.height) return;
        begin(resolution);
    };
    const onDisconnected = () => {
        connected = false;
        replacementSource = null;
        clearFrame();
        generation++;
    };
    const onConnected = () => { connected = true; armFrame(); };
    const onVideo = () => {
        const source = video().srcObject;
        if (!waiting || !source || source === oldSource) return;
        clearFrame();
        generation++;
        replacementSource = source;
        armFrame();
    };
    stream.addResponseEventListener('scaleWorldResolutionRecovery', onResponse);
    stream.addEventListener('webRtcDisconnected', onDisconnected);
    stream.addEventListener('webRtcConnected', onConnected);
    stream.addEventListener('videoInitialized', onVideo);
    return {
        cancel,
        dispose: () => {
            disposed = true;
            cancel();
            stream.removeResponseEventListener('scaleWorldResolutionRecovery');
            stream.removeEventListener('webRtcDisconnected', onDisconnected);
            stream.removeEventListener('webRtcConnected', onConnected);
            stream.removeEventListener('videoInitialized', onVideo);
        }
    };
}
