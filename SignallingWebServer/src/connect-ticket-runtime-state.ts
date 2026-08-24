// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import {
    isInstanceAgentCommandExpired,
    readInstanceAgentCommandJournalSnapshot
} from './instance-agent-command-state';
import {
    normalizeInstanceAgentDesiredStateSnapshot,
    readInstanceAgentDesiredStateSnapshot
} from './instance-agent-state';

export interface ConnectTicketRuntimeTicket {
    issuedAtEpochSeconds: number | null;
    expiresAtEpochSeconds: number;
    tokenId?: string;
    subject?: string;
    sessionRequestId?: string;
}

export interface ConnectTicketTeardownStartOptions {
    occurredAtUtc?: string;
    reason?: string;
    commandType?: string;
    instanceCommandId?: string;
}

export interface ManagedViewerAdmissionIdentity {
    sessionRequestId: string;
    activeSessionId?: string;
}

export type DurableManagedViewerEvidenceStatus = 'none' | 'present' | 'unavailable';

export interface ConnectTicketRuntimeGate {
    rejectReasonForTicket(ticket: ConnectTicketRuntimeTicket): string | null;
    recordManagedViewerAdmission(identity: ManagedViewerAdmissionIdentity): string | null;
    getDurableManagedViewerEvidenceStatus(): DurableManagedViewerEvidenceStatus;
    markTeardownStarted(options?: ConnectTicketTeardownStartOptions): boolean;
    isCommercialRecoveryRequired(): boolean;
    prepareCommercialRecoveryAfterReset(): number | null;
    completeCommercialRecoveryAfterReset(): boolean;
    getCommercialRecoveryReadyNotBeforeEpochSeconds(): number | null;
    getReconnectGraceEvidenceJournalBlockReason(): string | null;
    setReconnectGraceEvidenceJournalBlock(reason: string | null): void;
}

interface ConnectTicketRuntimeStateSnapshot {
    rejectTicketsIssuedAtOrBeforeEpochSeconds?: number;
    rejectTicketsIssuedAtOrBeforeUtc?: string;
    reason?: string;
    commandType?: string;
    instanceCommandId?: string;
    updatedAtUtc?: string;
    commercialRecoveryRequired?: boolean;
    commercialRecoveryReadyNotBeforeEpochSeconds?: number;
    managedViewerSessionRequestId?: string;
    managedViewerActiveSessionId?: string;
    managedViewerFirstAdmittedAtUtc?: string;
}

type ConnectTicketRuntimeStateReadResult =
    | { status: 'missing'; snapshot: ConnectTicketRuntimeStateSnapshot }
    | { status: 'valid'; snapshot: ConnectTicketRuntimeStateSnapshot }
    | { status: 'invalid'; snapshot: null; error: string };

let loggedUnsupportedWindowsDirectorySync = false;

export interface ConnectTicketRuntimeGateOptions {
    statePath?: string;
    desiredStatePath?: string;
    commandJournalPath?: string;
    admissionClockSkewSeconds?: number;
    nowEpochSeconds?: () => number;
    logger?: (message: string) => void;
}

function resolveDefaultDesiredStatePath(): string {
    return path.resolve(__dirname, '..', 'state', 'instance-agent-desired-state.json');
}

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

function normalizeOptionalGuid(value: unknown): string | undefined {
    const normalized = normalizeOptionalText(value);
    return normalized && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(normalized)
        ? normalized.toLowerCase()
        : undefined;
}

function normalizeOptionalEpochSeconds(value: unknown): number | undefined {
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
        return Math.trunc(value);
    }

    if (typeof value !== 'string') {
        return undefined;
    }

    const parsed = Number.parseInt(value.trim(), 10);
    return Number.isNaN(parsed) || parsed < 0 ? undefined : parsed;
}

function parseUtcToEpochSeconds(value: string | undefined): number | null {
    if (!value) {
        return null;
    }

    const parsed = Date.parse(value);
    if (!Number.isFinite(parsed)) {
        return null;
    }

    return Math.floor(parsed / 1000);
}

