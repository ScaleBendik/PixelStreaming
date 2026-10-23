// Copyright Epic Games, Inc. All Rights Reserved.

/** Chromium's live WebM/Matroska needs an Info/Duration and a discoverable Cues
 * index. Only headers change: track descriptions and encoded blocks stay intact.
 * Parsing buffers are bounded to 64 MiB, the header to 1 MiB, and cues to 100k.
 */
interface Sink {
    write(data: Blob): Promise<void>;
    seek(position: number): Promise<void>;
    close(): Promise<void>;
    abort(): Promise<void>;
}

interface ElementHeader { id: number; start: number; end: number; unknown: boolean }
const SEGMENT = 0x18538067, INFO = 0x1549a966, TRACKS = 0x1654ae6b;
const CLUSTER = 0x1f43b675, CUES = 0x1c53bb6b;
const MAX_ELEMENT = 64 * 1024 * 1024;

function vint(bytes: Uint8Array, offset: number, id = false): { value: number; width: number; unknown: boolean } | null {
    if (offset >= bytes.length) return null;
    const first = bytes[offset];
    if (!first) throw new Error('Invalid EBML integer');
    let width = 1;
    while (!(first & (0x80 >> (width - 1)))) width++;
    if (width > (id ? 4 : 8)) throw new Error('Invalid EBML width');
    if (offset + width > bytes.length) return null;
    let value = id ? first : first & (0xff >> width);
    let unknown = !id && value === (0xff >> width);
    for (let i = 1; i < width; i++) {
        value = value * 256 + bytes[offset + i];
        unknown &&= bytes[offset + i] === 255;
    }
    if (!unknown && !Number.isSafeInteger(value)) throw new Error('Unsafe EBML integer');
    return { value, width, unknown };
}

function header(bytes: Uint8Array, offset = 0): ElementHeader | null {
    const id = vint(bytes, offset, true);
    if (!id) return null;
    const size = vint(bytes, offset + id.width);
    if (!size) return null;
    const start = offset + id.width + size.width;
    return { id: id.value, start, end: size.unknown ? Infinity : start + size.value, unknown: size.unknown };
}

function concatenate(arrays: Uint8Array[]): Uint8Array {
    const out = new Uint8Array(arrays.reduce((n, a) => n + a.length, 0));
    let offset = 0;
    for (const a of arrays) { out.set(a, offset); offset += a.length; }
    return out;
}

function join(...arrays: Uint8Array[]): Uint8Array { return concatenate(arrays); }

function uint(value: number): Uint8Array {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid metadata integer');
    const bytes = [value % 256];
    while ((value = Math.floor(value / 256))) bytes.unshift(value % 256);
    return new Uint8Array(bytes);
}

function element(id: number, payload: Uint8Array): Uint8Array {
    let width = 1;
    while (payload.length >= 2 ** (7 * width) - 1) width++;
    const size = new Uint8Array(width);
    let remaining = payload.length;
    for (let i = width - 1; i >= 0; i--) { size[i] = remaining % 256; remaining = Math.floor(remaining / 256); }
    size[0] |= 1 << (8 - width);
    return join(uint(id), size, payload);
}

function fields(bytes: Uint8Array): Array<{ id: number; payload: Uint8Array; raw: Uint8Array }> {
    const result = [];
    for (let p = 0; p < bytes.length;) {
        const h = header(bytes, p);
        if (!h || h.unknown || h.end > bytes.length) throw new Error('Invalid metadata element');
        result.push({ id: h.id, payload: bytes.slice(h.start, h.end), raw: bytes.slice(p, h.end) });
        p = h.end;
    }
    return result;
}

function number(bytes: Uint8Array): number {
    const value = bytes.reduce((n, b) => n * 256 + b, 0);
    if (!Number.isSafeInteger(value)) throw new Error('Unsafe metadata integer');
    return value;
}

function float(value: number): Uint8Array {
    const bytes = new Uint8Array(8);
    new DataView(bytes.buffer).setFloat64(0, value);
    return bytes;
}

export class SeekableRecordingWriter {
    private pending: Uint8Array = new Uint8Array(0);
    private initialized = false;
    private segmentStart = 0;
    private durationPosition = 0;
    private infoPosition = 0;
    private tracksPosition = 0;
    private clusterPosition = 0;
    private clusterDataPosition = 0;
    private clusterEnd = 0;
    private clusterTime = 0;
    private inCluster = false;
    private videoTrack = 0;
    private scale = 1_000_000;
    private defaultFrameDuration = 0;
    private lastVideoTime = -1;
    private frameDuration = 0;
    private duration = 0;
    private cues: Uint8Array[] = [];
    private closed = false;
    bytesWritten = 0;

    constructor(private sink: Sink) {}

