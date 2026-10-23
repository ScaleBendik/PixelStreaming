// Copyright Epic Games, Inc. All Rights Reserved.
import { SeekableRecordingWriter } from './seekableRecording';

export interface RecordingSource {
    connection: object;
    videoTrack: MediaStreamTrack;
    audioTrack?: MediaStreamTrack;
    codec: string;
    eligible: boolean;
}

export interface RecordingSnapshot {
    phase: 'idle' | 'choosing' | 'ready' | 'starting' | 'recording' | 'saving' | 'saved' | 'error';
    filename: string;
    bytesWritten: number;
    startedAt: number | null;
    message: string;
}

export interface RecordingSupport {
    supported: boolean;
    reason: string;
}

export interface RecordingFormat {
    codec: 'AV1' | 'VP9' | 'H264';
    mimeType: 'video/webm' | 'video/x-matroska';
    extension: '.webm' | '.mkv';
    description: string;
}

export type RecordingFailureCode = 'file_open_failed' | 'recorder_start_failed' | 'recorder_failed' |
    'start_timeout' | 'format_mismatch' | 'write_backpressure' | 'write_failed' | 'stop_timeout' |
    'stop_failed' | 'write_timeout' | 'empty_recording' | 'file_close_failed';

/** Optional metadata only. Never exposes the filename, path, media or error text. */
export interface RecordingLifecycleEvent {
    eventType: 'recording_started' | 'recording_saved' | 'recording_failed';
    occurredAtUtc: string;
    codec: RecordingFormat['codec'];
    container: 'webm' | 'matroska';
    bytesWritten: number;
    durationMs: number;
    failureCode?: RecordingFailureCode;
}

// A separate observer for each attempt freezes its identity before asynchronous file I/O.
export type RecordingObserverFactory = () => ((event: RecordingLifecycleEvent) => void | Promise<void>) | undefined;

