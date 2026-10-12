// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { TextDecoder } from 'util';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.8';

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
    helperLaunchId?: string;
    sourceLaunchGenerationId?: string;
    sourceCreationUtc?: string;
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

function normalizeHelperLaunchId(value: unknown): string | undefined {
    const normalized = normalizeOptionalText(value);
    return normalized &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(normalized)
        ? normalized.toLowerCase()
        : undefined;
}

function normalizeLaunchGenerationId(value: unknown): string | undefined {
    const text = normalizeOptionalText(value);
    if (
        !text ||
        !/^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.test(text)
    ) {
        return undefined;
    }
    const normalized = text.replace(/-/g, '').toLowerCase();
    if (!normalized || !/^[0-9a-f]{32}$/.test(normalized) || /^0{32}$/.test(normalized)) {
        return undefined;
    }
    return `${normalized.slice(0, 8)}-${normalized.slice(8, 12)}-${normalized.slice(12, 16)}-${normalized.slice(16, 20)}-${normalized.slice(20)}`;
}

function normalizeExactSourceCreationUtc(value: unknown): string | undefined {
    const normalized = normalizeOptionalText(value);
    return normalized &&
        /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$/.test(normalized) &&
        Number.isFinite(Date.parse(normalized))
        ? normalized
        : undefined;
}

export interface InstanceAgentRecycleSourceLaunchIdentity {
    sourceLaunchGenerationId: string;
    sourceCreationUtc: string;
}

function canonicalLocalPath(value: string): string {
    const canonical = fs.realpathSync.native(value);
    return process.platform === 'win32' ? canonical.toLowerCase() : canonical;
}

// Read one atomic lease snapshot without creating state or running a subprocess.
// The recycler independently revalidates this exact identity under its lock.
export function readInstanceAgentRecycleSourceLaunchIdentity(): InstanceAgentRecycleSourceLaunchIdentity | null {
    let descriptor: number | null = null;
    try {
        const generationId = normalizeLaunchGenerationId(process.env.SCALEWORLD_STACK_LAUNCH_GENERATION);
        if (!generationId) {
            return null;
        }
        const installBase = process.env.SCALEWORLD_INSTALL_BASE?.trim() || 'C:\\PixelStreaming';
        const leasePath = path.join(installBase, 'state', 'stack-launch-lease.json');
        descriptor = fs.openSync(leasePath, 'r');
        const stat = fs.fstatSync(descriptor);
        if (!stat.isFile() || stat.size > 32768) {
            return null;
        }
        const bytes = Buffer.alloc(32769);
        let length = 0;
        while (length < bytes.length) {
            const read = fs.readSync(descriptor, bytes, length, bytes.length - length, null);
            if (read === 0) {
                break;
            }
            length += read;
        }
        if (length > 32768) {
            return null;
        }
        const decodedLease: unknown = JSON.parse(
            new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length))
        );
        if (!decodedLease || typeof decodedLease !== 'object' || Array.isArray(decodedLease)) {
            return null;
        }
        const lease = decodedLease as Record<string, unknown>;
        if (
            lease.schemaVersion !== 1 ||
            (lease.phase !== 'starting' && lease.phase !== 'completed') ||
            normalizeLaunchGenerationId(lease.generationId) !== generationId ||
            typeof lease.repoRoot !== 'string' ||
            canonicalLocalPath(lease.repoRoot) !== canonicalLocalPath(process.cwd())
        ) {
            return null;
        }
        const executablePath = canonicalLocalPath(process.execPath);
        const births = new Set<string>();
        for (const value of [lease.activeNode, lease.completedNode]) {
            if (!value || typeof value !== 'object' || Array.isArray(value)) {
                continue;
            }
            const pin = value as Record<string, unknown>;
            if (
                !pin ||
                pin.pid !== process.pid ||
                typeof pin.name !== 'string' ||
                pin.name.toLowerCase() !== 'node.exe' ||
                typeof pin.executablePath !== 'string' ||
                canonicalLocalPath(pin.executablePath) !== executablePath
            ) {
                continue;
            }
            const creationUtc = normalizeExactSourceCreationUtc(pin.creationUtc);
            if (creationUtc) {
                births.add(creationUtc);
            }
        }
        return births.size === 1
            ? { sourceLaunchGenerationId: generationId, sourceCreationUtc: [...births][0] }
            : null;
    } catch {
        return null;
    } finally {
        if (descriptor !== null) {
            try {
                fs.closeSync(descriptor);
            } catch {
                // Closing the read-only snapshot cannot grant recycle authority.
            }
        }
    }
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
    const helperLaunchId = normalizeHelperLaunchId(value?.helperLaunchId);
    const sourceLaunchGenerationId = normalizeLaunchGenerationId(value?.sourceLaunchGenerationId);
    const sourceCreationUtc = normalizeExactSourceCreationUtc(value?.sourceCreationUtc);
    if (
        (value?.schemaVersion !== LEGACY_RECYCLE_MARKER_SCHEMA_VERSION &&
            value?.schemaVersion !== RECYCLE_MARKER_SCHEMA_VERSION) ||
        !phase ||
        !requestedAtUtc ||
        !reason ||
        !recycleId ||
        sourcePid === null ||
        (value?.helperLaunchId !== undefined && !helperLaunchId) ||
        ((value?.sourceLaunchGenerationId !== undefined || value?.sourceCreationUtc !== undefined) &&
            (!sourceLaunchGenerationId || !sourceCreationUtc)) ||
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
        helperLaunchId,
        sourceLaunchGenerationId,
        sourceCreationUtc,
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
    expectedRecycleId?: string,
    expectedHelperLaunchId?: string
): boolean {
    const normalizedPath = path.resolve(filePath);
    try {
        const normalizedExpectedRecycleId = normalizeOptionalText(expectedRecycleId);
        const normalizedExpectedHelperLaunchId = normalizeHelperLaunchId(expectedHelperLaunchId);
        if (expectedHelperLaunchId !== undefined && !normalizedExpectedHelperLaunchId) {
            logger(
                '[instance-agent-recycle-state] Refusing to clear recycle marker with an invalid expected helper dispatch.'
            );
            return false;
        }
        if (normalizedExpectedRecycleId || normalizedExpectedHelperLaunchId) {
            const currentMarker = readInstanceAgentRecycleMarkerSnapshot(normalizedPath, logger);
            if (!currentMarker) {
                return true;
            }
            if (
                (normalizedExpectedRecycleId && currentMarker.recycleId !== normalizedExpectedRecycleId) ||
                (normalizedExpectedHelperLaunchId &&
                    currentMarker.helperLaunchId !== normalizedExpectedHelperLaunchId)
            ) {
                logger(
                    `[instance-agent-recycle-state] Refusing to clear recycle marker '${normalizedPath}' because its operation or helper dispatch no longer matches the caller.`
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
