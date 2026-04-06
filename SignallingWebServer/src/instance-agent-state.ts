// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

export interface InstanceAgentDesiredStateSnapshot {
    warmHoldEnabled: boolean;
    drainEnabled: boolean;
    shutdownRequested: boolean;
    policyVersion: string;
    message?: string;
    updatedAtUtc?: string;
    receivedAtUtc?: string;
}

function toBoolean(value: unknown): boolean {
    if (typeof value === 'boolean') {
        return value;
    }

    if (typeof value !== 'string') {
        return false;
    }

    switch (value.trim().toLowerCase()) {
        case '1':
        case 'true':
        case 'yes':
        case 'on':
            return true;
        default:
            return false;
    }
}

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

export function normalizeInstanceAgentDesiredStateSnapshot(
    value: Partial<InstanceAgentDesiredStateSnapshot> | null | undefined
): InstanceAgentDesiredStateSnapshot {
    return {
        warmHoldEnabled: toBoolean(value?.warmHoldEnabled),
        drainEnabled: toBoolean(value?.drainEnabled),
        shutdownRequested: toBoolean(value?.shutdownRequested),
        policyVersion: normalizeOptionalText(value?.policyVersion) ?? 'default',
        message: normalizeOptionalText(value?.message),
        updatedAtUtc: normalizeOptionalText(value?.updatedAtUtc),
        receivedAtUtc: normalizeOptionalText(value?.receivedAtUtc)
    };
}

export function readInstanceAgentDesiredStateSnapshot(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentDesiredStateSnapshot {
    const normalizedPath = path.resolve(filePath);
    if (!fs.existsSync(normalizedPath)) {
        return normalizeInstanceAgentDesiredStateSnapshot(undefined);
    }

    try {
        const raw = fs.readFileSync(normalizedPath, 'utf8');
        return normalizeInstanceAgentDesiredStateSnapshot(
            JSON.parse(raw) as Partial<InstanceAgentDesiredStateSnapshot>
        );
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(`[instance-agent-state] Failed to read desired state file '${normalizedPath}': ${message}`);
        return normalizeInstanceAgentDesiredStateSnapshot(undefined);
    }
}

export function writeInstanceAgentDesiredStateSnapshot(
    filePath: string,
    snapshot: Partial<InstanceAgentDesiredStateSnapshot>,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentDesiredStateSnapshot {
    const normalizedPath = path.resolve(filePath);
    const normalizedSnapshot = normalizeInstanceAgentDesiredStateSnapshot(snapshot);

    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fs.writeFileSync(normalizedPath, JSON.stringify(normalizedSnapshot, null, 2), 'utf8');
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(`[instance-agent-state] Failed to write desired state file '${normalizedPath}': ${message}`);
    }

    return normalizedSnapshot;
}