export function getRecordingFormat(codec: string): RecordingFormat | null {
    const name = codec.trim().replace(/^video\//i, '').split(/[.;]/)[0].toLowerCase();
    if (name === 'av1' || name === 'av01') {
        return { codec: 'AV1', mimeType: 'video/webm', extension: '.webm', description: 'WebM video' };
    }
    if (name === 'vp9' || name === 'vp09') {
        return { codec: 'VP9', mimeType: 'video/webm', extension: '.webm', description: 'WebM video' };
    }
    if (name === 'h264' || name === 'avc1' || name === 'avc3') {
        return { codec: 'H264', mimeType: 'video/x-matroska', extension: '.mkv', description: 'Matroska video' };
    }
    return null;
}

// These deliberately narrow types also work with TypeScript DOM versions that
// do not yet declare the File System Access API.
export interface RecordingFileWriter {
    readonly bytesWritten?: number;
    write(data: Blob): Promise<void>;
    close(): Promise<void>;
    abort(): Promise<void>;
}

export interface RecordingFileHandle {
    name: string;
    createWritable(): Promise<RecordingFileWriter & { seek(position: number): Promise<void> }>;
}

export interface RecordingFilePickerOptions {
    suggestedName: string;
    excludeAcceptAllOption: boolean;
    types: Array<{ description: string; accept: Record<string, string[]> }>;
}

interface RecordingOptions {
    /** Writer factory seam for lifecycle tests; production always indexes the container. */
    createFileWriter?: (file: RecordingFileHandle) => Promise<RecordingFileWriter>;
    getSource: () => RecordingSource | null;
    onState?: (state: RecordingSnapshot) => void;
    getSupport?: () => RecordingSupport;
    pickFile?: (options: RecordingFilePickerOptions) => Promise<RecordingFileHandle>;
    createStream?: (tracks: MediaStreamTrack[]) => MediaStream;
    createRecorder?: (stream: MediaStream) => MediaRecorder;
    now?: () => number;
    elapsedNow?: () => number;
    createObserver?: RecordingObserverFactory;
    maxPendingBytes?: number;
    startTimeoutMs?: number;
    ioTimeoutMs?: number;
}

interface RecordingRun {
    source: RecordingSource;
    format: RecordingFormat;
    writer: RecordingFileWriter | null;
    recorder: MediaRecorder | null;
    recorderStarted: boolean;
    opening: boolean;
    stopRequested: boolean;
    finishing: boolean;
    failure: string | null;
    failureCode?: RecordingFailureCode;
    observer?: ReturnType<RecordingObserverFactory>;
    captureStartedAt: number | null;
    captureStoppedAt: number | null;
    bytesWritten: number;
    receivedData: boolean;
    pendingBytes: number;
    writes: Promise<void>;
    completion: Promise<boolean>;
    complete: (saved: boolean) => void;
    trackEnded: () => void;
    startTimer?: ReturnType<typeof setTimeout>;
    stopTimer?: ReturnType<typeof setTimeout>;
}

export function getRecordingSupport(): RecordingSupport {
    const fail = (reason: string): RecordingSupport => ({ supported: false, reason });
    if (typeof window === 'undefined' || !window.isSecureContext) {
        return fail('Local recording requires a secure HTTPS connection.');
    }
    const agent = navigator.userAgent;
    const version = /Edg\/(\d+)/.exec(agent) || /Chrome\/(\d+)/.exec(agent);
    if (!version || Number(version[1]) < 141 || /Android|iPhone|iPad|iPod|OPR\//.test(agent)) {
        return fail('Use desktop Chrome or Edge version 141 or newer for local recording.');
    }
    const browser = window as Window & { showSaveFilePicker?: unknown };
    if (typeof browser.showSaveFilePicker !== 'function' || typeof MediaRecorder === 'undefined') {
        return fail('This browser does not provide local video recording and file access.');
    }
    return { supported: true, reason: '' };
}

function sourceProblem(source: RecordingSource | null): string | null {
    if (!source?.eligible) return 'Wait for the Unreal video stream before recording.';
    if (source.videoTrack.readyState !== 'live') return 'Wait for the Unreal video stream before recording.';
    if (!getRecordingFormat(source.codec)) {
        return 'Local recording requires an active AV1, VP9 or H264 video stream.';
    }
    return null;
}

function sameSource(first: RecordingSource, second: RecordingSource | null): boolean {
    return !!second && !sourceProblem(second) && first.connection === second.connection &&
        first.videoTrack === second.videoTrack && first.audioTrack === second.audioTrack &&
        getRecordingFormat(first.codec)?.codec === getRecordingFormat(second.codec)?.codec;
}

function matchesFormat(mime: string, expected: RecordingFormat): boolean {
    if (mime.split(';')[0].trim().toLowerCase() !== expected.mimeType) return false;
    const codecs = /(?:^|;)\s*codecs\s*=\s*"?([^";]+)/i.exec(mime)?.[1];
    return !!codecs?.split(',').some(codec => getRecordingFormat(codec)?.codec === expected.codec);
}

/** Records original RTC tracks. Chromium may pass their encoded video through when
 * MIME is unspecified; specifying a codec, cloning through a canvas, or using
 * captureStream() would lose that path. Actual passthrough still needs browser
 * acceptance testing: MediaRecorder exposes no "require passthrough" switch.
 */
export class LocalRecordingController {
    private state: RecordingSnapshot = {
        phase: 'idle', filename: '', bytesWritten: 0, startedAt: null, message: 'Choose a location for your recording.'
    };
    private readonly listeners = new Set<(state: RecordingSnapshot) => void>();
    private file: RecordingFileHandle | null = null;
    private fileFormat: RecordingFormat | null = null;
    private run: RecordingRun | null = null;
    private choice = 0;
    private disposed = false;
    private readonly now: () => number;
    private readonly elapsedNow: () => number;

    constructor(private readonly options: RecordingOptions) {
        this.now = options.now || Date.now;
        this.elapsedNow = options.elapsedNow || (() => performance.now());
        if (options.onState) this.listeners.add(options.onState);
    }

    get snapshot(): RecordingSnapshot { return { ...this.state }; }
    get hasUnsavedData(): boolean { return this.run !== null; }

    subscribe(listener: (state: RecordingSnapshot) => void): () => void {
        this.listeners.add(listener);
        listener(this.snapshot);
        return () => { this.listeners.delete(listener); };
    }

