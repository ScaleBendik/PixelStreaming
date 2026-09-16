// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export interface RecoveryEvent {
    eventType: 'runtime_fault';
    occurredAtUtc: string;
    metadata: Record<string, string>;
}
export type RecoveryNotice = {
    kind: 'unexpected_exit' | 'unresponsive';
    phase: string;
    occurredAtUtc: string;
};
const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Watchdog creates immutable outbox files; only the agent removes acknowledged files.
 * Context, notice and restored markers have separate single writers. */
export class RuntimeRecovery {
    readonly generation = randomUUID();
    readonly directory: string;
    constructor(
        desiredStatePath: string,
        private readonly log: (message: string) => void
    ) {
        this.directory = desiredStatePath + '.recovery';
    }
    private read(name: string): Record<string, unknown> | null {
        try {
            const value: unknown = JSON.parse(fs.readFileSync(path.join(this.directory, name), 'utf8'));
            return value && typeof value === 'object' && !Array.isArray(value)
                ? (value as Record<string, unknown>)
                : null;
        } catch {
            return null;
        }
    }
    private write(name: string, value: unknown): void {
        fs.mkdirSync(this.directory, { recursive: true });
        const filename = path.join(this.directory, name);
        const temporary = filename + '.' + this.generation + '.pending';
        const fd = fs.openSync(temporary, 'w');
        try {
            fs.writeFileSync(fd, JSON.stringify(value));
            fs.fsyncSync(fd);
        } finally {
            fs.closeSync(fd);
        }
        fs.renameSync(temporary, filename);
    }
    context(sessionRequestId: string | undefined, suppressed: boolean): void {
        try {
            this.write('context.json', {
                sessionRequestId,
                suppressed,
                generation: this.generation,
                processId: process.pid,
                updatedAtUtc: new Date().toISOString()
            });
        } catch {
            this.log('[runtime-recovery] Could not persist watchdog session context.');
        }
    }
    batch(): RecoveryEvent[] {
        try {
            const events: RecoveryEvent[] = [];
            for (const file of fs
                .readdirSync(this.directory)
                .filter((name) => /^[0-9a-f-]{36}\.json$/i.test(name))
                .sort()) {
                const value = this.read(file) as unknown as RecoveryEvent;
                if (
                    value?.eventType === 'runtime_fault' &&
                    value.metadata?.runtimeFaultEvidenceVersion === '1' &&
                    guid.test(value.metadata.evidenceId) &&
                    file === value.metadata.evidenceId + '.json' &&
                    Number.isFinite(Date.parse(value.occurredAtUtc))
                )
                    events.push(value);
                else this.log('[runtime-recovery] Invalid evidence file retained: ' + file);
                if (events.length === 20) break;
            }
            return events;
        } catch {
            return [];
        }
    }
    acknowledge(events: RecoveryEvent[]): void {
        for (const event of events) {
            const id = event.metadata.evidenceId;
            if (!guid.test(id)) continue;
            try {
                fs.unlinkSync(path.join(this.directory, id + '.json'));
            } catch {
                this.log('[runtime-recovery] Could not remove acknowledged evidence ' + id);
            }
        }
    }
    mediaReceived(sessionRequestId: string | undefined): void {
        if (!sessionRequestId) return;
        try {
            const latest = this.read('notice.json') as unknown as RecoveryEvent;
            const restored = this.read('restored.json');
            const occurredAtUtc = new Date().toISOString();
            if (
                latest?.metadata?.sessionRequestId === sessionRequestId &&
                !(
                    restored?.sessionRequestId === sessionRequestId &&
                    Date.parse(String(restored.occurredAtUtc)) >= Date.parse(latest.occurredAtUtc)
                )
            ) {
                const evidenceId = randomUUID();
                this.write(evidenceId + '.json', {
                    ...latest,
                    occurredAtUtc,
                    metadata: {
                        ...latest.metadata,
                        evidenceId,
                        source: 'instance-agent',
                        phase: 'media_restored'
                    }
                });
            }
            this.write('restored.json', { sessionRequestId, occurredAtUtc });
        } catch {
            this.log('[runtime-recovery] Could not persist media recovery marker.');
        }
    }
    notice(): RecoveryNotice | null {
        const context = this.read('context.json');
        const latest = this.read('notice.json') as unknown as RecoveryEvent;
        const contextAge = Date.now() - Date.parse(String(context?.updatedAtUtc));
        if (
            !context?.sessionRequestId ||
            context.suppressed ||
            !latest?.metadata ||
            latest.metadata.sessionRequestId !== context.sessionRequestId ||
            !Number.isFinite(contextAge) ||
            contextAge < -5_000 ||
            contextAge > 30_000 ||
            !Number.isFinite(Date.parse(latest.occurredAtUtc))
        )
            return null;
        const restored = this.read('restored.json');
        if (
            restored?.sessionRequestId === context.sessionRequestId &&
            Date.parse(String(restored.occurredAtUtc)) >= Date.parse(latest.occurredAtUtc)
        )
            return null;
        const kind = latest.metadata.faultKind;
        if (kind !== 'unexpected_exit' && kind !== 'unresponsive') return null;
        return { kind, phase: latest.metadata.phase, occurredAtUtc: latest.occurredAtUtc };
    }
}
