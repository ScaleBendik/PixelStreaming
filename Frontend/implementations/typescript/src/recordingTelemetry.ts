import type { RecordingLifecycleEvent, RecordingObserverFactory } from './localRecording';

export interface RecordingReportContext { sessionRequestId: string; capability: string; }
type Report = RecordingLifecycleEvent & { schemaVersion: 1; recordingId: string };
type Pending = { context: RecordingReportContext; report: Report; expiresAt: number; attempts: number; nextAt: number };
type StorageAccess = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TTL = 24 * 60 * 60 * 1000;
const LIMIT = 128;
const FAILURE_CODES = new Set(['file_open_failed', 'recorder_start_failed', 'recorder_failed', 'start_timeout',
    'format_mismatch', 'write_backpressure', 'write_failed', 'stop_timeout', 'stop_failed', 'write_timeout',
    'empty_recording', 'file_close_failed']);

function validContext(value: unknown): value is RecordingReportContext {
    const c = value as RecordingReportContext | null;
    return !!c && typeof c.sessionRequestId === 'string' && UUID.test(c.sessionRequestId) &&
        typeof c.capability === 'string' && /^[A-Za-z0-9_.-]{1,8192}$/.test(c.capability);
}

function validReport(value: unknown): value is Report {
    if (!value || typeof value !== 'object') return false;
    const r = value as Report;
    const fields = ['schemaVersion', 'recordingId', 'eventType', 'occurredAtUtc', 'codec', 'container', 'bytesWritten', 'durationMs', 'failureCode'];
    return Object.keys(r).every(key => fields.includes(key)) && r.schemaVersion === 1 &&
        typeof r.recordingId === 'string' && UUID.test(r.recordingId) &&
        ['recording_started', 'recording_saved', 'recording_failed'].includes(r.eventType) &&
        typeof r.occurredAtUtc === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(r.occurredAtUtc) &&
        Number.isFinite(Date.parse(r.occurredAtUtc)) && new Date(r.occurredAtUtc).toISOString() === r.occurredAtUtc &&
        ['AV1', 'VP9', 'H264'].includes(r.codec) && r.container === (r.codec === 'H264' ? 'matroska' : 'webm') &&
        Number.isSafeInteger(r.bytesWritten) && r.bytesWritten >= 0 && r.bytesWritten <= 2 ** 40 &&
        Number.isSafeInteger(r.durationMs) && r.durationMs >= 0 && r.durationMs <= TTL &&
        (r.eventType === 'recording_failed' ? FAILURE_CODES.has(r.failureCode!) : r.failureCode === undefined) &&
        (r.eventType !== 'recording_saved' || r.bytesWritten > 0);
}

/** Consume secrets before history.replaceState; a fresh launch cannot reuse another launch's token. */
export function consumeRecordingContext(hash: URLSearchParams, sessionRequestId: string | undefined,
    freshLaunch: boolean, storage: StorageAccess | undefined, key: string): RecordingReportContext | undefined {
    const hasIncoming = hash.has('sw_recording');
    const incoming = hash.get('sw_recording');
    hash.delete('sw_recording');
    let cached: unknown;
    try {
        if (freshLaunch || hasIncoming) storage?.removeItem(key);
        else cached = JSON.parse(storage?.getItem(key) || 'null');
    } catch { /* Storage denied or malformed: incoming credentials can still work. */ }
    const candidate = hasIncoming ? { capability: incoming, sessionRequestId } : cached;
    if (!validContext(candidate) || candidate.sessionRequestId !== sessionRequestId) {
        try { storage?.removeItem(key); } catch { /* Optional cache. */ }
        return undefined;
    }
    // Store only the defined fields; never retain URL parameters or server response extras.
    const context = { capability: candidate.capability, sessionRequestId: candidate.sessionRequestId };
    try { storage?.setItem(key, JSON.stringify(context)); } catch { /* In-memory reporting still works. */ }
    return context;
}

interface TelemetryOptions {
    context?: RecordingReportContext;
    storage?: StorageAccess;
    storageKey: string;
    send?: typeof fetch;
    now?: () => number;
    uuid?: () => string;
}

/** Bounded, best-effort tab outbox. An acknowledgement means durable API acceptance, not just relay receipt. */
export class RecordingTelemetry {
    private pending: Pending[] = [];
    private readonly active = new Set<Pending>();
    private timer?: ReturnType<typeof setTimeout>;
    private disposed = false;
    private readonly now: () => number;
    private readonly send: typeof fetch;
    private readonly context?: RecordingReportContext;

    constructor(private readonly options: TelemetryOptions) {
        this.now = options.now || Date.now;
        // Window.fetch requires its native receiver in Chromium; do not call it as a class method.
        this.send = options.send || ((input, init) => fetch(input, init));
        this.context = validContext(options.context) ? { ...options.context } : undefined;
        try {
            const raw = options.storage?.getItem(options.storageKey);
            // Bound parsing as well as the eventual queue; never trust sessionStorage contents.
            const entries: unknown = raw && raw.length <= 2_000_000 ? JSON.parse(raw) : [];
            if (Array.isArray(entries)) {
                this.pending = entries.slice(-LIMIT).filter((p): p is Pending => !!p &&
                    validContext(p.context) && validReport(p.report) && Number.isFinite(p.expiresAt) &&
                    p.expiresAt > this.now() && p.expiresAt <= this.now() + TTL).map(p => ({
                        context: { sessionRequestId: p.context.sessionRequestId, capability: p.context.capability },
                        report: p.report, expiresAt: p.expiresAt, attempts: 0, nextAt: 0
                    }));
            }
        } catch { /* Malformed or blocked storage does not disable recording. */ }
        this.flush();
    }

