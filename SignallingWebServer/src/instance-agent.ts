// Copyright Epic Games, Inc. All Rights Reserved.
import path from 'path';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import type { RuntimeStatusUpdate, SessionNetworkPathReport } from './runtime-status';
import {
    normalizeInstanceAgentDesiredStateSnapshot,
    type InstanceAgentDesiredStateSnapshot,
    writeInstanceAgentDesiredStateSnapshot
} from './instance-agent-state';
import {
    clearInstanceAgentRecycleMarkerSnapshot,
    readInstanceAgentRecycleMarkerSnapshot,
    resolveInstanceAgentRecycleMarkerPath,
    type InstanceAgentRecycleMarkerSnapshot
} from './instance-agent-recycle-state';
import {
    clearInstanceAgentCommandJournalSnapshot,
    readInstanceAgentCommandJournalSnapshot,
    resolveInstanceAgentCommandJournalPath,
    writeInstanceAgentCommandJournalSnapshot,
    type InstanceAgentCommandExecutionStatus,
    type InstanceAgentCommandJournalSnapshot
} from './instance-agent-command-state';
import {
    createSessionLogArtifactManager,
    type SessionLogArtifactManager,
    type SessionLogArtifactRegistrationRequest,
    type SessionLogArtifactRuntimeOptions
} from './session-log-artifacts';

const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';
const IMDS_DYNAMIC_BASE_URL = 'http://169.254.169.254/latest/dynamic/instance-identity';
const DEFAULT_HEARTBEAT_MS = 10_000;
const DEFAULT_FAST_POLLING_INTERVAL_MS = 2_000;
const DEFAULT_FAST_POLLING_WINDOW_MS = 20_000;
const DEFAULT_DESIRED_STATE_PATH = path.resolve(
    __dirname,
    '..',
    'state',
    'instance-agent-desired-state.json'
);
const MAX_PENDING_EVENTS = 100;

interface InstanceAgentBootstrapResponse {
    agentToken: string;
    tokenExpiresAtUtc: string;
    heartbeatIntervalSeconds: number;
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
    commands?: InstanceAgentCommandResponse[];
}

interface InstanceAgentHeartbeatResponse {
    tokenExpiresAtUtc: string;
    heartbeatIntervalSeconds: number;
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
    commands?: InstanceAgentCommandResponse[];
}

interface InstanceAgentEventBatchResponse {
    acceptedCount: number;
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
    commands?: InstanceAgentCommandResponse[];
}

interface InstanceAgentCommandStatusResponse {
    accepted: boolean;
    commandStatus: string;
    recordedAtUtc: string;
}

interface InstanceAgentArtifactRegistrationResponse {
    artifactId: string;
    sessionRequestId: string;
    userSessionId?: string;
    registeredAtUtc: string;
}

interface InstanceAgentCommandResponse {
    instanceCommandId: string;
    instanceId: string;
    region: string;
    sessionRequestId?: string;
    commandType: string;
    idempotencyKey: string;
    requestedAtUtc: string;
    timeoutAtUtc?: string;
    payloadJson?: string;
}

interface BootstrapIdentity {
    instanceId: string;
    region: string;
    identityDocumentJson?: string;
    identitySignature?: string;
}

interface PendingInstanceAgentEvent {
    eventType: string;
    occurredAtUtc: string;
    sessionId?: string;
    metadata: Record<string, string>;
}

interface InstanceAgentRuntimeSnapshot {
    status?: string;
    reason?: string;
    version?: string;
}

export interface InstanceAgentDesiredStateListenerContext {
    source: string;
}

export interface InstanceAgentCommand {
    instanceCommandId: string;
    instanceId: string;
    region: string;
    sessionRequestId?: string;
    commandType: string;
    idempotencyKey: string;
    requestedAtUtc: string;
    timeoutAtUtc?: string;
    payloadJson?: string;
}

export interface InstanceAgentCommandListenerContext {
    source: string;
}

export interface InstanceAgentCommandTransitionResult {
    accepted: boolean;
    commandStatus: string;
    recordedAtUtc: string;
}

export type InstanceAgentDesiredStateListener = (
    desiredState: InstanceAgentDesiredStateSnapshot,
    context: InstanceAgentDesiredStateListenerContext
) => void;

export type InstanceAgentCommandListener = (
    command: InstanceAgentCommand,
    context: InstanceAgentCommandListenerContext
) => void;

export interface InstanceAgentClient {
    recordRuntimeStatus(update: RuntimeStatusUpdate): void;
    recordSessionNetworkPath(update: SessionNetworkPathReport): void;
    getDesiredState(): InstanceAgentDesiredStateSnapshot;
    getActiveCommand(): InstanceAgentCommandJournalSnapshot | null;
    addDesiredStateListener(listener: InstanceAgentDesiredStateListener): () => void;
    addCommandListener(listener: InstanceAgentCommandListener): () => void;
    acknowledgeCommand(
        command: InstanceAgentCommand,
        options?: { occurredAtUtc?: string }
    ): Promise<InstanceAgentCommandTransitionResult>;
    startCommand(
        command: InstanceAgentCommand,
        options?: { occurredAtUtc?: string }
    ): Promise<InstanceAgentCommandTransitionResult>;
    completeCommand(
        command: Pick<InstanceAgentCommand, 'instanceCommandId' | 'instanceId' | 'region'>,
        options?: { occurredAtUtc?: string; resultJson?: string }
    ): Promise<InstanceAgentCommandTransitionResult>;
    failCommand(
        command: Pick<InstanceAgentCommand, 'instanceCommandId' | 'instanceId' | 'region'>,
        options: {
            failureCode: string;
            failureMessage?: string;
            terminalStatus?: string;
            occurredAtUtc?: string;
        }
    ): Promise<InstanceAgentCommandTransitionResult>;
    captureSessionLogArtifact(
        trigger: string,
        command:
            | Pick<
                  InstanceAgentCommand,
                  'instanceCommandId' | 'commandType' | 'sessionRequestId' | 'requestedAtUtc'
              >
            | Pick<
                  InstanceAgentCommandJournalSnapshot,
                  'instanceCommandId' | 'commandType' | 'sessionRequestId' | 'requestedAtUtc'
              >
            | null
            | undefined,
        metadata?: Record<string, unknown>
    ): Promise<void>;
    requestFastPolling(reason: string, options?: { durationMs?: number; intervalMs?: number }): void;
}

