// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

export interface InstanceAgentRecycleMarkerSnapshot {
    requestedAtUtc?: string;
    reason?: string;
    recycleId?: string;
    sourcePid?: number;
}

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

function normalizeOptionalInteger(value: unknown): number | undefined {
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
        return Math.trunc(value);
    }

    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    if (normalized.length === 0) {
        return undefined;
    }

    const parsed = Number.parseInt(normalized, 10);
    return Number.isNaN(parsed) || parsed < 0 ? undefined : parsed;
}

export function resolveInstanceAgentRecycleMarkerPath(desiredStatePath?: string | null): string {
    const normalizedDesiredStatePath = typeof desiredStatePath === 'string' ? desiredStatePath.trim() : '';
    if (normalizedDesiredStatePath.length > 0) {
        return path.resolve(
            path.dirname(path.resolve(normalizedDesiredStatePath)),
            'instance-agent-recycle-marker.json'
        );
    }

    return path.resolve(__dirname, '..', 'state', 'instance-agent-recycle-marker.json');
}

export function normalizeInstanceAgentRecycleMarkerSnapshot(
    value: Partial<InstanceAgentRecycleMarkerSnapshot> | null | undefined
): InstanceAgentRecycleMarkerSnapshot {
    return {
        requestedAtUtc: normalizeOptionalText(value?.requestedAtUtc),
        reason: normalizeOptionalText(value?.reason),
        recycleId: normalizeOptionalText(value?.recycleId),
        sourcePid: normalizeOptionalInteger(value?.sourcePid)
    };
}

export function readInstanceAgentRecycleMarkerSnapshot(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentRecycleMarkerSnapshot | null {
    const normalizedPath = path.resolve(filePath);
    if (!fs.existsSync(normalizedPath)) {
        return null;
    }

    try {
        const raw = fs.readFileSync(normalizedPath, 'utf8');
        return normalizeInstanceAgentRecycleMarkerSnapshot(
            JSON.parse(raw) as Partial<InstanceAgentRecycleMarkerSnapshot>
        );
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-recycle-state] Failed to read recycle marker '${normalizedPath}': ${message}`
        );
        return null;
    }
}

export function writeInstanceAgentRecycleMarkerSnapshot(
    filePath: string,
    snapshot: Partial<InstanceAgentRecycleMarkerSnapshot>,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentRecycleMarkerSnapshot {
    const normalizedPath = path.resolve(filePath);
    const normalizedSnapshot = normalizeInstanceAgentRecycleMarkerSnapshot(snapshot);

    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fs.writeFileSync(normalizedPath, JSON.stringify(normalizedSnapshot, null, 2), 'utf8');
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-recycle-state] Failed to write recycle marker '${normalizedPath}': ${message}`
        );
    }

    return normalizedSnapshot;
}

export function clearInstanceAgentRecycleMarkerSnapshot(
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
            `[instance-agent-recycle-state] Failed to clear recycle marker '${normalizedPath}': ${message}`
        );
    }
}