    readonly createObserver: RecordingObserverFactory = () => {
        if (!this.context || this.disposed) return undefined;
        let recordingId: string;
        try { recordingId = (this.options.uuid || (() => crypto.randomUUID()))(); } catch { return undefined; }
        if (!UUID.test(recordingId)) return undefined;
        const context = { ...this.context };
        const seen = new Set<Report['eventType']>();
        let terminal = false;
        return event => {
            if (this.disposed || terminal || seen.has(event.eventType)) return;
            const report: Report = { ...event, schemaVersion: 1, recordingId };
            if (!validReport(report)) return;
            seen.add(event.eventType);
            terminal = event.eventType !== 'recording_started';
            this.pending = this.pending.filter(p => p.expiresAt > this.now());
            if (this.pending.length >= LIMIT) {
                // Saved/failed outcomes take precedence over an unacknowledged start.
                const victim = this.pending.find(p => !this.active.has(p) && p.report.eventType === 'recording_started') ||
                    (terminal ? this.pending.find(p => !this.active.has(p)) : undefined);
                if (!victim) return;
                this.pending.splice(this.pending.indexOf(victim), 1);
            }
            this.pending.push({ context, report, expiresAt: this.now() + TTL, attempts: 0, nextAt: 0 });
            this.persist();
            this.flush();
        };
    };

    readonly flush = (): void => {
        if (this.disposed) return;
        clearTimeout(this.timer);
        this.pending = this.pending.filter(p => p.expiresAt > this.now());
        this.persist();
        const due = this.pending.filter(p => !this.active.has(p) && p.nextAt <= this.now())
            .sort((a, b) => Number(a.report.eventType === 'recording_started') - Number(b.report.eventType === 'recording_started'));
        // A slow start acknowledgement must not prevent the final save from being submitted before navigation.
        for (const entry of due) {
            if (this.active.size >= 2) break;
            this.active.add(entry);
            void this.deliver(entry);
        }
        const waiting = this.pending.filter(p => !this.active.has(p));
        if (waiting.length && this.active.size < 2) {
            this.timer = setTimeout(this.flush, Math.max(100, Math.min(...waiting.map(p => p.nextAt)) - this.now()));
        }
    };

    private async deliver(entry: Pending): Promise<void> {
        let remove = false;
        try {
            const response = await this.send('/api/recording-events', {
                method: 'POST', headers: { 'Content-Type': 'application/json',
                    'X-SW-Recording': entry.context.capability, 'X-SW-Session-Request': entry.context.sessionRequestId },
                body: JSON.stringify(entry.report), keepalive: true, credentials: 'omit', cache: 'no-store',
                redirect: 'error', signal: AbortSignal.timeout(5_000)
            });
            if (response.ok) {
                const ack = await response.json() as { accepted?: unknown; sessionRequestId?: unknown; recordingId?: unknown; eventType?: unknown } | null;
                remove = !!ack && ack.accepted === true && ack.sessionRequestId === entry.context.sessionRequestId &&
                    ack.recordingId === entry.report.recordingId && ack.eventType === entry.report.eventType;
            } else {
                remove = [400, 401, 403, 404, 405, 409, 410, 413, 415, 422, 501].includes(response.status);
            }
        } catch { /* No credential, payload or raw server error is logged. Retry silently. */ }
        this.active.delete(entry);
        if (this.disposed) return;
        if (remove) this.pending = this.pending.filter(p => p !== entry);
        else {
            entry.attempts++;
            entry.nextAt = this.now() + Math.min(60_000, 1000 * 2 ** Math.min(entry.attempts, 6));
        }
        this.flush();
    }

    private persist(): void {
        try {
            if (this.pending.length) this.options.storage?.setItem(this.options.storageKey, JSON.stringify(this.pending));
            else this.options.storage?.removeItem(this.options.storageKey);
        } catch { /* Disk quota/privacy mode: fall back to the bounded in-memory queue. */ }
    }

    dispose(): void { this.disposed = true; clearTimeout(this.timer); }
}

export function installRecordingTelemetry(hash: URLSearchParams, sessionRequestId: string | undefined, freshLaunch: boolean) {
    let storage: Storage | undefined;
    try { storage = window.sessionStorage; } catch { /* Browser privacy settings. */ }
    const key = 'sw-recording:' + location.host + location.pathname;
    const context = consumeRecordingContext(hash, sessionRequestId, freshLaunch, storage, key + ':context');
    const reporter = new RecordingTelemetry({ context, storage, storageKey: key + ':outbox' });
    // Remains alive while pagehide recording cleanup finishes; delivery never gates navigation.
    window.addEventListener('pagehide', reporter.flush);
    window.addEventListener('online', reporter.flush);
    document.addEventListener('visibilitychange', reporter.flush);
    return reporter;
}