    private checkOpen(): void { if (this.closed) throw new Error('Recording writer closed'); }

    private async output(bytes: Uint8Array): Promise<void> {
        this.checkOpen();
        await this.sink.write(new Blob([bytes.slice().buffer]));
        this.checkOpen();
        this.bytesWritten += bytes.length;
    }

    async write(blob: Blob): Promise<void> {
        if (this.closed) throw new Error('Recording writer closed');
        if (this.pending.length + blob.size > MAX_ELEMENT) throw new Error('Recording element exceeds memory limit');
        this.pending = join(this.pending, new Uint8Array(await blob.arrayBuffer()));
        this.checkOpen();
        if (!this.initialized && !await this.initialize()) {
            if (this.pending.length > 1024 * 1024) throw new Error('Recording header too large');
            return;
        }
        let consumed = 0;
        while (consumed < this.pending.length) {
            const h = header(this.pending, consumed);
            if (!h) break;
            const absolute = this.bytesWritten + consumed;
            if (this.inCluster && (absolute === this.clusterEnd || h.id === CLUSTER || h.id === CUES)) this.inCluster = false;
            if (h.id === CLUSTER && !this.inCluster) {
                this.clusterPosition = absolute - this.segmentStart;
                this.clusterDataPosition = this.bytesWritten + h.start;
                this.clusterEnd = h.unknown ? Infinity : this.bytesWritten + h.end;
                this.clusterTime = 0;
                this.inCluster = true;
                consumed = h.start;
                continue;
            }
            if (h.unknown || h.end - consumed > MAX_ELEMENT) throw new Error('Unsupported recording element');
            if (h.end > this.pending.length) break;
            if (this.inCluster) {
                if (this.bytesWritten + h.end > this.clusterEnd) throw new Error('Invalid cluster size');
                const payload = this.pending.subarray(h.start, h.end);
                if (h.id === 0xe7) this.clusterTime = number(payload);
                if (h.id === 0xa3) this.block(payload, absolute - this.clusterDataPosition);
                if (h.id === 0xa0) {
                    const group = fields(payload);
                    const block = group.find(f => f.id === 0xa1);
                    if (block) this.block(block.payload, absolute - this.clusterDataPosition, !group.some(f => f.id === 0xfb), group.find(f => f.id === 0x9b)?.payload);
                }
            } else if (h.id === CUES || h.id === INFO || h.id === TRACKS || h.id === SEGMENT) {
                throw new Error('Unexpected duplicate recording metadata');
            }
            consumed = h.end;
        }
        if (consumed) {
            await this.output(this.pending.subarray(0, consumed));
            this.pending = this.pending.slice(consumed);
        }
    }

    private async initialize(): Promise<boolean> {
        if (this.pending.length > 1024 * 1024 && !header(this.pending)) throw new Error('Recording header too large');
        const ebml = header(this.pending);
        if (!ebml || ebml.end > this.pending.length) return false;
        if (ebml.id !== 0x1a45dfa3 || ebml.unknown) throw new Error('Missing EBML header');
        const segment = header(this.pending, ebml.end);
        if (!segment) return false;
        if (segment.id !== SEGMENT) throw new Error('Missing recording segment');
        let offset = segment.start;
        const metadata: Array<{ id: number; payload: Uint8Array; raw: Uint8Array }> = [];
        while (true) {
            if (offset > 1024 * 1024) throw new Error('Recording header too large');
            const h = header(this.pending, offset);
            if (!h) return false;
            if (h.id === CLUSTER) break;
            if (h.unknown || h.end > 1024 * 1024) throw new Error('Unsupported recording header');
            if (h.end > this.pending.length) return false;
            metadata.push({ id: h.id, payload: this.pending.slice(h.start, h.end), raw: this.pending.slice(offset, h.end) });
            offset = h.end;
        }
        const info = metadata.filter(f => f.id === INFO), tracks = metadata.filter(f => f.id === TRACKS);
        if (info.length !== 1 || tracks.length !== 1) throw new Error('Missing recording track metadata');
        const infoFields = fields(info[0].payload).filter(f => f.id !== 0x4489 && f.id !== 0xbf);
        const scale = infoFields.find(f => f.id === 0x2ad7b1);
        if (scale) this.scale = number(scale.payload);
        if (!this.scale) throw new Error('Invalid timestamp scale');
        for (const entry of fields(tracks[0].payload).filter(f => f.id === 0xae)) {
            const track = fields(entry.payload);
            if (number(track.find(f => f.id === 0x83)?.payload || new Uint8Array()) !== 1) continue;
            this.videoTrack = number(track.find(f => f.id === 0xd7)!.payload);
            this.defaultFrameDuration = number(track.find(f => f.id === 0x23e383)?.payload || new Uint8Array()) / this.scale;
        }
        if (!this.videoTrack) throw new Error('Missing video track');
        // An unknown-length Segment permits appending Cues. Reserve a fixed-size
        // Void for SeekHead so final patches never move already-written clusters.
        const prefix = join(this.pending.slice(0, ebml.end), uint(SEGMENT), new Uint8Array([1, 255, 255, 255, 255, 255, 255, 255]));
        this.segmentStart = prefix.length;
        await this.output(prefix);
        await this.output(element(0xec, new Uint8Array(253))); // exactly 256 bytes
        this.infoPosition = this.bytesWritten - this.segmentStart;
        const newInfo = element(INFO, join(...infoFields.map(f => f.raw), element(0x4489, float(0))));
        this.durationPosition = this.bytesWritten + newInfo.length - 8;
        await this.output(newInfo);
        this.tracksPosition = this.bytesWritten - this.segmentStart;
        await this.output(tracks[0].raw);
        // Existing SeekHead/CRC offsets become invalid when headers move.
        for (const f of metadata) if (![INFO, TRACKS, 0x114d9b74, 0xbf, CUES].includes(f.id)) await this.output(f.raw);
        this.pending = this.pending.slice(offset);
        this.initialized = true;
        return true;
    }

