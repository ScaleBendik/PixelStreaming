// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

const JOURNAL_SCHEMA_VERSION = 1;
const MAX_IDENTIFIER_LENGTH = 128;

export interface InstanceAgentReconnectGraceElapsedEvidence {
    evidenceId: string;
    sessionRequestId: string;
    activeSessionId?: string;
    lastViewerDisconnectedAtUtc: string;
    reconnectGraceExpiresAtUtc: string;
    phase: 'elapsed';
}

interface InstanceAgentReconnectGraceElapsedEvidenceJournal {
    schemaVersion: typeof JOURNAL_SCHEMA_VERSION;
    evidences: InstanceAgentReconnectGraceElapsedEvidence[];
}

export type InstanceAgentReconnectGraceElapsedEvidenceJournalReadResult =
    | {
          status: 'missing';
          evidences: [];
      }
    | {
          status: 'valid';
          evidences: InstanceAgentReconnectGraceElapsedEvidence[];
      }
    | {
          status: 'invalid';
          evidences: null;
          error: string;
      };

let loggedUnsupportedWindowsDirectorySync = false;

function normalizeIdentifier(value: unknown): string | null {
    if (typeof value !== 'string') {
        return null;
    }

    const normalized = value.trim();
    return normalized.length > 0 && normalized.length <= MAX_IDENTIFIER_LENGTH ? normalized : null;
}

function normalizeUtcTimestamp(value: unknown): string | null {
    if (typeof value !== 'string') {
        return null;
    }

    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}

export function normalizeInstanceAgentReconnectGraceElapsedEvidence(
    value: Partial<InstanceAgentReconnectGraceElapsedEvidence> | null | undefined
): InstanceAgentReconnectGraceElapsedEvidence | null {
    const evidenceId = normalizeIdentifier(value?.evidenceId);
    const sessionRequestId = normalizeIdentifier(value?.sessionRequestId);
    const activeSessionId = normalizeIdentifier(value?.activeSessionId) ?? undefined;
    const lastViewerDisconnectedAtUtc = normalizeUtcTimestamp(value?.lastViewerDisconnectedAtUtc);
    const reconnectGraceExpiresAtUtc = normalizeUtcTimestamp(value?.reconnectGraceExpiresAtUtc);
    if (
        !evidenceId ||
        !sessionRequestId ||
        (value?.activeSessionId !== undefined && !activeSessionId) ||
        !lastViewerDisconnectedAtUtc ||
        !reconnectGraceExpiresAtUtc ||
        value?.phase !== 'elapsed' ||
        Date.parse(reconnectGraceExpiresAtUtc) <= Date.parse(lastViewerDisconnectedAtUtc)
    ) {
        return null;
    }

    return {
        evidenceId,
        sessionRequestId,
        activeSessionId,
        lastViewerDisconnectedAtUtc,
        reconnectGraceExpiresAtUtc,
        phase: 'elapsed'
    };
}

function normalizeJournal(value: unknown): InstanceAgentReconnectGraceElapsedEvidenceJournal | null {
    if (!value || typeof value !== 'object') {
        return null;
    }

    const candidate = value as {
        schemaVersion?: unknown;
        evidences?: unknown;
    };
    if (candidate.schemaVersion !== JOURNAL_SCHEMA_VERSION || !Array.isArray(candidate.evidences)) {
        return null;
    }

    const evidences: InstanceAgentReconnectGraceElapsedEvidence[] = [];
    const evidenceIds = new Set<string>();
    for (const rawEvidence of candidate.evidences) {
        const evidence = normalizeInstanceAgentReconnectGraceElapsedEvidence(
            rawEvidence as Partial<InstanceAgentReconnectGraceElapsedEvidence>
        );
        if (!evidence || evidenceIds.has(evidence.evidenceId)) {
            return null;
        }

        evidenceIds.add(evidence.evidenceId);
        evidences.push(evidence);
    }

    return {
        schemaVersion: JOURNAL_SCHEMA_VERSION,
        evidences
    };
}

export function resolveInstanceAgentReconnectGraceElapsedEvidenceJournalPath(
    desiredStatePath?: string | null
): string {
    const normalizedDesiredStatePath = typeof desiredStatePath === 'string' ? desiredStatePath.trim() : '';
    if (normalizedDesiredStatePath.length > 0) {
        return path.resolve(
            path.dirname(path.resolve(normalizedDesiredStatePath)),
            'instance-agent-reconnect-grace-elapsed-evidence.json'
        );
    }

    return path.resolve(__dirname, '..', 'state', 'instance-agent-reconnect-grace-elapsed-evidence.json');
}

export function inspectInstanceAgentReconnectGraceElapsedEvidenceJournal(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentReconnectGraceElapsedEvidenceJournalReadResult {
    const normalizedPath = path.resolve(filePath);

    try {
        const journal = normalizeJournal(JSON.parse(fs.readFileSync(normalizedPath, 'utf8')) as unknown);
        if (!journal) {
            const error = 'Journal structure, schema, evidence, or evidence-id uniqueness is invalid.';
            logger(
                `[instance-agent-reconnect-grace-evidence-state] Refusing to use invalid elapsed-evidence journal '${normalizedPath}'.`
            );
            return { status: 'invalid', evidences: null, error };
        }

        return { status: 'valid', evidences: journal.evidences };
    } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
            return { status: 'missing', evidences: [] };
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-reconnect-grace-evidence-state] Failed to read elapsed-evidence journal '${normalizedPath}': ${message}`
        );
        return { status: 'invalid', evidences: null, error: message };
    }
}

export function readInstanceAgentReconnectGraceElapsedEvidenceJournal(
    filePath: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentReconnectGraceElapsedEvidence[] | null {
    const result = inspectInstanceAgentReconnectGraceElapsedEvidenceJournal(filePath, logger);
    return result.status === 'invalid' ? null : result.evidences;
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
                    `[instance-agent-reconnect-grace-evidence-state] Directory fsync is unsupported for '${directoryPath}' on this Windows runtime; the journal file itself remains fsynced and atomic rename semantics are retained: ${message}`
                );
            }
            return true;
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-reconnect-grace-evidence-state] Failed to fsync elapsed-evidence journal directory '${directoryPath}': ${message}`
        );
        return false;
    } finally {
        if (directoryDescriptor !== null) {
            try {
                fs.closeSync(directoryDescriptor);
            } catch {
                // Best effort descriptor cleanup. A prior successful fsync remains authoritative.
            }
        }
    }
}