function toUtcIsoString(epochSeconds: number): string {
    return new Date(epochSeconds * 1000).toISOString();
}

function isTeardownCommand(command: { commandType?: string | null } | null | undefined): boolean {
    const commandType = command?.commandType?.trim().toLowerCase() ?? '';
    return commandType === 'recycletowarm' || commandType === 'shutdown';
}

function normalizeRuntimeStateSnapshot(
    value: Partial<ConnectTicketRuntimeStateSnapshot> | null | undefined
): ConnectTicketRuntimeStateSnapshot {
    const cutoff = normalizeOptionalEpochSeconds(value?.rejectTicketsIssuedAtOrBeforeEpochSeconds);
    return {
        rejectTicketsIssuedAtOrBeforeEpochSeconds: cutoff,
        rejectTicketsIssuedAtOrBeforeUtc:
            normalizeOptionalText(value?.rejectTicketsIssuedAtOrBeforeUtc) ??
            (cutoff === undefined ? undefined : toUtcIsoString(cutoff)),
        reason: normalizeOptionalText(value?.reason),
        commandType: normalizeOptionalText(value?.commandType),
        instanceCommandId: normalizeOptionalText(value?.instanceCommandId),
        updatedAtUtc: normalizeOptionalText(value?.updatedAtUtc),
        commercialRecoveryRequired: value?.commercialRecoveryRequired === true ? true : undefined,
        commercialRecoveryReadyNotBeforeEpochSeconds: normalizeOptionalEpochSeconds(
            value?.commercialRecoveryReadyNotBeforeEpochSeconds
        ),
        managedViewerSessionRequestId: normalizeOptionalGuid(value?.managedViewerSessionRequestId),
        managedViewerActiveSessionId: normalizeOptionalGuid(value?.managedViewerActiveSessionId),
        managedViewerFirstAdmittedAtUtc: normalizeOptionalText(value?.managedViewerFirstAdmittedAtUtc)
    };
}

function parsePersistedRuntimeStateSnapshot(value: unknown): ConnectTicketRuntimeStateSnapshot | null {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
        return null;
    }

    const candidate = value as Record<string, unknown>;
    const cutoff = candidate.rejectTicketsIssuedAtOrBeforeEpochSeconds;
    if (typeof cutoff !== 'number' || !Number.isSafeInteger(cutoff) || cutoff < 0) {
        return null;
    }

    const utc = candidate.rejectTicketsIssuedAtOrBeforeUtc;
    if (utc !== undefined && (typeof utc !== 'string' || parseUtcToEpochSeconds(utc.trim()) !== cutoff)) {
        return null;
    }

    for (const key of ['reason', 'commandType', 'instanceCommandId'] as const) {
        const item = candidate[key];
        if (item !== undefined && (typeof item !== 'string' || item.trim().length === 0)) {
            return null;
        }
    }

    const updatedAtUtc = candidate.updatedAtUtc;
    if (
        updatedAtUtc !== undefined &&
        (typeof updatedAtUtc !== 'string' || !Number.isFinite(Date.parse(updatedAtUtc)))
    ) {
        return null;
    }

    if (
        candidate.commercialRecoveryRequired !== undefined &&
        typeof candidate.commercialRecoveryRequired !== 'boolean'
    ) {
        return null;
    }

    const readyNotBefore = candidate.commercialRecoveryReadyNotBeforeEpochSeconds;
    if (
        readyNotBefore !== undefined &&
        (!Number.isSafeInteger(readyNotBefore) ||
            (readyNotBefore as number) < 0 ||
            candidate.commercialRecoveryRequired !== true ||
            (readyNotBefore as number) < cutoff)
    ) {
        return null;
    }

    const managedViewerSessionRequestId = candidate.managedViewerSessionRequestId;
    const managedViewerActiveSessionId = candidate.managedViewerActiveSessionId;
    const managedViewerFirstAdmittedAtUtc = candidate.managedViewerFirstAdmittedAtUtc;
    const hasAnyManagedViewerEvidenceField =
        managedViewerSessionRequestId !== undefined ||
        managedViewerActiveSessionId !== undefined ||
        managedViewerFirstAdmittedAtUtc !== undefined;
    if (
        hasAnyManagedViewerEvidenceField &&
        (!normalizeOptionalGuid(managedViewerSessionRequestId) ||
            typeof managedViewerFirstAdmittedAtUtc !== 'string' ||
            !Number.isFinite(Date.parse(managedViewerFirstAdmittedAtUtc)))
    ) {
        return null;
    }
    if (managedViewerActiveSessionId !== undefined && !normalizeOptionalGuid(managedViewerActiveSessionId)) {
        return null;
    }

    return normalizeRuntimeStateSnapshot(candidate as Partial<ConnectTicketRuntimeStateSnapshot>);
}

