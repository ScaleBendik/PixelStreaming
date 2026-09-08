// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'node:fs';
import path from 'node:path';
import type { CodecEvidence } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.8';

/** One writer per runtime. Never acknowledges an event until its replacement file is flushed. */
export class CodecEvidenceJournal {
    private events: CodecEvidence[] = [];
    private failed = false;
    constructor(
        private readonly filename: string,
        private readonly capacity = 20000
    ) {
        try {
            fs.mkdirSync(path.dirname(filename), { recursive: true });
            if (fs.existsSync(filename)) {
                const parsed: unknown = JSON.parse(fs.readFileSync(filename, 'utf8'));
                if (
                    !Array.isArray(parsed) ||
                    parsed.length > capacity ||
                    parsed.some((value: unknown) => {
                        const e = value as Partial<CodecEvidence> | null;
                        return (
                            !e ||
                            typeof e.eventId !== 'string' ||
                            typeof e.sessionRequestId !== 'string' ||
                            !Number.isSafeInteger(e.sequence) ||
                            (e.sequence ?? 0) < 1
                        );
                    })
                )
                    throw new Error('Invalid codec journal');
                this.events = parsed as CodecEvidence[];
            }
            this.persist(this.events);
        } catch {
            this.failed = true;
        }
    }
    get ready(): boolean {
        return !this.failed && this.events.length < this.capacity - 20;
    }
    batch(): CodecEvidence[] {
        return this.events.slice(0, 50);
    }
    append(event: CodecEvidence): void {
        if (this.failed || this.events.length >= this.capacity)
            throw new Error('Codec evidence journal unavailable');
        const next = [...this.events, event];
        this.persist(next);
        this.events = next;
    }
    acknowledge(ids: string[]): void {
        const acknowledged = new Set(ids);
        const next = this.events.filter((e) => !acknowledged.has(e.eventId));
        if (next.length === this.events.length) return;
        this.persist(next);
        this.events = next;
    }
    private persist(events: CodecEvidence[]): void {
        const temporary = this.filename + '.pending';
        try {
            const fd = fs.openSync(temporary, 'w');
            try {
                fs.writeFileSync(fd, JSON.stringify(events));
                fs.fsyncSync(fd);
            } finally {
                fs.closeSync(fd);
            }
            fs.renameSync(temporary, this.filename);
        } catch (error) {
            this.failed = true;
            throw error;
        }
    }
}