function writeJournalAtomically(
    filePath: string,
    evidences: InstanceAgentReconnectGraceElapsedEvidence[],
    logger: (message: string) => void
): boolean {
    const normalizedPath = path.resolve(filePath);
    const temporaryPath = `${normalizedPath}.${process.pid}.${randomUUID()}.tmp`;
    let fileDescriptor: number | null = null;

    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fileDescriptor = fs.openSync(temporaryPath, 'wx');
        fs.writeFileSync(
            fileDescriptor,
            JSON.stringify(
                {
                    schemaVersion: JOURNAL_SCHEMA_VERSION,
                    evidences
                } satisfies InstanceAgentReconnectGraceElapsedEvidenceJournal,
                null,
                2
            ),
            'utf8'
        );
        fs.fsyncSync(fileDescriptor);
        fs.closeSync(fileDescriptor);
        fileDescriptor = null;
        fs.renameSync(temporaryPath, normalizedPath);
        return fsyncContainingDirectoryAfterMetadataChange(normalizedPath, logger);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-reconnect-grace-evidence-state] Failed to write elapsed-evidence journal '${normalizedPath}': ${message}`
        );
        return false;
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

export function appendInstanceAgentReconnectGraceElapsedEvidence(
    filePath: string,
    value: InstanceAgentReconnectGraceElapsedEvidence,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentReconnectGraceElapsedEvidence[] | null {
    const evidence = normalizeInstanceAgentReconnectGraceElapsedEvidence(value);
    if (!evidence) {
        logger(
            `[instance-agent-reconnect-grace-evidence-state] Refusing to append invalid elapsed evidence to '${path.resolve(filePath)}'.`
        );
        return null;
    }

    const current = readInstanceAgentReconnectGraceElapsedEvidenceJournal(filePath, logger);
    if (!current) {
        return null;
    }

    const existing = current.find((candidate) => candidate.evidenceId === evidence.evidenceId);
    if (existing) {
        if (JSON.stringify(existing) !== JSON.stringify(evidence)) {
            logger(
                `[instance-agent-reconnect-grace-evidence-state] Refusing elapsed evidence id collision '${evidence.evidenceId}'.`
            );
            return null;
        }

        return fsyncContainingDirectoryAfterMetadataChange(filePath, logger) ? current : null;
    }

    const next = [...current, evidence];
    return writeJournalAtomically(filePath, next, logger) ? next : null;
}

export function removeAcknowledgedInstanceAgentReconnectGraceElapsedEvidence(
    filePath: string,
    evidenceId: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentReconnectGraceElapsedEvidence[] | null {
    const normalizedEvidenceId = normalizeIdentifier(evidenceId);
    if (!normalizedEvidenceId) {
        return null;
    }

    const current = readInstanceAgentReconnectGraceElapsedEvidenceJournal(filePath, logger);
    if (!current) {
        return null;
    }

    const acknowledgedIndex = current.findIndex((candidate) => candidate.evidenceId === normalizedEvidenceId);
    if (acknowledgedIndex < 0) {
        return current;
    }

    const next = current.filter((candidate) => candidate.evidenceId !== normalizedEvidenceId);
    if (next.length > 0) {
        return writeJournalAtomically(filePath, next, logger) ? next : null;
    }

    const normalizedPath = path.resolve(filePath);
    try {
        fs.unlinkSync(normalizedPath);
        return fsyncContainingDirectoryAfterMetadataChange(normalizedPath, logger) ? [] : null;
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[instance-agent-reconnect-grace-evidence-state] Failed to remove acknowledged elapsed-evidence journal '${normalizedPath}': ${message}`
        );
        return null;
    }
}

export function rotateInstanceAgentReconnectGraceElapsedEvidenceAfterAttempt(
    filePath: string,
    evidenceId: string,
    logger: (message: string) => void = (message) => Logger.info(message)
): InstanceAgentReconnectGraceElapsedEvidence[] | null {
    const normalizedEvidenceId = normalizeIdentifier(evidenceId);
    if (!normalizedEvidenceId) {
        return null;
    }

    const current = readInstanceAgentReconnectGraceElapsedEvidenceJournal(filePath, logger);
    if (!current) {
        return null;
    }

    const attemptedIndex = current.findIndex((candidate) => candidate.evidenceId === normalizedEvidenceId);
    if (attemptedIndex < 0 || current.length <= 1 || attemptedIndex === current.length - 1) {
        return current;
    }

    const attempted = current[attemptedIndex];
    const next = current.filter((candidate) => candidate.evidenceId !== normalizedEvidenceId);
    next.push(attempted);
    return writeJournalAtomically(filePath, next, logger) ? next : null;
}
