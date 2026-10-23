import { convertRecordingToMp4, Mp4Destination } from './mp4Conversion';

const scope = globalThis as unknown as {
    onmessage: ((event: MessageEvent<{ type: 'start' | 'cancel'; file: File; destination: Mp4Destination }>) => void) | null;
    postMessage(message: unknown): void;
};
let active: AbortController | undefined;
scope.onmessage = event => {
    if (event.data.type === 'cancel') { active?.abort(); return; }
    if (active || event.data.type !== 'start') return;
    active = new AbortController();
    let lastProgress = -1;
    let lastUpdate = 0;
    void convertRecordingToMp4(event.data.file, event.data.destination, active.signal, (fraction, bytes) => {
        const percent = Math.floor(fraction * 100);
        if (percent === lastProgress && performance.now() - lastUpdate < 1000) return;
        lastProgress = percent;
        lastUpdate = performance.now();
        scope.postMessage({ type: 'progress', percent, bytes });
    }).then(result => scope.postMessage({ type: 'saved', ...result })).catch(() => {
        scope.postMessage({ type: active?.signal.aborted ? 'cancelled' : 'error' });
    });
};
