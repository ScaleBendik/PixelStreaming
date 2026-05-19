// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import { readInstanceAgentCommandJournalSnapshot } from './instance-agent-command-state';
import {
    normalizeInstanceAgentDesiredStateSnapshot,
    readInstanceAgentDesiredStateSnapshot
} from './instance-agent-state';

export interface ConnectTicketRuntimeTicket {
    issuedAtEpochSeconds: number | null;
    expiresAtEpochSeconds: number;
    tokenId?: string;
    subject?: string;
}

export interface ConnectTicketTeardownStartOptions {
    occurredAtUtc?: string;
    reason?: string;
    commandType?: string;
    instanceCommandId?: string;
}

export interface ConnectTicketRuntimeGate {
    rejectReasonForTicket(ticket: ConnectTicketRuntimeTicket): string | null;
    markTeardownStarted(options?: ConnectTicketTeardownStartOptions): void;
}

interface ConnectTicketRuntimeStateSnapshot {
    rejectTicketsIssuedAtOrBeforeEpochSeconds?: number;
    rejectTicketsIssuedAtOrBeforeUtc?: string;
    reason?: string;
    commandType?: string;
    instanceCommandId?: string;
    updatedAtUtc?: string;
}

export interface ConnectTicketRuntimeGateOptions {
    statePath?: string;
    desiredStatePath?: string;
    commandJournalPath?: string;
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
        updatedAtUtc: normalizeOptionalText(value?.updatedAtUtc)
    };
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

function readRuntimeStateSnapshot(
    filePath: string,
    logger: (message: string) => void
): ConnectTicketRuntimeStateSnapshot {
    const normalizedPath = path.resolve(filePath);
    if (!fs.existsSync(normalizedPath)) {
        return normalizeRuntimeStateSnapshot(undefined);
    }

    try {
        const raw = fs.readFileSync(normalizedPath, 'utf8');
        return normalizeRuntimeStateSnapshot(JSON.parse(raw) as Partial<ConnectTicketRuntimeStateSnapshot>);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[connect-ticket-runtime-state] Failed to read runtime auth state '${normalizedPath}': ${message}`
        );
        return normalizeRuntimeStateSnapshot(undefined);
    }
}

function writeRuntimeStateSnapshot(
    filePath: string,
    snapshot: ConnectTicketRuntimeStateSnapshot,
    logger: (message: string) => void
): void {
    const normalizedPath = path.resolve(filePath);
    try {
        fs.mkdirSync(path.dirname(normalizedPath), { recursive: true });
        fs.writeFileSync(normalizedPath, JSON.stringify(snapshot, null, 2), 'utf8');
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        logger(
            `[connect-ticket-runtime-state] Failed to write runtime auth state '${normalizedPath}': ${message}`
        );
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

    const markTeardownStarted = (startOptions: ConnectTicketTeardownStartOptions = {}): void => {
        const nowEpochSeconds = Math.floor(Date.now() / 1000);
        const requestedEpochSeconds = parseUtcToEpochSeconds(
            normalizeOptionalText(startOptions.occurredAtUtc)
        );
        const cutoffEpochSeconds = requestedEpochSeconds ?? nowEpochSeconds;
        const currentSnapshot = readRuntimeStateSnapshot(statePath, logger);
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
            updatedAtUtc: new Date().toISOString()
        });

        writeRuntimeStateSnapshot(statePath, nextSnapshot, logger);
    };

    const recoveredCommand = readInstanceAgentCommandJournalSnapshot(commandJournalPath, logger);
    if (isTeardownCommand(recoveredCommand)) {
        markTeardownStarted({
            occurredAtUtc: recoveredCommand?.requestedAtUtc,
            reason: 'recovered_active_teardown_command',
            commandType: recoveredCommand?.commandType,
            instanceCommandId: recoveredCommand?.instanceCommandId
        });
    }

    if (desiredStatePath) {
        const desiredState = readInstanceAgentDesiredStateSnapshot(desiredStatePath, logger);
        const normalizedDesiredState = normalizeInstanceAgentDesiredStateSnapshot(desiredState);
        if (normalizedDesiredState.recycleRequestedToken || normalizedDesiredState.shutdownRequested) {
            markTeardownStarted({
                occurredAtUtc: normalizedDesiredState.updatedAtUtc,
                reason: normalizedDesiredState.recycleRequestedToken
                    ? 'recovered_desired_state_recycle_request'
                    : 'recovered_desired_state_shutdown_request'
            });
        }
    }

    return {
        rejectReasonForTicket(ticket: ConnectTicketRuntimeTicket): string | null {
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

            const state = readRuntimeStateSnapshot(statePath, logger);
            const cutoff = state.rejectTicketsIssuedAtOrBeforeEpochSeconds;
            if (cutoff === undefined) {
                return null;
            }

            if (ticket.issuedAtEpochSeconds === null) {
                return 'Connect ticket cannot be used after session teardown because it has no issue time.';
            }

            if (ticket.issuedAtEpochSeconds <= cutoff) {
                return 'Connect ticket was issued before this session teardown began.';
            }

            return null;
        },
        markTeardownStarted
    };
}