    private update(patch: Partial<RecordingSnapshot>): void {
        this.state = { ...this.state, ...patch };
        for (const listener of this.listeners) {
            // An optional toolbar must not break file finalization.
            try { listener(this.snapshot); } catch { /* Isolate presentation failures. */ }
        }
    }

    async chooseLocation(): Promise<void> {
        if (this.disposed || this.run || this.state.phase === 'choosing') return;
        const support = (this.options.getSupport || getRecordingSupport)();
        const source = this.options.getSource();
        const problem = support.supported ? sourceProblem(source) : support.reason;
        if (problem) { this.update({ phase: 'error', message: problem }); return; }
        const format = getRecordingFormat(source!.codec)!;
        const previous = this.snapshot;
        const choice = ++this.choice;
        this.update({ phase: 'choosing', message: 'Choose a folder and filename.' });
        try {
            const pick = this.options.pickFile || ((options: RecordingFilePickerOptions) => {
                const browser = window as Window & {
                    showSaveFilePicker?: (options: RecordingFilePickerOptions) => Promise<RecordingFileHandle>;
                };
                return browser.showSaveFilePicker!(options);
            });
            const file = await pick({
                suggestedName: `ScaleWorld-${new Date(this.now()).toISOString().replace(/[:.]/g, '-')}${format.extension}`,
                excludeAcceptAllOption: true,
                types: [{ description: format.description, accept: { [format.mimeType]: [format.extension] } }]
            });
            if (choice !== this.choice || this.disposed) return;
            this.file = file;
            this.fileFormat = format;
            this.update({ phase: 'ready', filename: file.name, bytesWritten: 0, startedAt: null, message: 'Ready to record.' });
        } catch (error) {
            if (choice !== this.choice || this.disposed) return;
            if ((error as { name?: string })?.name === 'AbortError') this.update(previous);
            else this.update({ phase: 'error', message: 'Could not choose a recording location. Try again.' });
        }
    }

    async start(): Promise<void> {
        if (this.disposed || this.run || this.state.phase === 'choosing') return;
        const source = this.options.getSource();
        const support = (this.options.getSupport || getRecordingSupport)();
        const problem = support.supported ? sourceProblem(source) : support.reason;
        if (problem || !source || !this.file) {
            this.update({ phase: 'error', message: problem || 'Choose a new recording location first.' });
            return;
        }
        const format = getRecordingFormat(source.codec)!;
        if (this.fileFormat?.codec !== format.codec) {
            this.file = null;
            this.fileFormat = null;
            this.update({ phase: 'error', message: 'The video codec changed. Choose a new recording location for the current format.' });
            return;
        }
        const file = this.file;
        this.file = null; // Every clip requires a new picker confirmation, including failed recordings.
        this.fileFormat = null;
        let complete!: (saved: boolean) => void;
        const completion = new Promise<boolean>(resolve => { complete = resolve; });
        const run: RecordingRun = {
            source: { ...source }, format, writer: null, recorder: null, recorderStarted: false,
            opening: true, stopRequested: false, finishing: false, failure: null,
            captureStartedAt: null, captureStoppedAt: null, bytesWritten: 0,
            receivedData: false, pendingBytes: 0, writes: Promise.resolve(), completion, complete,
            trackEnded: () => { void this.stop('The media track ended. Finishing the recording.'); }
        };
        try { run.observer = this.options.createObserver?.(); } catch { /* Reporting is optional. */ }
        this.run = run;
        source.videoTrack.addEventListener('ended', run.trackEnded);
        source.audioTrack?.addEventListener('ended', run.trackEnded);
        this.update({ phase: 'starting', filename: file.name, bytesWritten: 0, startedAt: null, message: `Waiting for ${format.codec} video…` });
        let opening: Promise<RecordingFileWriter> | undefined;
        try {
            opening = this.options.createFileWriter ? this.options.createFileWriter(file) :
                file.createWritable().then(writer => new SeekableRecordingWriter(writer));
            run.writer = await this.withTimeout(opening, 'Opening the recording file timed out.');
        } catch {
            // A picker handle may finish opening after the timeout. Never leave
            // that late writer open or let it attach to a subsequent recording.
            if (opening) void opening.then(writer => writer.abort()).catch((): void => {});
            run.failure = 'Could not open the recording file. Choose a location and try again.';
            run.failureCode = 'file_open_failed';
        }
        run.opening = false;
        if (!sameSource(run.source, this.options.getSource())) run.stopRequested = true;
        if (run.stopRequested || run.failure) { await this.finish(run); return; }
        try {
            const tracks = [source.videoTrack];
            if (source.audioTrack?.readyState === 'live') tracks.push(source.audioTrack);
            const stream = (this.options.createStream || (tracks => new MediaStream(tracks)))(tracks);
            // IMPORTANT: no MIME type or bitrate options. Chromium only selects
            // its existing-encoded-frame recorder with unspecified video codec.
            const recorder = (this.options.createRecorder || (stream => new MediaRecorder(stream)))(stream);
            run.recorder = recorder;
            recorder.ondataavailable = event => this.receive(run, event.data);
            recorder.onstop = () => { void this.finish(run); };
            recorder.onerror = () => this.fail(run, 'The browser could not record this stream. The recording was not saved.', 'recorder_failed');
            run.startTimer = setTimeout(() => this.fail(run, 'No recording data arrived. Try again once the stream is playing.', 'start_timeout'), this.options.startTimeoutMs ?? 15_000);
            run.captureStartedAt = this.elapsedNow();
            recorder.start(1_000);
            run.recorderStarted = true;
        } catch {
            this.fail(run, 'The browser could not start recording this stream.', 'recorder_start_failed');
        }
    }

