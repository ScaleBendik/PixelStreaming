// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

const LEGACY_RECYCLE_MARKER_SCHEMA_VERSION = 1;
const RECYCLE_MARKER_SCHEMA_VERSION = 2;

export type InstanceAgentRecycleMarkerPhase = 'intent' | 'replacement_started';

export interface InstanceAgentRecycleMarkerSnapshot {
    schemaVersion: typeof LEGACY_RECYCLE_MARKER_SCHEMA_VERSION | typeof RECYCLE_MARKER_SCHEMA_VERSION;
    phase: InstanceAgentRecycleMarkerPhase;
    requestedAtUtc: string;
    reason: string;
    recycleId: string;
    sourcePid: number;
    replacementStartedAtUtc?: string;
    resetCompletedAtUtc?: string;
    recycleRequestedToken?: string;
    sessionRequestId?: string;
    userSessionId?: string;
    sessionId?: string;
}

let loggedUnsupportedWindowsDirectorySync = false;

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

export function normalizeInstanceAgentRecycleToken(value: unknown): string | undefined {
    const normalized = normalizeOptionalText(value);
    if (!normalized) {
        return undefined;
    }

    const compactGuid = normalized.replace(/-/g, '');
    return /^[0-9a-f]{32}$/i.test(compactGuid) ? compactGuid.toLowerCase() : normalized;
}

function normalizeRequiredTimestamp(value: unknown): string | null {
    const normalized = normalizeOptionalText(value);
    if (!normalized) {
        return null;
    }

    const parsed = Date.parse(normalized);
    return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}

function normalizeRequiredPositiveInteger(value: unknown): number | null {
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) {
        return null;
    }

    return value;
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
): InstanceAgentRecycleMarkerSnapshot | null {
    const phase = value?.phase === 'intent' || value?.phase === 'replacement_started' ? value.phase : null;
    const requestedAtUtc = normalizeRequiredTimestamp(value?.requestedAtUtc);
    const replacementStartedAtUtc = normalizeRequiredTimestamp(value?.replacementStartedAtUtc);
    const resetCompletedAtUtc = normalizeRequiredTimestamp(value?.resetCompletedAtUtc);
    const reason = normalizeOptionalText(value?.reason);
    const recycleId = normalizeOptionalText(value?.recycleId);
    const sourcePid = normalizeRequiredPositiveInteger(value?.sourcePid);
    if (
        (value?.schemaVersion !== LEGACY_RECYCLE_MARKER_SCHEMA_VERSION &&
            value?.schemaVersion !== RECYCLE_MARKER_SCHEMA_VERSION) ||
        !phase ||
        !requestedAtUtc ||
        !reason ||
        !recycleId ||
        sourcePid === null ||
        (phase === 'intent' &&
            (value?.replacementStartedAtUtc !== undefined || value?.resetCompletedAtUtc !== undefined)) ||
        (phase === 'replacement_started' &&
            (!replacementStartedAtUtc ||
                Date.parse(replacementStartedAtUtc) < Date.parse(requestedAtUtc) ||
                (value?.resetCompletedAtUtc !== undefined &&
                    (!resetCompletedAtUtc ||
                        Date.parse(resetCompletedAtUtc) < Date.parse(replacementStartedAtUtc)))))
    ) {
        return null;
    }

    return {
        schemaVersion: value.schemaVersion,
        phase,
        requestedAtUtc,
        reason,
        recycleId,
        sourcePid,
        replacementStartedAtUtc: phase === 'replacement_started' ? replacementStartedAtUtc! : undefined,
        resetCompletedAtUtc: phase === 'replacement_started' ? (resetCompletedAtUtc ?? undefined) : undefined,
        recycleRequestedToken: normalizeOptionalText(value?.recycleRequestedToken),
        sessionRequestId: normalizeOptionalText(value?.sessionRequestId),
        userSessionId: normalizeOptionalText(value?.userSessionId),
        sessionId: normalizeOptionalText(value?.sessionId)
    };
}

