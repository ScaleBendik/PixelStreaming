import type { RecordingFileHandle } from './localRecording';
import type { Mp4Destination } from './mp4Conversion';

export interface RecordingFolder {
    name: string;
    getFileHandle(name: string, options?: { create?: boolean }): Promise<RecordingFileHandle & Mp4Destination>;
    removeEntry?(name: string): Promise<void>;
}
const createdFiles = new WeakMap<RecordingFileHandle, RecordingFolder>();

export async function createRecordingFile(folder: RecordingFolder, suggestedName: string): Promise<RecordingFileHandle & Mp4Destination> {
    let name = suggestedName;
    for (let attempt = 0; attempt < 5; attempt++) {
        try { await folder.getFileHandle(name); }
        catch (error) {
            if ((error as DOMException).name !== 'NotFoundError') throw error;
            const file = await folder.getFileHandle(name, { create: true });
            createdFiles.set(file, folder);
            return file;
        }
        name = suggestedName.replace(/(\.[^.]+)$/, `-${crypto.randomUUID()}$1`);
    }
    throw new Error('Could not choose a unique output filename');
}

export async function discardEmptyRecordingFile(file: RecordingFileHandle): Promise<void> {
    const folder = createdFiles.get(file);
    if (!folder?.removeEntry || !file.isSameEntry || !file.getFile) return;
    try {
        const current = await folder.getFileHandle(file.name);
        if (!await file.isSameEntry(current) || (await file.getFile()).size !== 0) return;
        await folder.removeEntry(file.name);
        createdFiles.delete(file);
    } catch { /* Preserve entries when identity, permissions or open writers prevent safe cleanup. */ }
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
    private destination: RecordingFileHandle | null = null;
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
        const destination = this.destination; this.destination = null;
        this.update({ phase, message, ...(phase === 'saved' ? { percent: 100 } : {}) });
        if (destination && phase !== 'saved') {
            // Keep completion bounded even when a removable drive stops responding.
            let timer: ReturnType<typeof setTimeout>;
            void Promise.race([discardEmptyRecordingFile(destination), new Promise<void>(done => { timer = setTimeout(done, 2000); })])
                .finally(() => { clearTimeout(timer); resolve?.(); });
        } else resolve?.();
    }
    private watchdog(): void {
        clearTimeout(this.timer);
        this.timer = setTimeout(() => {
            this.cancel('MP4 conversion stopped responding. Your original recording is saved; you can retry.');
        }, 180_000);
    }
    start(source: RecordingFileHandle, target: RecordingFolder | (RecordingFileHandle & Mp4Destination)): Promise<void> {
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
                if (generation !== this.generation) return;
                // Never silently overwrite a pre-existing MP4 during automatic export.
                let destination: RecordingFileHandle & Mp4Destination;
                if ('getFileHandle' in target) {
                    destination = await createRecordingFile(target, filename);
                } else {
                    destination = target;
                    // Save pickers can return the source itself if a user changes
                    // the suggested filename. Never overwrite the original clip.
                    const handle = source as RecordingFileHandle & { isSameEntry?(other: RecordingFileHandle): Promise<boolean> };
                    if (source === destination || await handle.isSameEntry?.(destination)) throw new Error('Source and destination are identical');
                }
                if (generation !== this.generation) { void discardEmptyRecordingFile(destination); return; }
                this.destination = destination;
                this.update({ filename: destination.name });
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
                        this.finish('saved', 'MP4 saved. Your video is now ready. The original recording is kept unchanged.');
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