    private receive(run: RecordingRun, data: Blob): void {
        if (run !== this.run || run.finishing || run.failure || !data.size) return;
        if (!matchesFormat(run.recorder?.mimeType || data.type, run.format)) {
            this.fail(run, `The browser did not produce ${run.format.codec} ${run.format.description}. The recording was not saved.`, 'format_mismatch');
            return;
        }
        if (run.pendingBytes + data.size > (this.options.maxPendingBytes ?? 64 * 1024 * 1024)) {
            this.fail(run, 'The disk could not keep up with the recording. The recording was not saved.', 'write_backpressure');
            return;
        }
        if (!run.receivedData) {
            run.receivedData = true;
            clearTimeout(run.startTimer);
            this.notify(run, 'recording_started');
            this.update({ startedAt: this.now(), ...(run.stopRequested ? {} : { phase: 'recording' as const, message: 'Recording to your device.' }) });
        }
        run.pendingBytes += data.size;
        run.writes = run.writes.then(async () => {
            if (run.failure || run !== this.run) return;
            await this.withTimeout(run.writer!.write(data), 'Writing recording data timed out.');
            if (run === this.run) {
                run.bytesWritten = run.writer!.bytesWritten ?? run.bytesWritten + data.size;
                this.update({ bytesWritten: run.bytesWritten });
            }
        }).catch(() => {
            this.fail(run, 'Could not write the recording file. Check free space and file access. The recording was not saved.', 'write_failed');
        }).finally(() => { run.pendingBytes -= data.size; });
    }

    stop(reason = 'Finishing the recording…'): Promise<boolean> {
        const run = this.run;
        if (!run) {
            if (this.state.phase === 'choosing') {
                ++this.choice;
                this.update({ phase: this.file ? 'ready' : 'idle', message: this.file ? 'Ready to record.' : 'Choose a location for your recording.' });
            }
            return Promise.resolve(this.state.phase !== 'error');
        }
        this.requestStop(run, reason);
        return run.completion;
    }

    private requestStop(run: RecordingRun, reason: string): void {
        if (run.stopRequested || run.finishing) return;
        run.stopRequested = true;
        run.captureStoppedAt = this.elapsedNow();
        clearTimeout(run.startTimer);
        this.update({ phase: 'saving', message: reason });
        if (run.opening) return;
        if (!run.recorderStarted) { void this.finish(run); return; }
        run.stopTimer = setTimeout(() => {
            run.failure ||= 'The browser did not finish the recording in time. The recording was not saved.';
            run.failureCode ||= 'stop_timeout';
            void this.finish(run);
        }, this.options.ioTimeoutMs ?? 15_000);
        try {
            if (run.recorder?.state !== 'inactive') run.recorder?.stop();
            // If already inactive, wait for its queued final data and stop event.
        } catch {
            run.failure ||= 'The browser could not finish the recording. The recording was not saved.';
            run.failureCode ||= 'stop_failed';
            void this.finish(run);
        }
    }