export interface InstanceAgentClientOptions {
    enabled?: boolean;
    apiBaseUrl?: string;
    bootstrapSharedSecret?: string;
    instanceId?: string;
    region?: string;
    lane?: string;
    routeKey?: string;
    scopeValue?: string;
    agentVersion?: string;
    runtimeVersion?: string;
    heartbeatMs?: number;
    desiredStatePath?: string;
    sessionLogArtifacts?: SessionLogArtifactRuntimeOptions;
    logger?: (message: string) => void;
}

function parseBoolean(rawValue: unknown, fallback: boolean): boolean {
    if (typeof rawValue === 'boolean') return rawValue;
    if (typeof rawValue !== 'string') return fallback;
    switch (rawValue.trim().toLowerCase()) {
        case '1':
        case 'true':
        case 'yes':
        case 'on':
            return true;
        case '0':
        case 'false':
        case 'no':
        case 'off':
            return false;
        default:
            return fallback;
    }
}

function parseNonNegativeInteger(rawValue: unknown, fallback: number): number {
    if (rawValue === undefined || rawValue === null || rawValue === '') return fallback;

    if (typeof rawValue === 'number') {
        return Number.isFinite(rawValue) && rawValue >= 0 ? Math.trunc(rawValue) : fallback;
    }

    if (typeof rawValue !== 'string') {
        return fallback;
    }

    const parsed = Number.parseInt(rawValue, 10);
    return Number.isNaN(parsed) || parsed < 0 ? fallback : parsed;
}

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

function normalizeEventMetadata(value: Record<string, unknown>): Record<string, string> {
    const normalized: Record<string, string> = {};
    for (const [key, item] of Object.entries(value)) {
        const normalizedKey = normalizeOptionalText(key);
        if (!normalizedKey) {
            continue;
        }

        if (item === undefined || item === null) {
            continue;
        }

        if (typeof item === 'string') {
            const normalizedValue = normalizeOptionalText(item);
            if (normalizedValue) {
                normalized[normalizedKey] = normalizedValue;
            }
            continue;
        }

        if (typeof item === 'number' || typeof item === 'boolean' || typeof item === 'bigint') {
            normalized[normalizedKey] = String(item);
        }
    }

    return normalized;
}

function normalizeCommand(
    value: InstanceAgentCommandResponse | null | undefined
): InstanceAgentCommand | null {
    const instanceCommandId = normalizeOptionalText(value?.instanceCommandId);
    const instanceId = normalizeOptionalText(value?.instanceId);
    const region = normalizeOptionalText(value?.region);
    const commandType = normalizeOptionalText(value?.commandType);
    const idempotencyKey = normalizeOptionalText(value?.idempotencyKey);
    const requestedAtUtc = normalizeOptionalText(value?.requestedAtUtc);
    if (!instanceCommandId || !instanceId || !region || !commandType || !idempotencyKey || !requestedAtUtc) {
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
        payloadJson: normalizeOptionalText(value?.payloadJson)
    };
}

function truncateDiagnosticText(value: string, maxLength = 240): string {
    const normalized = value.replace(/\s+/g, ' ').trim();
    if (normalized.length <= maxLength) {
        return normalized;
    }

    return `${normalized.slice(0, maxLength - 3)}...`;
}

function isTerminalCommandStatus(value: string | null | undefined): boolean {
    const normalized = normalizeOptionalText(value)?.toLowerCase();
    return (
        normalized === 'completed' ||
        normalized === 'failed' ||
        normalized === 'timedout' ||
        normalized === 'timed_out' ||
        normalized === 'timeout' ||
        normalized === 'cancelled' ||
        normalized === 'canceled'
    );
}

function normalizeOpenCommandExecutionStatus(
    value: string | null | undefined
): InstanceAgentCommandExecutionStatus | null {
    const normalized = normalizeOptionalText(value)?.toLowerCase();
    if (normalized === 'acked') {
        return 'acked';
    }

    if (normalized === 'running') {
        return 'running';
    }

    return null;
}

function isRecycleToWarmCommand(
    command:
        | Pick<InstanceAgentCommand, 'commandType'>
        | Pick<InstanceAgentCommandJournalSnapshot, 'commandType'>
        | null
        | undefined
): boolean {
    return normalizeOptionalText(command?.commandType)?.toLowerCase() === 'recycletowarm';
}

async function describeErrorResponse(response: Response, action: string): Promise<string> {
    const responseUrl = normalizeOptionalText(response.url) ?? 'unknown URL';
    const contentType = normalizeOptionalText(response.headers.get('content-type')) ?? '';
    const responseText = await response.text();

    let detail: string | undefined;
    if (contentType.toLowerCase().includes('application/json')) {
        try {
            const parsed = JSON.parse(responseText) as { message?: unknown };
            detail = normalizeOptionalText(
                typeof parsed.message === 'string' ? parsed.message : responseText
            );
        } catch {
            detail = normalizeOptionalText(responseText);
        }
    } else {
        detail = normalizeOptionalText(responseText);
    }

    const isHtmlResponse =
        contentType.toLowerCase().includes('text/html') ||
        /^<!doctype html\b/i.test(responseText.trim()) ||
        /^<html\b/i.test(responseText.trim());

    const likelyWrongBaseUrl = response.status === 404 || response.status === 405 || isHtmlResponse;

    const hint = likelyWrongBaseUrl
        ? ' Check INSTANCE_AGENT_API_BASE_URL; it may point to the web app, a wrong host, or a tunnel/proxy that is not routing to the API.'
        : '';

    return `${action} failed with status ${response.status} at ${responseUrl}.${detail ? ` ${truncateDiagnosticText(detail)}` : ''}${hint}`;
}

async function readImdsToken(): Promise<string> {
    const response = await fetch(IMDS_TOKEN_URL, {
        method: 'PUT',
        headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' }
    });
    if (!response.ok) throw new Error(`IMDSv2 token request failed with status ${response.status}.`);
    return response.text();
}

async function readImdsValue(pathSuffix: string, token: string): Promise<string> {
    const response = await fetch(`${IMDS_METADATA_BASE_URL}/${pathSuffix}`, {
        headers: { 'X-aws-ec2-metadata-token': token }
    });
    if (!response.ok) throw new Error(`IMDS read for '${pathSuffix}' failed with status ${response.status}.`);
    return response.text();
}