export function readInstanceAgentRecycleMarkerSnapshot(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentRecycleMarkerSnapshot | null {
    const normalizedPath = path.resolve(filePath);

    try {
        const snapshot = normalizeInstanceAgentRecycleMarkerSnapshot(
            JSON.parse(fs.readFileSync(normalizedPath, 'utf8')) as Partial<InstanceAgentRecycleMarkerSnapshot>
        );
        if (!snapshot) {
            throw new Error('Recycle marker schema, phase, or replacement proof is invalid.');
        }

        return snapshot;
    } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
            return null;
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-recycle-state] Failed to read valid recycle marker '${normalizedPath}': ${message}`
        );
        throw error;
    }
}

export function isInstanceAgentRecycleReplacementProof(
    snapshot: InstanceAgentRecycleMarkerSnapshot | null | undefined,
    currentProcessId: number = process.pid
): snapshot is InstanceAgentRecycleMarkerSnapshot & {
    phase: 'replacement_started';
    replacementStartedAtUtc: string;
} {
    return (
        snapshot?.phase === 'replacement_started' &&
        Boolean(snapshot.replacementStartedAtUtc) &&
        snapshot.sourcePid !== currentProcessId
    );
}

function isUnsupportedWindowsDirectorySync(error: unknown): boolean {
    if (process.platform !== 'win32') {
        return false;
    }

    const code = (error as NodeJS.ErrnoException)?.code;
    return (
        code === 'EACCES' || code === 'EINVAL' || code === 'EISDIR' || code === 'ENOTSUP' || code === 'EPERM'
    );
}

function fsyncContainingDirectoryAfterMetadataChange(
    filePath: string,
    logger: (message: string) => void
): boolean {
    const directoryPath = path.dirname(path.resolve(filePath));
    let directoryDescriptor: number | null = null;
    try {
        directoryDescriptor = fs.openSync(directoryPath, 'r');
        fs.fsyncSync(directoryDescriptor);
        return true;
    } catch (error) {
        if (isUnsupportedWindowsDirectorySync(error)) {
            if (!loggedUnsupportedWindowsDirectorySync) {
                loggedUnsupportedWindowsDirectorySync = true;
                const message = error instanceof Error ? error.message : String(error);
                logger(
                    `[instance-agent-recycle-state] Directory fsync is unsupported for '${directoryPath}' on this Windows runtime; the marker file itself remains fsynced and atomic rename semantics are retained: ${message}`
                );
            }
            return true;
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-recycle-state] Failed to fsync marker directory '${directoryPath}': ${message}`
        );
        return false;
    } finally {
        if (directoryDescriptor !== null) {
            try {
                fs.closeSync(directoryDescriptor);
            } catch {
                // Best effort descriptor cleanup after the durability decision was made.
            }
        }
    }
}

export function writeInstanceAgentRecycleMarkerSnapshot(
    filePath: string,
    snapshot: Partial<InstanceAgentRecycleMarkerSnapshot>,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentRecycleMarkerSnapshot {
    const normalizedPath = path.resolve(filePath);
    const normalizedSnapshot = normalizeInstanceAgentRecycleMarkerSnapshot({
        ...snapshot,
        schemaVersion: RECYCLE_MARKER_SCHEMA_VERSION
    });
    if (!normalizedSnapshot) {
        throw new Error('Refusing to persist an invalid recycle marker.');
    }

    const temporaryPath = `${normalizedPath}.${process.pid}.${randomUUID()}.tmp`;
    let fileDescriptor: number | null = null;
    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fileDescriptor = fs.openSync(temporaryPath, 'wx');
        fs.writeFileSync(fileDescriptor, JSON.stringify(normalizedSnapshot, null, 2), 'utf8');
        fs.fsyncSync(fileDescriptor);
        fs.closeSync(fileDescriptor);
        fileDescriptor = null;
        fs.renameSync(temporaryPath, normalizedPath);
        if (!fsyncContainingDirectoryAfterMetadataChange(normalizedPath, logger)) {
            throw new Error('The recycle marker directory metadata could not be made durable.');
        }
        return normalizedSnapshot;
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-recycle-state] Failed to write recycle marker '${normalizedPath}': ${message}`
        );
        throw error;
    } finally {
        if (fileDescriptor !== null) {
            try {
                fs.closeSync(fileDescriptor);
            } catch {
                // Best effort cleanup after a failed write.
            }
        }
        try {
            if (fs.existsSync(temporaryPath)) {
                fs.unlinkSync(temporaryPath);
            }
        } catch {
            // Best effort cleanup after a failed write.
        }
    }
}

export function clearInstanceAgentRecycleMarkerSnapshot(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message),
    expectedRecycleId?: string
): boolean {
    const normalizedPath = path.resolve(filePath);
    try {
        const normalizedExpectedRecycleId = normalizeOptionalText(expectedRecycleId);
        if (normalizedExpectedRecycleId) {
            const currentMarker = readInstanceAgentRecycleMarkerSnapshot(normalizedPath, logger);
            if (!currentMarker) {
                return true;
            }
            if (currentMarker.recycleId !== normalizedExpectedRecycleId) {
                logger(
                    `[instance-agent-recycle-state] Refusing to clear recycle marker '${normalizedPath}' because recycle ${currentMarker.recycleId} replaced expected recycle ${normalizedExpectedRecycleId}.`
                );
                return false;
            }
        }

        fs.unlinkSync(normalizedPath);
        return fsyncContainingDirectoryAfterMetadataChange(normalizedPath, logger);
    } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
            return true;
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-recycle-state] Failed to clear recycle marker '${normalizedPath}': ${message}`
        );
        return false;
    }
}