    private fail(run: RecordingRun, message: string, code: RecordingFailureCode): void {
        if (run !== this.run) return;
        run.failure ||= message;
        run.failureCode ||= code;
        this.requestStop(run, 'Finishing recording cleanup…');
    }

    private async finish(run: RecordingRun): Promise<void> {
        if (run.finishing || run.opening) return;
        run.finishing = true;
        run.captureStoppedAt ??= this.elapsedNow();
        clearTimeout(run.startTimer);
        clearTimeout(run.stopTimer);
        this.update({ phase: 'saving', message: 'Saving the recording…' });
        try {
            await this.withTimeout(run.writes, 'Finishing pending recording writes timed out.');
        } catch {
            run.failure ||= 'Could not finish writing the recording in time. The file was not saved.';
            run.failureCode ||= 'write_timeout';
        }
        if (!run.failure && run.recorderStarted && !run.receivedData) {
            run.failure = 'No video was captured. The recording was not saved.';
            run.failureCode = 'empty_recording';
        }
        if (run.writer) {
            try {
                if (run.failure || !run.receivedData) await this.withTimeout(run.writer.abort(), 'Recording cleanup timed out.');
                else {
                    await this.withTimeout(run.writer.close(), 'Saving the recording timed out.');
                    run.bytesWritten = run.writer.bytesWritten ?? run.bytesWritten;
                }
            } catch {
                run.failure ||= 'Could not finish saving the recording. The file may be incomplete.';
                run.failureCode ||= 'file_close_failed';
                // A failed close is never a saved file. Abort is best effort and
                // bounded; a stalled drive must not hang session navigation.
                try { await this.withTimeout(run.writer.abort(), 'Recording cleanup timed out.'); } catch { /* Already reported. */ }
            }
        }
        run.source.videoTrack.removeEventListener('ended', run.trackEnded);
        run.source.audioTrack?.removeEventListener('ended', run.trackEnded);
        if (run.recorder) {
            run.recorder.ondataavailable = null;
            run.recorder.onstop = null;
            run.recorder.onerror = null;
        }
        if (run.failure) this.notify(run, 'recording_failed');
        else if (run.receivedData) this.notify(run, 'recording_saved');
        this.run = null;
        if (run.failure) this.update({ phase: 'error', message: run.failure });
        else if (run.receivedData) this.update({ phase: 'saved', bytesWritten: run.bytesWritten, message: 'Saved to your chosen location.' });
        else this.update({ phase: 'idle', message: 'Recording cancelled. Choose a new location to record.' });
        run.complete(!run.failure);
    }

    private notify(run: RecordingRun, eventType: RecordingLifecycleEvent['eventType']): void {
        // Never await analytics: neither network failures nor observer bugs may delay a save.
        try {
            const result = run.observer?.({
                eventType, occurredAtUtc: new Date(this.now()).toISOString(), codec: run.format.codec,
                container: run.format.extension === '.webm' ? 'webm' : 'matroska',
                bytesWritten: run.bytesWritten,
                durationMs: run.captureStartedAt === null ? 0 : Math.max(0, Math.round(
                    (run.captureStoppedAt ?? this.elapsedNow()) - run.captureStartedAt)),
                ...(eventType === 'recording_failed' ? { failureCode: run.failureCode } : {})
            });
            if (result) void Promise.resolve(result).catch(() => { /* Isolate asynchronous observers too. */ });
        } catch { /* Local recording remains independent of telemetry. */ }
    }

    sourceChanged(): void {
        if (this.run && !sameSource(this.run.source, this.options.getSource())) {
            void this.stop('The stream changed or disconnected. Finishing the recording.');
        }
    }

    async dispose(): Promise<void> {
        this.disposed = true;
        ++this.choice;
        await this.stop();
        this.file = null;
        this.fileFormat = null;
        this.listeners.clear();
    }

    private withTimeout<T>(promise: Promise<T>, message: string): Promise<T> {
        return new Promise<T>((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error(message)), this.options.ioTimeoutMs ?? 15_000);
            promise.then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
        });
    }
}