async function readImdsDynamicValue(pathSuffix: string, token: string): Promise<string> {
    const response = await fetch(`${IMDS_DYNAMIC_BASE_URL}/${pathSuffix}`, {
        headers: { 'X-aws-ec2-metadata-token': token }
    });
    if (!response.ok) {
        throw new Error(`IMDS dynamic read for '${pathSuffix}' failed with status ${response.status}.`);
    }

    return response.text();
}

export function wireInstanceAgent(
    server: SignallingServer,
    options: InstanceAgentClientOptions = {}
): InstanceAgentClient | null {
    const log = options.logger ?? ((message: string) => Logger.info(message));
    const enabled = parseBoolean(options.enabled ?? process.env.INSTANCE_AGENT_ENABLED ?? false, false);
    const apiBaseUrl = normalizeOptionalText(options.apiBaseUrl ?? process.env.INSTANCE_AGENT_API_BASE_URL);
    if (!enabled || !apiBaseUrl) {
        if (enabled) {
            log('[instance-agent] Disabled because no API base URL was configured.');
        } else {
            log('[instance-agent] Disabled.');
        }
        return null;
    }

    const bootstrapSharedSecret = normalizeOptionalText(
        options.bootstrapSharedSecret ?? process.env.INSTANCE_AGENT_BOOTSTRAP_SHARED_SECRET
    );
    const configuredInstanceId = normalizeOptionalText(
        options.instanceId ?? process.env.INSTANCE_AGENT_INSTANCE_ID
    );
    const configuredRegion = normalizeOptionalText(options.region ?? process.env.INSTANCE_AGENT_REGION);
    const configuredLane = normalizeOptionalText(options.lane ?? process.env.INSTANCE_AGENT_LANE);
    const configuredRouteKey = normalizeOptionalText(
        options.routeKey ?? process.env.INSTANCE_AGENT_ROUTE_KEY
    );
    const configuredScopeValue = normalizeOptionalText(
        options.scopeValue ?? process.env.INSTANCE_AGENT_SCOPE_VALUE
    );
    const configuredAgentVersion = normalizeOptionalText(
        options.agentVersion ?? process.env.INSTANCE_AGENT_VERSION
    );
    const configuredRuntimeVersion = normalizeOptionalText(
        options.runtimeVersion ?? process.env.INSTANCE_AGENT_RUNTIME_VERSION
    );
    const desiredStatePath =
        normalizeOptionalText(options.desiredStatePath ?? process.env.INSTANCE_AGENT_DESIRED_STATE_PATH) ??
        DEFAULT_DESIRED_STATE_PATH;
    const recycleMarkerPath = resolveInstanceAgentRecycleMarkerPath(desiredStatePath);
    const commandJournalPath = resolveInstanceAgentCommandJournalPath(desiredStatePath);
    const explicitHeartbeatMs = parseNonNegativeInteger(
        options.heartbeatMs ?? process.env.INSTANCE_AGENT_HEARTBEAT_MS,
        0
    );

    let currentDesiredState = writeInstanceAgentDesiredStateSnapshot(desiredStatePath, {}, log);
    let pendingRecycleCompletion: InstanceAgentRecycleMarkerSnapshot | null =
        readInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
    let activeCommand = readInstanceAgentCommandJournalSnapshot(commandJournalPath, log);
    let recoveredActiveCommandId = activeCommand?.instanceCommandId ?? null;
    let bootstrapIdentityPromise: Promise<BootstrapIdentity> | null = null;
    let bootstrapPromise: Promise<void> | null = null;
    let tickInFlight = false;
    let heartbeatTimer: NodeJS.Timeout | null = null;
    let configuredHeartbeatMs = explicitHeartbeatMs > 0 ? explicitHeartbeatMs : DEFAULT_HEARTBEAT_MS;
    let heartbeatMs = configuredHeartbeatMs;
    let fastPollingIntervalMs = DEFAULT_FAST_POLLING_INTERVAL_MS;
    let fastPollingUntil = 0;
    let fastPollingRestoreTimer: NodeJS.Timeout | null = null;
    let token: string | null = null;
    let runtimeSnapshot: InstanceAgentRuntimeSnapshot = {};
    let pendingEvents: PendingInstanceAgentEvent[] = [];
    let resetInProgress = false;
    let artifactManager: SessionLogArtifactManager | null = null;
    const desiredStateListeners = new Set<InstanceAgentDesiredStateListener>();
    const commandListeners = new Set<InstanceAgentCommandListener>();

    if (pendingRecycleCompletion) {
        log(
            `[instance-agent] Pending recycle marker detected (${pendingRecycleCompletion.recycleId ?? 'unknown'}). Waiting for ready state before emitting reset completion.`
        );
    }

    if (activeCommand) {
        log(
            `[instance-agent] Recovered active command ${activeCommand.instanceCommandId} (${activeCommand.commandType}, status=${activeCommand.status}, attempt=${activeCommand.attemptNumber}).`
        );
    }

    const queueEvent = (eventType: string, metadata: Record<string, unknown>, sessionId?: string): void => {
        pendingEvents.push({
            eventType,
            occurredAtUtc: new Date().toISOString(),
            sessionId: normalizeOptionalText(sessionId),
            metadata: normalizeEventMetadata(metadata)
        });

        if (pendingEvents.length > MAX_PENDING_EVENTS) {
            pendingEvents = pendingEvents.slice(pendingEvents.length - MAX_PENDING_EVENTS);
        }
    };

    const persistActiveCommand = (
        command: InstanceAgentCommand,
        status: InstanceAgentCommandExecutionStatus,
        occurredAtUtc: string
    ): InstanceAgentCommandJournalSnapshot | null => {
        const normalizedOccurredAtUtc = normalizeOptionalText(occurredAtUtc) ?? new Date().toISOString();
        const previousCommand = activeCommand;
        const isSameCommand = previousCommand?.instanceCommandId === command.instanceCommandId;
        const attemptNumber = isSameCommand
            ? (previousCommand?.attemptNumber ?? 1)
            : (previousCommand?.attemptNumber ?? 0) + 1;

        activeCommand = writeInstanceAgentCommandJournalSnapshot(
            commandJournalPath,
            {
                instanceCommandId: command.instanceCommandId,
                instanceId: command.instanceId,
                region: command.region,
                sessionRequestId: command.sessionRequestId,
                commandType: command.commandType,
                idempotencyKey: command.idempotencyKey,
                requestedAtUtc: command.requestedAtUtc,
                timeoutAtUtc: command.timeoutAtUtc,
                payloadJson: command.payloadJson,
                status,
                attemptNumber: Math.max(1, attemptNumber),
                ackedAtUtc:
                    status === 'acked'
                        ? normalizedOccurredAtUtc
                        : (previousCommand?.ackedAtUtc ?? normalizedOccurredAtUtc),
                startedAtUtc: status === 'running' ? normalizedOccurredAtUtc : previousCommand?.startedAtUtc
            },
            log
        );

        return activeCommand;
    };

    const clearActiveCommand = (): void => {
        activeCommand = null;
        recoveredActiveCommandId = null;
        clearInstanceAgentCommandJournalSnapshot(commandJournalPath, log);
    };

    const applyDesiredState = (
        value: Partial<InstanceAgentDesiredStateSnapshot> | null | undefined,
        source: string
    ): void => {
        const nextState = normalizeInstanceAgentDesiredStateSnapshot({
            ...value,
            receivedAtUtc: new Date().toISOString()
        });
        const changed =
            nextState.warmHoldEnabled !== currentDesiredState.warmHoldEnabled ||
            nextState.drainEnabled !== currentDesiredState.drainEnabled ||
            nextState.shutdownRequested !== currentDesiredState.shutdownRequested ||
            nextState.recycleRequestedToken !== currentDesiredState.recycleRequestedToken ||
            nextState.policyVersion !== currentDesiredState.policyVersion ||
            nextState.message !== currentDesiredState.message;

        currentDesiredState = writeInstanceAgentDesiredStateSnapshot(desiredStatePath, nextState, log);
        if (changed) {
            queueEvent('desired_state_updated', {
                warmHoldEnabled: nextState.warmHoldEnabled,
                drainEnabled: nextState.drainEnabled,
                shutdownRequested: nextState.shutdownRequested,
                recycleRequestedToken: nextState.recycleRequestedToken,
                policyVersion: nextState.policyVersion,
                message: nextState.message
            });
            log(
                `[instance-agent] Desired state updated from ${source}: warmHold=${currentDesiredState.warmHoldEnabled}, drain=${currentDesiredState.drainEnabled}, shutdown=${currentDesiredState.shutdownRequested}, recycleRequested=${currentDesiredState.recycleRequestedToken ? 'true' : 'false'}, policy=${currentDesiredState.policyVersion}.`
            );

            for (const listener of desiredStateListeners) {
                try {
                    listener(currentDesiredState, { source });
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(`[instance-agent] Desired-state listener failed: ${message}`);
                }
            }
        }
    };

    const applyCommands = (
        values: InstanceAgentCommandResponse[] | null | undefined,
        source: string
    ): void => {
        if (!Array.isArray(values) || values.length === 0) {
            return;
        }

        for (const rawCommand of values) {
            const command = normalizeCommand(rawCommand);
            if (!command) {
                continue;
            }

            queueEvent('instance_command_received', {
                instanceCommandId: command.instanceCommandId,
                commandType: command.commandType,
                idempotencyKey: command.idempotencyKey,
                sessionRequestId: command.sessionRequestId,
                timeoutAtUtc: command.timeoutAtUtc
            });
            log(
                `[instance-agent] Command received from ${source}: id=${command.instanceCommandId}, type=${command.commandType}, key=${command.idempotencyKey}.`
            );

            for (const listener of commandListeners) {
                try {
                    listener(command, { source });
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(`[instance-agent] Command listener failed: ${message}`);
                }
            }
        }
    };

    const getEffectiveHeartbeatMs = (): number => {
        if (Date.now() < fastPollingUntil) {
            return Math.max(1_000, Math.min(configuredHeartbeatMs, fastPollingIntervalMs));
        }

        return configuredHeartbeatMs;
    };

    const clearFastPollingRestoreTimer = (): void => {
        if (!fastPollingRestoreTimer) {
            return;
        }

        clearTimeout(fastPollingRestoreTimer);
        fastPollingRestoreTimer = null;
    };

    const scheduleFastPollingRestore = (): void => {
        clearFastPollingRestoreTimer();
        if (fastPollingUntil <= Date.now()) {
            fastPollingUntil = 0;
            if (heartbeatTimer && heartbeatMs !== configuredHeartbeatMs) {
                scheduleHeartbeat(configuredHeartbeatMs);
            }
            return;
        }

        fastPollingRestoreTimer = setTimeout(
            () => {
                fastPollingRestoreTimer = null;
                fastPollingUntil = 0;
                scheduleHeartbeat(configuredHeartbeatMs);
            },
            Math.max(250, fastPollingUntil - Date.now())
        );
    };

    const scheduleHeartbeat = (nextHeartbeatMs: number): void => {
        configuredHeartbeatMs = Math.max(1_000, nextHeartbeatMs);
        const normalizedHeartbeatMs = getEffectiveHeartbeatMs();
        if (heartbeatTimer && heartbeatMs === normalizedHeartbeatMs) {
            return;
        }

        heartbeatMs = normalizedHeartbeatMs;
        if (heartbeatTimer) {
            clearInterval(heartbeatTimer);
        }

        heartbeatTimer = setInterval(() => {
            void runTick();
        }, heartbeatMs);
    };

    const requestFastPolling = (
        reason: string,
        options: { durationMs?: number; intervalMs?: number } = {}
    ): void => {
        const normalizedReason = normalizeOptionalText(reason) ?? 'unspecified';
        const durationMs = Math.max(1_000, options.durationMs ?? DEFAULT_FAST_POLLING_WINDOW_MS);
        const intervalMs = Math.max(1_000, options.intervalMs ?? DEFAULT_FAST_POLLING_INTERVAL_MS);
        const nextFastPollingUntil = Date.now() + durationMs;
        const nextIntervalMs = Math.min(fastPollingIntervalMs, intervalMs);
        const fastPollingChanged =
            nextFastPollingUntil > fastPollingUntil || nextIntervalMs !== fastPollingIntervalMs;

        fastPollingUntil = Math.max(fastPollingUntil, nextFastPollingUntil);
        fastPollingIntervalMs = nextIntervalMs;
        scheduleFastPollingRestore();

        if (fastPollingChanged || heartbeatMs > getEffectiveHeartbeatMs()) {
            log(
                `[instance-agent] Fast polling enabled for ${durationMs} ms at ${getEffectiveHeartbeatMs()} ms interval (reason=${normalizedReason}).`
            );
            scheduleHeartbeat(configuredHeartbeatMs);
        }

        void runTick();
    };

    const resolveBootstrapIdentity = async (): Promise<BootstrapIdentity> => {
        if (configuredInstanceId && configuredRegion) {
            return {
                instanceId: configuredInstanceId,
                region: configuredRegion
            };
        }

        if (!bootstrapIdentityPromise) {
            bootstrapIdentityPromise = (async () => {
                const tokenValue = await readImdsToken();
                const [instanceId, region, identityDocumentJson, identitySignature] = await Promise.all([
                    readImdsValue('instance-id', tokenValue),
                    readImdsValue('placement/region', tokenValue),
                    readImdsDynamicValue('document', tokenValue),
                    readImdsDynamicValue('signature', tokenValue)
                ]);

                return {
                    instanceId: instanceId.trim(),
                    region: region.trim(),
                    identityDocumentJson: identityDocumentJson.trim(),
                    identitySignature: identitySignature.trim()
                };
            })().catch((error) => {
                bootstrapIdentityPromise = null;
                throw error;
            });
        }

        return bootstrapIdentityPromise;
    };

    const parseJsonResponse = async <TResponse>(response: Response): Promise<TResponse> => {
        const text = await response.text();
        return text.length > 0 ? (JSON.parse(text) as TResponse) : ({} as TResponse);
    };

    const authorizedFetch = async (
        relativePath: string,
        method: 'POST',
        body: unknown
    ): Promise<Response> => {
        if (!token) {
            throw new Error('Instance agent token is not available.');
        }

        return fetch(new URL(relativePath, apiBaseUrl).toString(), {
            method,
            headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${token}`
            },
            body: JSON.stringify(body)
        });
    };

    const postCommandTransition = async <TRequest>(
        relativePath: string,
        body: TRequest,
        action: string
    ): Promise<InstanceAgentCommandTransitionResult> => {
        await ensureBootstrap();
        const response = await authorizedFetch(relativePath, 'POST', body);
        if (!response.ok) {
            throw new Error(await describeErrorResponse(response, action));
        }

        const payload = await parseJsonResponse<InstanceAgentCommandStatusResponse>(response);
        return {
            accepted: payload.accepted === true,
            commandStatus: normalizeOptionalText(payload.commandStatus) ?? 'Unknown',
            recordedAtUtc: normalizeOptionalText(payload.recordedAtUtc) ?? new Date().toISOString()
        };
    };

    const acknowledgeCommand = async (
        command: InstanceAgentCommand,
        options: { occurredAtUtc?: string } = {}
    ): Promise<InstanceAgentCommandTransitionResult> => {
        const occurredAtUtc = normalizeOptionalText(options.occurredAtUtc) ?? new Date().toISOString();
        const result = await postCommandTransition(
            '/agent/commands/ack',
            {
                instanceId: command.instanceId,
                region: command.region,
                instanceCommandId: command.instanceCommandId,
                occurredAtUtc
            },
            'Command acknowledgement'
        );

        if (result.accepted) {
            persistActiveCommand(command, 'acked', result.recordedAtUtc);
            queueEvent('instance_command_acknowledged', {
                instanceCommandId: command.instanceCommandId,
                commandType: command.commandType,
                commandStatus: result.commandStatus,
                attemptNumber: activeCommand?.attemptNumber
            });
            log(
                `[instance-agent] Command acknowledged: id=${command.instanceCommandId}, type=${command.commandType}, status=${result.commandStatus}.`
            );
        } else {
            const recoveredStatus = normalizeOpenCommandExecutionStatus(result.commandStatus);
            if (recoveredStatus) {
                persistActiveCommand(command, recoveredStatus, result.recordedAtUtc);
                log(
                    `[instance-agent] Recovered open command state during acknowledgement: id=${command.instanceCommandId}, type=${command.commandType}, status=${result.commandStatus}.`
                );
            }
        }

        return result;
    };

    const startCommand = async (
        command: InstanceAgentCommand,
        options: { occurredAtUtc?: string } = {}
    ): Promise<InstanceAgentCommandTransitionResult> => {
        const occurredAtUtc = normalizeOptionalText(options.occurredAtUtc) ?? new Date().toISOString();
        const result = await postCommandTransition(
            '/agent/commands/start',
            {
                instanceId: command.instanceId,
                region: command.region,
                instanceCommandId: command.instanceCommandId,
                occurredAtUtc
            },
            'Command start'
        );

        if (result.accepted) {
            persistActiveCommand(command, 'running', result.recordedAtUtc);
            queueEvent('instance_command_started', {
                instanceCommandId: command.instanceCommandId,
                commandType: command.commandType,
                commandStatus: result.commandStatus,
                attemptNumber: activeCommand?.attemptNumber
            });
            log(
                `[instance-agent] Command started: id=${command.instanceCommandId}, type=${command.commandType}, status=${result.commandStatus}.`
            );
        } else if (normalizeOpenCommandExecutionStatus(result.commandStatus) === 'running') {
            persistActiveCommand(command, 'running', result.recordedAtUtc);
            log(
                `[instance-agent] Recovered running command state during start: id=${command.instanceCommandId}, type=${command.commandType}, status=${result.commandStatus}.`
            );
        }

        return result;
    };

    const completeCommand = async (
        command: Pick<InstanceAgentCommand, 'instanceCommandId' | 'instanceId' | 'region'>,
        options: { occurredAtUtc?: string; resultJson?: string } = {}
    ): Promise<InstanceAgentCommandTransitionResult> => {
        const occurredAtUtc = normalizeOptionalText(options.occurredAtUtc) ?? new Date().toISOString();
        const result = await postCommandTransition(
            '/agent/commands/complete',
            {
                instanceId: command.instanceId,
                region: command.region,
                instanceCommandId: command.instanceCommandId,
                occurredAtUtc,
                resultJson: options.resultJson
            },
            'Command completion'
        );

        if (result.accepted || isTerminalCommandStatus(result.commandStatus)) {
            queueEvent('instance_command_completed', {
                instanceCommandId: command.instanceCommandId,
                commandStatus: result.commandStatus
            });
            clearActiveCommand();
            log(
                `[instance-agent] Command completed: id=${command.instanceCommandId}, status=${result.commandStatus}.`
            );
        }

        return result;
    };

    const failCommand = async (
        command: Pick<InstanceAgentCommand, 'instanceCommandId' | 'instanceId' | 'region'>,
        options: {
            failureCode: string;
            failureMessage?: string;
            terminalStatus?: string;
            occurredAtUtc?: string;
        }
    ): Promise<InstanceAgentCommandTransitionResult> => {
        const failureCode = normalizeOptionalText(options.failureCode);
        if (!failureCode) {
            throw new Error('failureCode is required to fail an instance command.');
        }

        const occurredAtUtc = normalizeOptionalText(options.occurredAtUtc) ?? new Date().toISOString();
        const result = await postCommandTransition(
            '/agent/commands/fail',
            {
                instanceId: command.instanceId,
                region: command.region,
                instanceCommandId: command.instanceCommandId,
                occurredAtUtc,
                failureCode,
                failureMessage: options.failureMessage,
                terminalStatus: options.terminalStatus
            },
            'Command failure'
        );

        if (result.accepted || isTerminalCommandStatus(result.commandStatus)) {
            queueEvent('instance_command_failed', {
                instanceCommandId: command.instanceCommandId,
                commandStatus: result.commandStatus,
                failureCode,
                failureMessage: normalizeOptionalText(options.failureMessage)
            });
            clearActiveCommand();
            log(
                `[instance-agent] Command failed: id=${command.instanceCommandId}, status=${result.commandStatus}, failureCode=${failureCode}.`
            );
        }

        return result;
    };

    const registerArtifact = async (request: SessionLogArtifactRegistrationRequest): Promise<void> => {
        await ensureBootstrap();
        const response = await authorizedFetch('/agent/artifacts/register', 'POST', {
            instanceId: request.instanceId,
            region: request.region,
            sessionRequestId: request.sessionRequestId,
            userSessionId: request.userSessionId,
            sessionId: request.sessionId,
            artifactType: request.artifactType,
            bucketName: request.bucketName,
            objectKey: request.objectKey,
            objectVersionId: request.objectVersionId,
            eTag: request.eTag,
            sizeBytes: request.sizeBytes,
            checksumSha256: request.checksumSha256,
            timeRangeStartUtc: request.timeRangeStartUtc,
            timeRangeEndUtc: request.timeRangeEndUtc,
            uploadedAtUtc: request.uploadedAtUtc,
            metadata: request.metadata
        });
        if (!response.ok) {
            throw new Error(await describeErrorResponse(response, 'Artifact registration'));
        }

        const payload = await parseJsonResponse<InstanceAgentArtifactRegistrationResponse>(response);
        log(
            `[instance-agent] Registered session artifact ${payload.artifactId} for request ${payload.sessionRequestId} (${request.artifactType}).`
        );
    };

    artifactManager = createSessionLogArtifactManager({
        ...(options.sessionLogArtifacts ?? {}),
        desiredStatePath,
        registerArtifact,
        logger: log
    });
    artifactManager?.cleanStartupLogs({
        preserveRecycleLogs:
            pendingRecycleCompletion !== null ||
            (activeCommand !== null && isRecycleToWarmCommand(activeCommand))
    });

    const captureSessionLogArtifact = async (
        trigger: string,
        command:
            | Pick<
                  InstanceAgentCommand,
                  'instanceCommandId' | 'commandType' | 'sessionRequestId' | 'requestedAtUtc'
              >
            | Pick<
                  InstanceAgentCommandJournalSnapshot,
                  'instanceCommandId' | 'commandType' | 'sessionRequestId' | 'requestedAtUtc'
              >
            | null
            | undefined,
        metadata: Record<string, unknown> = {}
    ): Promise<void> => {
        if (!artifactManager) {
            return;
        }

        try {
            const identity = await resolveBootstrapIdentity();
            await artifactManager.captureAndUpload({
                trigger,
                instanceId: identity.instanceId,
                region: identity.region,
                sessionRequestId: normalizeOptionalText(command?.sessionRequestId),
                instanceCommandId: normalizeOptionalText(command?.instanceCommandId),
                commandType: normalizeOptionalText(command?.commandType),
                runtimeStatus: runtimeSnapshot.status,
                runtimeReason: runtimeSnapshot.reason,
                runtimeVersion: runtimeSnapshot.version,
                recycleId: normalizeOptionalText(metadata.recycleId),
                recycleReason: normalizeOptionalText(metadata.recycleReason),
                recycleRequestedAtUtc: normalizeOptionalText(metadata.recycleRequestedAtUtc),
                timeRangeStartUtc: normalizeOptionalText(
                    command?.requestedAtUtc ?? metadata.recycleRequestedAtUtc
                ),
                metadata
            });
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(`[session-artifacts] ${trigger} capture failed: ${message}`);
            throw error;
        }
    };
    const ensureBootstrap = async (): Promise<void> => {
        if (token) {
            return;
        }

        if (bootstrapPromise) {
            return bootstrapPromise;
        }

        bootstrapPromise = (async () => {
            const identity = await resolveBootstrapIdentity();
            const response = await fetch(new URL('/agent/bootstrap', apiBaseUrl).toString(), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    instanceId: identity.instanceId,
                    region: identity.region,
                    lane: configuredLane,
                    routeKey: configuredRouteKey,
                    scopeValue: configuredScopeValue,
                    agentVersion: configuredAgentVersion,
                    runtimeVersion: configuredRuntimeVersion ?? runtimeSnapshot.version,
                    currentRuntimeStatus: runtimeSnapshot.status,
                    currentRuntimeReason: runtimeSnapshot.reason,
                    viewerCount: server.playerRegistry.count(),
                    runtimeReady: runtimeSnapshot.status === 'ready',
                    streamerHealthy: runtimeSnapshot.status === 'ready',
                    instanceIdentityDocumentJson: identity.identityDocumentJson,
                    instanceIdentitySignature: identity.identitySignature,
                    bootstrapSharedSecret
                })
            });

            if (!response.ok) {
                throw new Error(await describeErrorResponse(response, 'Bootstrap'));
            }

            const payload = await parseJsonResponse<InstanceAgentBootstrapResponse>(response);
            token = payload.agentToken;
            applyDesiredState(payload.desiredState, 'bootstrap');
            applyCommands(payload.commands, 'bootstrap');
            if (explicitHeartbeatMs <= 0 && payload.heartbeatIntervalSeconds > 0) {
                scheduleHeartbeat(payload.heartbeatIntervalSeconds * 1000);
            }
            log(
                `[instance-agent] Bootstrapped against ${apiBaseUrl} as ${identity.instanceId} (${identity.region}).`
            );
        })()
            .catch((error) => {
                const message = error instanceof Error ? error.message : String(error);
                log(`[instance-agent] Bootstrap failed: ${message}`);
                throw error;
            })
            .finally(() => {
                bootstrapPromise = null;
            });

        return bootstrapPromise;
    };

    const sendHeartbeat = async (): Promise<void> => {
        const identity = await resolveBootstrapIdentity();
        const response = await authorizedFetch('/agent/heartbeat', 'POST', {
            instanceId: identity.instanceId,
            region: identity.region,
            agentVersion: configuredAgentVersion,
            runtimeVersion: configuredRuntimeVersion ?? runtimeSnapshot.version,
            currentRuntimeStatus: runtimeSnapshot.status,
            currentRuntimeReason: runtimeSnapshot.reason,
            viewerCount: server.playerRegistry.count(),
            runtimeReady: runtimeSnapshot.status === 'ready',
            streamerHealthy: runtimeSnapshot.status === 'ready'
        });
        if (!response.ok) {
            throw new Error(await describeErrorResponse(response, 'Heartbeat'));
        }

        const payload = await parseJsonResponse<InstanceAgentHeartbeatResponse>(response);
        applyDesiredState(payload.desiredState, 'heartbeat');
        applyCommands(payload.commands, 'heartbeat');
        if (explicitHeartbeatMs <= 0 && payload.heartbeatIntervalSeconds > 0) {
            scheduleHeartbeat(payload.heartbeatIntervalSeconds * 1000);
        }
    };

    const flushEvents = async (): Promise<void> => {
        if (!token || pendingEvents.length === 0) {
            return;
        }

        const identity = await resolveBootstrapIdentity();
        const eventsToSend = pendingEvents.slice(0, MAX_PENDING_EVENTS);
        const response = await authorizedFetch('/agent/events/batch', 'POST', {
            instanceId: identity.instanceId,
            region: identity.region,
            events: eventsToSend
        });
        if (!response.ok) {
            throw new Error(await describeErrorResponse(response, 'Event upload'));
        }

        const payload = await parseJsonResponse<InstanceAgentEventBatchResponse>(response);
        pendingEvents = pendingEvents.slice(Math.max(0, payload.acceptedCount));
        applyDesiredState(payload.desiredState, 'events');
        applyCommands(payload.commands, 'events');
    };

    const tryStartRecoveredRecycleCommand = async (): Promise<void> => {
        if (
            !activeCommand ||
            !isRecycleToWarmCommand(activeCommand) ||
            activeCommand.status !== 'acked' ||
            !pendingRecycleCompletion
        ) {
            return;
        }

        try {
            const occurredAtUtc =
                normalizeOptionalText(pendingRecycleCompletion.requestedAtUtc) ?? new Date().toISOString();
            await startCommand(activeCommand, { occurredAtUtc });
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[instance-agent] Failed to mark recovered recycle command ${activeCommand.instanceCommandId} as started: ${message}`
            );
        }
    };

    const tryFinalizeRecoveredActiveCommand = async (): Promise<void> => {
        if (
            !activeCommand ||
            !isRecycleToWarmCommand(activeCommand) ||
            activeCommand.instanceCommandId !== recoveredActiveCommandId ||
            activeCommand.status !== 'running' ||
            server.playerRegistry.count() > 0 ||
            resetInProgress ||
            pendingRecycleCompletion
        ) {
            return;
        }

        if ((runtimeSnapshot.status?.trim().toLowerCase() ?? '') !== 'ready') {
            return;
        }

        try {
            await captureSessionLogArtifact('reset_recovered_ready', activeCommand, {
                source: 'ready_recovery'
            }).catch(() => undefined);
            await completeCommand(activeCommand, {
                resultJson: JSON.stringify({
                    status: runtimeSnapshot.status,
                    reason: runtimeSnapshot.reason,
                    source: 'ready_recovery',
                    version: runtimeSnapshot.version
                })
            });
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[instance-agent] Failed to finalize recovered recycle command ${activeCommand.instanceCommandId}: ${message}`
            );
        }
    };

    const runTick = async (): Promise<void> => {
        if (tickInFlight) {
            return;
        }

        tickInFlight = true;
        try {
            await ensureBootstrap();
            await artifactManager?.drainQueue();
            await flushEvents();
            await sendHeartbeat();
            await flushEvents();
            await tryStartRecoveredRecycleCommand();
            await tryFinalizeRecoveredActiveCommand();
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(`[instance-agent] Tick failed: ${message}`);
        } finally {
            tickInFlight = false;
        }
    };

    queueEvent('agent_started', {
        agentVersion: configuredAgentVersion,
        runtimeVersion: configuredRuntimeVersion
    });

    server.playerRegistry.on('added', (playerId: string) => {
        queueEvent('viewer_connected', {
            playerId,
            viewerCount: server.playerRegistry.count()
        });
        requestFastPolling('viewer_connected');
    });
    server.playerRegistry.on('removed', (playerId?: string) => {
        const rawCount = server.playerRegistry.count();
        const removedEntryStillPresent =
            typeof playerId === 'string' && playerId.length > 0 ? server.playerRegistry.has(playerId) : false;
        queueEvent('viewer_disconnected', {
            playerId,
            viewerCount: Math.max(0, rawCount - (removedEntryStillPresent ? 1 : 0))
        });
        requestFastPolling('viewer_disconnected');
    });

    scheduleHeartbeat(heartbeatMs);
    void runTick();

    return {
        recordRuntimeStatus(update: RuntimeStatusUpdate) {
            const nextStatus = normalizeOptionalText(update.status);
            const nextReason = normalizeOptionalText(update.reason);
            const previousStatus = runtimeSnapshot.status;
            const previousReason = runtimeSnapshot.reason;
            runtimeSnapshot = {
                status: nextStatus,
                reason: nextReason,
                version: normalizeOptionalText(update.version) ?? runtimeSnapshot.version
            };

            if (update.heartbeatOnly === true) {
                return;
            }

            if (previousStatus === nextStatus && previousReason === nextReason) {
                return;
            }

            if (nextStatus === 'resetting' && !resetInProgress) {
                resetInProgress = true;
                log(
                    `[instance-agent] Reset started while runtime entered '${nextStatus}'${nextReason ? ` (reason=${nextReason})` : ''}.`
                );
                queueEvent('reset_started', {
                    status: nextStatus,
                    reason: nextReason,
                    source: update.source,
                    version: update.version
                });
            } else if ((resetInProgress || pendingRecycleCompletion) && nextStatus === 'ready') {
                const recycleMarker = pendingRecycleCompletion;
                resetInProgress = false;
                pendingRecycleCompletion = null;
                if (recycleMarker) {
                    clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
                    log(
                        `[instance-agent] Recycle marker ${recycleMarker.recycleId ?? 'unknown'} completed after runtime became ready. Clearing marker and emitting reset_completed.`
                    );
                } else {
                    log(
                        '[instance-agent] Reset completed after runtime became ready. Emitting reset_completed.'
                    );
                }
                queueEvent('reset_completed', {
                    status: nextStatus,
                    reason: nextReason,
                    source: update.source,
                    version: update.version,
                    recycleId: recycleMarker?.recycleId,
                    recycleReason: recycleMarker?.reason,
                    recycleRequestedAtUtc: recycleMarker?.requestedAtUtc
                });
                if (activeCommand && isRecycleToWarmCommand(activeCommand)) {
                    const commandToComplete = activeCommand;
                    void captureSessionLogArtifact('reset_completed', commandToComplete, {
                        recycleId: recycleMarker?.recycleId,
                        recycleReason: recycleMarker?.reason,
                        recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                        source: update.source
                    }).catch(() => undefined);
                    void completeCommand(commandToComplete, {
                        resultJson: JSON.stringify({
                            status: nextStatus,
                            reason: nextReason,
                            source: update.source,
                            version: update.version,
                            recycleId: recycleMarker?.recycleId,
                            recycleReason: recycleMarker?.reason,
                            recycleRequestedAtUtc: recycleMarker?.requestedAtUtc
                        })
                    }).catch((error) => {
                        const message = error instanceof Error ? error.message : String(error);
                        log(
                            `[instance-agent] Failed to report recycle command completion for ${commandToComplete.instanceCommandId}: ${message}`
                        );
                    });
                }
            } else if (
                (resetInProgress || pendingRecycleCompletion) &&
                (nextStatus === 'stopping' || nextStatus === 'idle_shutdown_pending')
            ) {
                resetInProgress = false;
                const recycleMarker = pendingRecycleCompletion;
                pendingRecycleCompletion = null;
                if (recycleMarker) {
                    clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
                    log(
                        `[instance-agent] Cancelling pending recycle marker ${recycleMarker.recycleId ?? 'unknown'} because runtime entered '${nextStatus}'.`
                    );
                } else {
                    log(
                        `[instance-agent] Reset was cancelled because runtime entered '${nextStatus}'. Emitting reset_cancelled.`
                    );
                }
                queueEvent('reset_cancelled', {
                    status: nextStatus,
                    reason: nextReason,
                    source: update.source,
                    version: update.version,
                    recycleId: recycleMarker?.recycleId,
                    recycleReason: recycleMarker?.reason,
                    recycleRequestedAtUtc: recycleMarker?.requestedAtUtc
                });
                if (activeCommand && isRecycleToWarmCommand(activeCommand)) {
                    const commandToFail = activeCommand;
                    void captureSessionLogArtifact('reset_cancelled', commandToFail, {
                        recycleId: recycleMarker?.recycleId,
                        recycleReason: recycleMarker?.reason,
                        recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                        source: update.source,
                        cancelledStatus: nextStatus,
                        cancelledReason: nextReason
                    }).catch(() => undefined);
                    void failCommand(commandToFail, {
                        failureCode: 'reset_cancelled',
                        failureMessage: `Runtime entered '${nextStatus}' before recycle completion.`,
                        occurredAtUtc: new Date().toISOString()
                    }).catch((error) => {
                        const message = error instanceof Error ? error.message : String(error);
                        log(
                            `[instance-agent] Failed to report recycle command cancellation for ${commandToFail.instanceCommandId}: ${message}`
                        );
                    });
                }
            }

            queueEvent(
                nextStatus === 'ready'
                    ? 'runtime_ready'
                    : nextStatus === 'resetting'
                      ? 'resetting'
                      : nextStatus === 'idle_shutdown_pending'
                        ? 'idle_shutdown_pending'
                        : nextStatus === 'stopping'
                          ? 'stopping'
                          : 'runtime_status_changed',
                {
                    status: nextStatus,
                    reason: nextReason,
                    source: update.source,
                    version: update.version
                }
            );
        },
        recordSessionNetworkPath(update: SessionNetworkPathReport) {
            queueEvent(
                'session_network_path',
                {
                    usesTurn: update.usesTurn,
                    candidateType: update.candidateType,
                    relayProtocol: update.relayProtocol
                },
                update.sessionId
            );
        },
        getDesiredState() {
            return currentDesiredState;
        },
        getActiveCommand() {
            return activeCommand;
        },
        addDesiredStateListener(listener: InstanceAgentDesiredStateListener) {
            desiredStateListeners.add(listener);
            try {
                listener(currentDesiredState, { source: 'current' });
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(`[instance-agent] Desired-state listener failed: ${message}`);
            }
            return () => {
                desiredStateListeners.delete(listener);
            };
        },
        addCommandListener(listener: InstanceAgentCommandListener) {
            commandListeners.add(listener);
            return () => {
                commandListeners.delete(listener);
            };
        },
        acknowledgeCommand(command: InstanceAgentCommand, options?: { occurredAtUtc?: string }) {
            return acknowledgeCommand(command, options);
        },
        startCommand(command: InstanceAgentCommand, options?: { occurredAtUtc?: string }) {
            return startCommand(command, options);
        },
        completeCommand(
            command: Pick<InstanceAgentCommand, 'instanceCommandId' | 'instanceId' | 'region'>,
            options?: { occurredAtUtc?: string; resultJson?: string }
        ) {
            return completeCommand(command, options);
        },
        failCommand(
            command: Pick<InstanceAgentCommand, 'instanceCommandId' | 'instanceId' | 'region'>,
            options: {
                failureCode: string;
                failureMessage?: string;
                terminalStatus?: string;
                occurredAtUtc?: string;
            }
        ) {
            return failCommand(command, options);
        },
        captureSessionLogArtifact(trigger, command, metadata) {
            return captureSessionLogArtifact(trigger, command, metadata);
        },
        requestFastPolling(reason: string, options?: { durationMs?: number; intervalMs?: number }) {
            requestFastPolling(reason, options);
        }
    };
}