export function resolveConnectTicketRuntimeStatePath(desiredStatePath?: string | null): string {
    const normalizedDesiredStatePath = typeof desiredStatePath === 'string' ? desiredStatePath.trim() : '';
    if (normalizedDesiredStatePath.length > 0) {
        return path.resolve(
            path.dirname(path.resolve(normalizedDesiredStatePath)),
            'connect-ticket-runtime-state.json'
        );
    }

    return path.resolve(__dirname, '..', 'state', 'connect-ticket-runtime-state.json');
}

function resolveCommandJournalPath(desiredStatePath?: string | null): string {
    const normalizedDesiredStatePath = typeof desiredStatePath === 'string' ? desiredStatePath.trim() : '';
    if (normalizedDesiredStatePath.length > 0) {
        return path.resolve(
            path.dirname(path.resolve(normalizedDesiredStatePath)),
            'instance-agent-active-command.json'
        );
    }

    return path.resolve(__dirname, '..', 'state', 'instance-agent-active-command.json');
}

function inspectRuntimeStateSnapshot(
    filePath: string,
    logger: (message: string) => void
): ConnectTicketRuntimeStateReadResult {
    const normalizedPath = path.resolve(filePath);

    try {
        const raw = fs.readFileSync(normalizedPath, 'utf8');
        const snapshot = parsePersistedRuntimeStateSnapshot(JSON.parse(raw) as unknown);
        if (!snapshot) {
            const error = 'Runtime auth state structure or teardown cutoff is invalid.';
            logger(`[connect-ticket-runtime-state] Refusing invalid runtime auth state '${normalizedPath}'.`);
            return { status: 'invalid', snapshot: null, error };
        }

        return { status: 'valid', snapshot };
    } catch (error) {
        if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
            return {
                status: 'missing',
                snapshot: normalizeRuntimeStateSnapshot(undefined)
            };
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[connect-ticket-runtime-state] Failed to read runtime auth state '${normalizedPath}': ${message}`
        );
        return { status: 'invalid', snapshot: null, error: message };
    }
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
                    `[connect-ticket-runtime-state] Directory fsync is unsupported for '${directoryPath}' on this Windows runtime; the cutoff file itself remains fsynced and atomic rename semantics are retained: ${message}`
                );
            }
            return true;
        }

        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[connect-ticket-runtime-state] Failed to fsync runtime auth state directory '${directoryPath}': ${message}`
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

function writeRuntimeStateSnapshot(
    filePath: string,
    snapshot: ConnectTicketRuntimeStateSnapshot,
    logger: (message: string) => void
): boolean {
    const normalizedPath = path.resolve(filePath);
    const temporaryPath = `${normalizedPath}.${process.pid}.${randomUUID()}.tmp`;
    let fileDescriptor: number | null = null;
    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fileDescriptor = fs.openSync(temporaryPath, 'wx');
        fs.writeFileSync(fileDescriptor, JSON.stringify(snapshot, null, 2), 'utf8');
        fs.fsyncSync(fileDescriptor);
        fs.closeSync(fileDescriptor);
        fileDescriptor = null;
        fs.renameSync(temporaryPath, normalizedPath);
        return fsyncContainingDirectoryAfterMetadataChange(normalizedPath, logger);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[connect-ticket-runtime-state] Failed to write runtime auth state '${normalizedPath}': ${message}`
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

export function createConnectTicketRuntimeGate(
    options: ConnectTicketRuntimeGateOptions = {}
): ConnectTicketRuntimeGate {
    const logger = options.logger ?? ((message: string) => Logger.info(message));
    const desiredStatePath =
        normalizeOptionalText(options.desiredStatePath) ?? resolveDefaultDesiredStatePath();
    const statePath =
        normalizeOptionalText(options.statePath) ?? resolveConnectTicketRuntimeStatePath(desiredStatePath);
    const commandJournalPath =
        normalizeOptionalText(options.commandJournalPath) ?? resolveCommandJournalPath(desiredStatePath);
    let initialRuntimeState = inspectRuntimeStateSnapshot(statePath, logger);
    if (initialRuntimeState.status === 'invalid') {
        throw new Error(
            `Connect-ticket runtime auth state '${statePath}' is invalid or unreadable; refusing to start because prior teardown cutoffs cannot be proven.`
        );
    }

    if (initialRuntimeState.status === 'missing') {
        const suppliedInitialEpochSeconds = options.nowEpochSeconds?.();
        const initialEpochSeconds =
            Number.isSafeInteger(suppliedInitialEpochSeconds) && (suppliedInitialEpochSeconds as number) >= 0
                ? (suppliedInitialEpochSeconds as number)
                : Math.floor(Date.now() / 1000);
        const baselineSnapshot = normalizeRuntimeStateSnapshot({
            rejectTicketsIssuedAtOrBeforeEpochSeconds: 0,
            rejectTicketsIssuedAtOrBeforeUtc: toUtcIsoString(0),
            reason: 'runtime_state_initialized',
            updatedAtUtc: toUtcIsoString(initialEpochSeconds)
        });
        if (!writeRuntimeStateSnapshot(statePath, baselineSnapshot, logger)) {
            throw new Error(
                `Connect-ticket runtime auth state '${statePath}' could not be durably initialized; refusing to start.`
            );
        }
        initialRuntimeState = { status: 'valid', snapshot: baselineSnapshot };
    }

    let runtimeStatePersistenceFailureReason: string | null = null;
    let reconnectGraceEvidenceJournalBlockReason: string | null = null;
    let managedSessionRequestId = initialRuntimeState.snapshot.managedViewerSessionRequestId ?? null;
    let runtimeStateFileExpected = true;
    const admissionClockSkewSeconds = Math.max(
        0,
        Math.trunc(
            Number.isFinite(options.admissionClockSkewSeconds)
                ? (options.admissionClockSkewSeconds as number)
                : 5
        )
    );
    const nowEpochSeconds = (): number => {
        const supplied = options.nowEpochSeconds?.();
        return Number.isSafeInteger(supplied) && (supplied as number) >= 0
            ? (supplied as number)
            : Math.floor(Date.now() / 1000);
    };
    const nowUtc = (): string => toUtcIsoString(nowEpochSeconds());

    const markTeardownStarted = (startOptions: ConnectTicketTeardownStartOptions = {}): boolean => {
        const currentEpochSeconds = nowEpochSeconds();
        const requestedEpochSeconds = parseUtcToEpochSeconds(
            normalizeOptionalText(startOptions.occurredAtUtc)
        );
        const cutoffEpochSeconds = requestedEpochSeconds ?? currentEpochSeconds;
        const currentState = inspectRuntimeStateSnapshot(statePath, logger);
        if (
            currentState.status === 'invalid' ||
            (currentState.status === 'missing' && runtimeStateFileExpected)
        ) {
            runtimeStatePersistenceFailureReason =
                'Connect tickets are blocked because the durable teardown cutoff state is missing, invalid, or unreadable.';
            return false;
        }

        const currentSnapshot = currentState.snapshot;
        const currentCutoff = currentSnapshot.rejectTicketsIssuedAtOrBeforeEpochSeconds ?? 0;
        const nextCutoff = Math.max(currentCutoff, cutoffEpochSeconds);
        const nextSnapshot = normalizeRuntimeStateSnapshot({
            ...currentSnapshot,
            rejectTicketsIssuedAtOrBeforeEpochSeconds: nextCutoff,
            rejectTicketsIssuedAtOrBeforeUtc: toUtcIsoString(nextCutoff),
            reason: normalizeOptionalText(startOptions.reason) ?? currentSnapshot.reason,
            commandType: normalizeOptionalText(startOptions.commandType) ?? currentSnapshot.commandType,
            instanceCommandId:
                normalizeOptionalText(startOptions.instanceCommandId) ?? currentSnapshot.instanceCommandId,
            // Every destructive teardown must remain fail-closed through a completed replacement
            // and its admission margin. A caller forgetting the optional hint must never allow a
            // stale cleanup-era JWT into the next customer's runtime.
            commercialRecoveryRequired: true,
            commercialRecoveryReadyNotBeforeEpochSeconds: undefined,
            updatedAtUtc: nowUtc()
        });

        if (!writeRuntimeStateSnapshot(statePath, nextSnapshot, logger)) {
            runtimeStatePersistenceFailureReason =
                'Connect tickets are blocked because the durable teardown cutoff could not be persisted.';
            return false;
        }

        runtimeStateFileExpected = true;
        runtimeStatePersistenceFailureReason = null;
        return true;
    };

    const recoveredCommand = readInstanceAgentCommandJournalSnapshot(commandJournalPath, logger);
    if (isTeardownCommand(recoveredCommand) && !isInstanceAgentCommandExpired(recoveredCommand)) {
        if (
            !markTeardownStarted({
                occurredAtUtc: recoveredCommand?.requestedAtUtc,
                reason: 'recovered_active_teardown_command',
                commandType: recoveredCommand?.commandType,
                instanceCommandId: recoveredCommand?.instanceCommandId
            })
        ) {
            throw new Error(
                'Failed to durably recover the connect-ticket cutoff for an active teardown command.'
            );
        }
    }

    if (desiredStatePath) {
        const desiredState = readInstanceAgentDesiredStateSnapshot(desiredStatePath, logger);
        const normalizedDesiredState = normalizeInstanceAgentDesiredStateSnapshot(desiredState);
        if (normalizedDesiredState.recycleRequestedToken || normalizedDesiredState.shutdownRequested) {
            if (
                !markTeardownStarted({
                    occurredAtUtc: normalizedDesiredState.updatedAtUtc,
                    reason: normalizedDesiredState.recycleRequestedToken
                        ? 'recovered_desired_state_recycle_request'
                        : 'recovered_desired_state_shutdown_request'
                })
            ) {
                throw new Error(
                    'Failed to durably recover the connect-ticket cutoff for desired teardown state.'
                );
            }
        }
    }

    return {
        rejectReasonForTicket(ticket: ConnectTicketRuntimeTicket): string | null {
            if (runtimeStatePersistenceFailureReason) {
                return runtimeStatePersistenceFailureReason;
            }

            const activeCommand = readInstanceAgentCommandJournalSnapshot(commandJournalPath, logger);
            if (isTeardownCommand(activeCommand)) {
                return 'Connect ticket cannot be used while session teardown is in progress.';
            }

            if (desiredStatePath) {
                const desiredState = readInstanceAgentDesiredStateSnapshot(desiredStatePath, logger);
                if (desiredState.recycleRequestedToken || desiredState.shutdownRequested) {
                    return 'Connect ticket cannot be used while session teardown is in progress.';
                }
            }

            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status === 'invalid' || (state.status === 'missing' && runtimeStateFileExpected)) {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because the durable teardown cutoff state is missing, invalid, or unreadable.';
                return runtimeStatePersistenceFailureReason;
            }

            const ticketSessionRequestId = normalizeOptionalText(ticket.sessionRequestId);
            if (
                ticketSessionRequestId &&
                managedSessionRequestId &&
                ticketSessionRequestId.toLowerCase() !== managedSessionRequestId.toLowerCase()
            ) {
                return 'Connect ticket targets a different managed session than this runtime process.';
            }

            const cutoff = state.snapshot.rejectTicketsIssuedAtOrBeforeEpochSeconds;
            if (state.snapshot.commercialRecoveryRequired === true) {
                return 'Connect tickets are blocked until committed commercial session cleanup completes.';
            }
            if (cutoff !== undefined) {
                if (ticket.issuedAtEpochSeconds === null) {
                    return 'Connect ticket cannot be used after session teardown because it has no issue time.';
                }

                if (ticket.issuedAtEpochSeconds <= cutoff) {
                    return 'Connect ticket was issued before this session teardown began.';
                }
            }

            if (ticketSessionRequestId && !managedSessionRequestId) {
                managedSessionRequestId = ticketSessionRequestId;
            }

            return null;
        },
        recordManagedViewerAdmission(identity: ManagedViewerAdmissionIdentity): string | null {
            if (runtimeStatePersistenceFailureReason) {
                return runtimeStatePersistenceFailureReason;
            }

            const sessionRequestId = normalizeOptionalGuid(identity.sessionRequestId);
            const activeSessionId = normalizeOptionalGuid(identity.activeSessionId);
            if (!sessionRequestId || (identity.activeSessionId !== undefined && !activeSessionId)) {
                return 'Managed viewer identity is invalid and cannot be durably admitted.';
            }

            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status !== 'valid') {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because durable managed-viewer evidence is missing, invalid, or unreadable.';
                return runtimeStatePersistenceFailureReason;
            }

            const existingSessionRequestId = state.snapshot.managedViewerSessionRequestId;
            if (
                existingSessionRequestId &&
                existingSessionRequestId.toLowerCase() !== sessionRequestId.toLowerCase()
            ) {
                return 'Connect ticket targets a different managed session than the durable viewer-use evidence for this runtime.';
            }

            const existingActiveSessionId = state.snapshot.managedViewerActiveSessionId;
            if (
                existingActiveSessionId &&
                activeSessionId &&
                existingActiveSessionId.toLowerCase() !== activeSessionId.toLowerCase()
            ) {
                return 'Connect ticket active session conflicts with the durable viewer-use evidence for this runtime.';
            }

            if (
                existingSessionRequestId &&
                (!activeSessionId || existingActiveSessionId?.toLowerCase() === activeSessionId.toLowerCase())
            ) {
                return null;
            }

            const nextSnapshot = normalizeRuntimeStateSnapshot({
                ...state.snapshot,
                managedViewerSessionRequestId: sessionRequestId,
                managedViewerActiveSessionId: existingActiveSessionId ?? activeSessionId,
                managedViewerFirstAdmittedAtUtc: state.snapshot.managedViewerFirstAdmittedAtUtc ?? nowUtc(),
                updatedAtUtc: nowUtc()
            });
            if (!writeRuntimeStateSnapshot(statePath, nextSnapshot, logger)) {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because durable managed-viewer evidence could not be persisted.';
                return runtimeStatePersistenceFailureReason;
            }

            runtimeStatePersistenceFailureReason = null;
            managedSessionRequestId = sessionRequestId;
            return null;
        },
        getDurableManagedViewerEvidenceStatus(): DurableManagedViewerEvidenceStatus {
            if (runtimeStatePersistenceFailureReason) {
                return 'unavailable';
            }

            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status !== 'valid') {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because durable managed-viewer evidence is missing, invalid, or unreadable.';
                return 'unavailable';
            }

            return state.snapshot.managedViewerSessionRequestId ? 'present' : 'none';
        },
        markTeardownStarted,
        isCommercialRecoveryRequired(): boolean {
            if (runtimeStatePersistenceFailureReason) {
                return true;
            }

            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status === 'invalid' || (state.status === 'missing' && runtimeStateFileExpected)) {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because the durable teardown cutoff state is missing, invalid, or unreadable.';
                return true;
            }

            return state.snapshot.commercialRecoveryRequired === true;
        },
        prepareCommercialRecoveryAfterReset(): number | null {
            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status !== 'valid' || state.snapshot.commercialRecoveryRequired !== true) {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because commercial recovery readiness could not be durably prepared.';
                return null;
            }

            const existingReadyNotBefore = state.snapshot.commercialRecoveryReadyNotBeforeEpochSeconds;
            if (existingReadyNotBefore !== undefined) {
                runtimeStatePersistenceFailureReason = null;
                return existingReadyNotBefore;
            }

            const cutoffEpochSeconds = Math.max(
                state.snapshot.rejectTicketsIssuedAtOrBeforeEpochSeconds ?? 0,
                nowEpochSeconds() + admissionClockSkewSeconds
            );
            // The future cutoff rejects a cleanup-era ticket admitted on an API clock that is
            // ahead by the accepted skew. Holding Ready for a second skew interval ensures the
            // first new ticket from an API clock that is equally far behind still has iat > cutoff.
            const readyNotBeforeEpochSeconds = cutoffEpochSeconds + admissionClockSkewSeconds;
            const preparedSnapshot = normalizeRuntimeStateSnapshot({
                ...state.snapshot,
                rejectTicketsIssuedAtOrBeforeEpochSeconds: cutoffEpochSeconds,
                rejectTicketsIssuedAtOrBeforeUtc: toUtcIsoString(cutoffEpochSeconds),
                commercialRecoveryRequired: true,
                commercialRecoveryReadyNotBeforeEpochSeconds: readyNotBeforeEpochSeconds,
                reason: 'commercial_recovery_ready_margin',
                updatedAtUtc: nowUtc()
            });
            if (!writeRuntimeStateSnapshot(statePath, preparedSnapshot, logger)) {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because the recovery-ready ticket cutoff could not be persisted.';
                return null;
            }

            runtimeStateFileExpected = true;
            runtimeStatePersistenceFailureReason = null;
            return readyNotBeforeEpochSeconds;
        },
        completeCommercialRecoveryAfterReset(): boolean {
            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status !== 'valid') {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because commercial recovery state could not be durably completed.';
                return false;
            }

            if (state.snapshot.commercialRecoveryRequired !== true) {
                runtimeStatePersistenceFailureReason = null;
                return true;
            }

            const readyNotBeforeEpochSeconds = state.snapshot.commercialRecoveryReadyNotBeforeEpochSeconds;
            if (readyNotBeforeEpochSeconds === undefined || nowEpochSeconds() <= readyNotBeforeEpochSeconds) {
                return false;
            }

            const completedSnapshot = normalizeRuntimeStateSnapshot({
                ...state.snapshot,
                commercialRecoveryRequired: false,
                commercialRecoveryReadyNotBeforeEpochSeconds: undefined,
                managedViewerSessionRequestId: undefined,
                managedViewerActiveSessionId: undefined,
                managedViewerFirstAdmittedAtUtc: undefined,
                updatedAtUtc: nowUtc()
            });
            if (!writeRuntimeStateSnapshot(statePath, completedSnapshot, logger)) {
                runtimeStatePersistenceFailureReason =
                    'Connect tickets are blocked because commercial recovery completion could not be persisted.';
                return false;
            }

            // The durable cutoff continues to reject every cleanup-era ticket. Release the
            // process-local request ownership only after the recovery latch has been durably
            // cleared so the replacement customer's newer signed ticket can establish ownership.
            managedSessionRequestId = null;
            runtimeStatePersistenceFailureReason = null;
            return true;
        },
        getCommercialRecoveryReadyNotBeforeEpochSeconds(): number | null {
            const state = inspectRuntimeStateSnapshot(statePath, logger);
            if (state.status !== 'valid') {
                return null;
            }

            return state.snapshot.commercialRecoveryReadyNotBeforeEpochSeconds ?? null;
        },
        getReconnectGraceEvidenceJournalBlockReason(): string | null {
            return reconnectGraceEvidenceJournalBlockReason;
        },
        setReconnectGraceEvidenceJournalBlock(reason: string | null): void {
            reconnectGraceEvidenceJournalBlockReason = normalizeOptionalText(reason) ?? null;
        }
    };
}