    private block(payload: Uint8Array, relativePosition: number, keyOverride?: boolean, duration?: Uint8Array): void {
        const track = vint(payload, 0);
        if (!track || track.unknown || payload.length < track.width + 3) throw new Error('Truncated recording block');
        const relative = new DataView(payload.buffer, payload.byteOffset + track.width, 2).getInt16(0);
        const time = this.clusterTime + relative;
        const flags = payload[track.width + 2];
        this.duration = Math.max(this.duration, time + (duration ? number(duration) : 0));
        if (track.value !== this.videoTrack) return;
        if (flags & 6) throw new Error('Unsupported laced video');
        if (this.lastVideoTime >= 0 && time > this.lastVideoTime) this.frameDuration = time - this.lastVideoTime;
        this.lastVideoTime = Math.max(this.lastVideoTime, time);
        if ((keyOverride ?? !!(flags & 0x80)) && time >= 0) {
            if (this.cues.length >= 100_000) throw new Error('Recording seek index limit reached');
            this.cues.push(element(0xbb, join(element(0xb3, uint(time)), element(0xb7, join(
                element(0xf7, uint(this.videoTrack)), element(0xf1, uint(this.clusterPosition)), element(0xf0, uint(relativePosition))
            )))));
        }
    }

    async close(): Promise<void> {
        if (this.closed) throw new Error('Recording writer closed');
        if (!this.initialized || this.pending.length || !this.cues.length ||
            (this.inCluster && this.clusterEnd !== Infinity && this.clusterEnd !== this.bytesWritten)) {
            throw new Error('Incomplete recording cannot be indexed');
        }
        const cuesPosition = this.bytesWritten - this.segmentStart;
        await this.output(element(CUES, concatenate(this.cues)));
        const seek = (id: number, position: number): Uint8Array => element(0x4dbb, join(element(0x53ab, uint(id)), element(0x53ac, uint(position))));
        const index = element(0x114d9b74, join(seek(INFO, this.infoPosition), seek(TRACKS, this.tracksPosition), seek(CUES, cuesPosition)));
        const padding = 256 - index.length;
        const reserved = join(index, element(0xec, new Uint8Array(padding - (padding - 2 < 127 ? 2 : 3))));
        if (reserved.length !== 256) throw new Error('Invalid seek header reservation');
        await this.sink.seek(this.segmentStart);
        this.checkOpen();
        await this.sink.write(new Blob([reserved.slice().buffer]));
        this.checkOpen();
        await this.sink.seek(this.durationPosition);
        this.checkOpen();
        await this.sink.write(new Blob([float(Math.max(this.duration, this.lastVideoTime + (this.defaultFrameDuration || this.frameDuration || 1))).slice().buffer]));
        this.checkOpen();
        // Finalized files use a known Segment length, including the appended index.
        const segmentSize = new Uint8Array(8);
        let length = this.bytesWritten - this.segmentStart;
        for (let i = 7; i > 0; i--) { segmentSize[i] = length % 256; length = Math.floor(length / 256); }
        segmentSize[0] = 1;
        await this.sink.seek(this.segmentStart - 8);
        this.checkOpen();
        await this.sink.write(new Blob([segmentSize.buffer]));
        this.checkOpen();
        await this.sink.close();
        this.closed = true;
        this.cues = [];
    }

    async abort(): Promise<void> {
        this.closed = true;
        this.pending = new Uint8Array(0);
        this.cues = [];
        await this.sink.abort();
    }
}
