import type { RecordingFileHandle } from './localRecording';
import type { Mp4Destination } from './mp4Conversion';

export interface RecordingFolder {
    name: string;
    getFileHandle(name: string, options?: { create?: boolean }): Promise<RecordingFileHandle & Mp4Destination>;
}
export interface Mp4ExportSnapshot {
    phase: 'idle' | 'converting' | 'saved' | 'cancelled' | 'error';
    percent: number;
    filename: string;
    message: string;
}
type ExportWorker = Pick<Worker, 'postMessage' | 'terminate' | 'onmessage' | 'onerror' | 'onmessageerror'>;

/** Holds only local file handles. Exports are deliberately separate from capture
 * analytics: a converted copy is not a second captured video. */
export class Mp4ExportController {
    private state: Mp4ExportSnapshot = { phase: 'idle', percent: 0, filename: '', message: '' };
    private worker: ExportWorker | null = null;
    private generation = 0;
    private resolve: (() => void) | null = null;
    private timer?: ReturnType<typeof setTimeout>;
    private saved: RecordingFileHandle | null = null;
    private completed: Promise<void> = Promise.resolve();
    private cancelling = false;
    constructor(private onChange: () => void, private createWorker: () => ExportWorker = () =>
        new Worker(new URL('./mp4Export.worker.ts', import.meta.url), { type: 'module', name: 'local-mp4-export' })) {}
    get snapshot(): Mp4ExportSnapshot { return { ...this.state }; }
    get busy(): boolean { return this.state.phase === 'converting'; }
    get savedFile(): RecordingFileHandle | null { return this.saved; }
    wait(): Promise<void> { return this.completed; }
    reset(): void {
        if (this.busy) return;
        this.saved = null;
        this.update({ phase: 'idle', percent: 0, filename: '', message: '' });
    }
    private update(patch: Partial<Mp4ExportSnapshot>): void {
        this.state = { ...this.state, ...patch };
        this.onChange();
    }
    private finish(phase: Mp4ExportSnapshot['phase'], message: string): void {
        clearTimeout(this.timer);
        this.worker?.terminate(); this.worker = null;
        const resolve = this.resolve; this.resolve = null;
        this.update({ phase, message, ...(phase === 'saved' ? { percent: 100 } : {}) });
        resolve?.();
    }
    private watchdog(): void {
        clearTimeout(this.timer);
        this.timer = setTimeout(() => {
            this.cancel('MP4 conversion stopped responding. Your original recording is saved; you can retry.');
        }, 180_000);
    }
    start(source: RecordingFileHandle, folder: RecordingFolder): Promise<void> {
        if (this.busy) return this.completed;
        const generation = ++this.generation;
        this.cancelling = false;
        this.saved = null;
        this.completed = new Promise(resolve => { this.resolve = resolve; });
        const filename = source.name.replace(/\.(webm|mkv)$/i, '') + '.mp4';
        this.update({ phase: 'converting', percent: 0, filename, message: 'Preparing MP4… Keep this tab open.' });
        this.watchdog();
        void (async () => {
            try {
                if (!source.getFile) throw new Error('Missing saved recording');
                const file = await source.getFile();
                // Never silently overwrite a pre-existing MP4 during automatic export.
                let existing = false;
                try { await folder.getFileHandle(filename); existing = true; }
                catch (error) { if ((error as DOMException).name !== 'NotFoundError') throw error; }
                if (generation !== this.generation) return;
                const outputName = existing ? filename.replace(/\.mp4$/, `-${crypto.randomUUID()}.mp4`) : filename;
                const destination = await folder.getFileHandle(outputName, { create: true });
                if (generation !== this.generation) return;
                this.update({ filename: outputName });
                const worker = this.createWorker(); this.worker = worker;
                worker.onmessage = event => {
                    if (generation !== this.generation || !this.busy) return;
                    const data = event.data;
                    if (data.type === 'progress') {
                        if (this.cancelling) return;
                        this.watchdog();
                        this.update({ percent: Math.min(99, Math.max(0, data.percent)), message: `Preparing MP4… ${Math.min(99, Math.max(0, data.percent))}%` });
                    } else if (data.type === 'saved') {
                        this.saved = destination;
                        this.finish('saved', 'Your video is now ready.');
                    } else if (data.type === 'cancelled') this.finish('cancelled', 'Conversion cancelled. Your original recording is saved.');
                    else if (data.type === 'error') this.finish('error', 'MP4 conversion failed or this browser cannot encode H.264/AAC. Your original recording is saved.');
                };
                worker.onerror = () => { if (generation === this.generation && this.busy) this.finish('error', 'MP4 conversion failed. Your original recording is saved.'); };
                worker.onmessageerror = () => { if (generation === this.generation && this.busy) this.finish('error', 'Could not start local conversion. Your original recording is saved.'); };
                worker.postMessage({ type: 'start', file, destination });
            } catch {
                if (generation === this.generation) this.finish('error', 'Could not export MP4. Check folder access and free disk space. Your original recording is saved.');
            }
        })();
        return this.completed;
    }
    cancel(message = 'Conversion cancelled. Your original recording is saved.'): void {
        if (!this.busy) return;
        if (this.cancelling) return;
        this.cancelling = true;
        if (this.worker) {
            try { this.worker.postMessage({ type: 'cancel' }); }
            catch { ++this.generation; this.finish('cancelled', message); return; }
            clearTimeout(this.timer);
            this.timer = setTimeout(() => { ++this.generation; this.finish('cancelled', message); }, 5000);
        } else { ++this.generation; this.finish('cancelled', message); }
    }
    dispose(): void {
        ++this.generation;
        try { this.worker?.postMessage({ type: 'cancel' }); } catch { /* Worker may already have stopped. */ }
        this.finish('cancelled', 'Conversion cancelled. Your original recording is saved.');
    }
}
