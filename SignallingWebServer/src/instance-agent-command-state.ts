// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

export type InstanceAgentCommandExecutionStatus = 'acked' | 'running';

export interface InstanceAgentCommandJournalSnapshot {
    instanceCommandId: string;
    instanceId: string;
    region: string;
    sessionRequestId?: string;
    commandType: string;
    idempotencyKey: string;
    requestedAtUtc: string;
    timeoutAtUtc?: string;
    payloadJson?: string;
    status: InstanceAgentCommandExecutionStatus;
    attemptNumber: number;
    ackedAtUtc?: string;
    startedAtUtc?: string;
}

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

function normalizeExecutionStatus(value: unknown): InstanceAgentCommandExecutionStatus | undefined {
    const normalized = normalizeOptionalText(value)?.toLowerCase();
    if (normalized === 'acked' || normalized === 'running') {
        return normalized;
    }

    return undefined;
}

function normalizeAttemptNumber(value: unknown): number {
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
        return Math.trunc(value);
    }

    if (typeof value === 'string') {
        const parsed = Number.parseInt(value.trim(), 10);
        if (!Number.isNaN(parsed) && parsed > 0) {
            return parsed;
        }
    }

    return 1;
}

export function resolveInstanceAgentCommandJournalPath(desiredStatePath?: string | null): string {
    const normalizedDesiredStatePath = typeof desiredStatePath === 'string' ? desiredStatePath.trim() : '';
    if (normalizedDesiredStatePath.length > 0) {
        return path.resolve(
            path.dirname(path.resolve(normalizedDesiredStatePath)),
            'instance-agent-active-command.json'
        );
    }

    return path.resolve(__dirname, '..', 'state', 'instance-agent-active-command.json');
}

export function normalizeInstanceAgentCommandJournalSnapshot(
    value: Partial<InstanceAgentCommandJournalSnapshot> | null | undefined
): InstanceAgentCommandJournalSnapshot | null {
    const instanceCommandId = normalizeOptionalText(value?.instanceCommandId);
    const instanceId = normalizeOptionalText(value?.instanceId);
    const region = normalizeOptionalText(value?.region);
    const commandType = normalizeOptionalText(value?.commandType);
    const idempotencyKey = normalizeOptionalText(value?.idempotencyKey);
    const requestedAtUtc = normalizeOptionalText(value?.requestedAtUtc);
    const status = normalizeExecutionStatus(value?.status);
    if (
        !instanceCommandId ||
        !instanceId ||
        !region ||
        !commandType ||
        !idempotencyKey ||
        !requestedAtUtc ||
        !status
    ) {
        return null;
    }

    return {
        instanceCommandId,
        instanceId,
        region,
        sessionRequestId: normalizeOptionalText(value?.sessionRequestId),
        commandType,
        idempotencyKey,
        requestedAtUtc,
        timeoutAtUtc: normalizeOptionalText(value?.timeoutAtUtc),
        payloadJson: normalizeOptionalText(value?.payloadJson),
        status,
        attemptNumber: normalizeAttemptNumber(value?.attemptNumber),
        ackedAtUtc: normalizeOptionalText(value?.ackedAtUtc),
        startedAtUtc: normalizeOptionalText(value?.startedAtUtc)
    };
}

export function readInstanceAgentCommandJournalSnapshot(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentCommandJournalSnapshot | null {
    const normalizedPath = path.resolve(filePath);
    if (!fs.existsSync(normalizedPath)) {
        return null;
    }

    try {
        const raw = fs.readFileSync(normalizedPath, 'utf8');
        return normalizeInstanceAgentCommandJournalSnapshot(
            JSON.parse(raw) as Partial<InstanceAgentCommandJournalSnapshot>
        );
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-command-state] Failed to read active command journal '${normalizedPath}': ${message}`
        );
        return null;
    }
}

export function writeInstanceAgentCommandJournalSnapshot(
    filePath: string,
    snapshot: Partial<InstanceAgentCommandJournalSnapshot>,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentCommandJournalSnapshot | null {
    const normalizedPath = path.resolve(filePath);
    const normalizedSnapshot = normalizeInstanceAgentCommandJournalSnapshot(snapshot);
    if (!normalizedSnapshot) {
        logger(
            `[instance-agent-command-state] Refusing to write invalid active command journal '${normalizedPath}'.`
        );
        return null;
    }

    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fs.writeFileSync(normalizedPath, JSON.stringify(normalizedSnapshot, null, 2), 'utf8');
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-command-state] Failed to write active command journal '${normalizedPath}': ${message}`
        );
    }

    return normalizedSnapshot;
}

export function clearInstanceAgentCommandJournalSnapshot(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): void {
    const normalizedPath = path.resolve(filePath);
    try {
        if (fs.existsSync(normalizedPath)) {
            fs.unlinkSync(normalizedPath);
        }
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-command-state] Failed to clear active command journal '${normalizedPath}': ${message}`
        );
    }
}
