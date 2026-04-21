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

const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';
const IMDS_DYNAMIC_BASE_URL = 'http://169.254.169.254/latest/dynamic/instance-identity';
const DEFAULT_HEARTBEAT_MS = 10_000;
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
}

interface InstanceAgentHeartbeatResponse {
    tokenExpiresAtUtc: string;
    heartbeatIntervalSeconds: number;
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
}

interface InstanceAgentEventBatchResponse {
    acceptedCount: number;
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
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

export interface InstanceAgentClient {
    recordRuntimeStatus(update: RuntimeStatusUpdate): void;
    recordSessionNetworkPath(update: SessionNetworkPathReport): void;
    getDesiredState(): InstanceAgentDesiredStateSnapshot;
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

function truncateDiagnosticText(value: string, maxLength = 240): string {
    const normalized = value.replace(/\s+/g, ' ').trim();
    if (normalized.length <= maxLength) {
        return normalized;
    }

    return `${normalized.slice(0, maxLength - 3)}...`;
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
    const explicitHeartbeatMs = parseNonNegativeInteger(
        options.heartbeatMs ?? process.env.INSTANCE_AGENT_HEARTBEAT_MS,
        0
    );

    let currentDesiredState = writeInstanceAgentDesiredStateSnapshot(desiredStatePath, {}, log);
    let pendingRecycleCompletion: InstanceAgentRecycleMarkerSnapshot | null =
        readInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
    let bootstrapIdentityPromise: Promise<BootstrapIdentity> | null = null;
    let bootstrapPromise: Promise<void> | null = null;
    let tickInFlight = false;
    let heartbeatTimer: NodeJS.Timeout | null = null;
    let heartbeatMs = explicitHeartbeatMs > 0 ? explicitHeartbeatMs : DEFAULT_HEARTBEAT_MS;
    let token: string | null = null;
    let runtimeSnapshot: InstanceAgentRuntimeSnapshot = {};
    let pendingEvents: PendingInstanceAgentEvent[] = [];
    let resetInProgress = false;

    if (pendingRecycleCompletion) {
        log(
            `[instance-agent] Pending recycle marker detected (${pendingRecycleCompletion.recycleId ?? 'unknown'}). Waiting for ready state before emitting reset completion.`
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
        }
    };

    const scheduleHeartbeat = (nextHeartbeatMs: number): void => {
        const normalizedHeartbeatMs = Math.max(5_000, nextHeartbeatMs);
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
    };

    const runTick = async (): Promise<void> => {
        if (tickInFlight) {
            return;
        }

        tickInFlight = true;
        try {
            await ensureBootstrap();
            await flushEvents();
            await sendHeartbeat();
            await flushEvents();
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
    });
    server.playerRegistry.on('removed', (playerId?: string) => {
        const rawCount = server.playerRegistry.count();
        const removedEntryStillPresent =
            typeof playerId === 'string' && playerId.length > 0 ? server.playerRegistry.has(playerId) : false;
        queueEvent('viewer_disconnected', {
            playerId,
            viewerCount: Math.max(0, rawCount - (removedEntryStillPresent ? 1 : 0))
        });
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
            } else if (
                (resetInProgress || pendingRecycleCompletion) &&
                (nextStatus === 'stopping' || nextStatus === 'idle_shutdown_pending')
            ) {
                resetInProgress = false;
                const recycleMarker = pendingRecycleCompletion;
                pendingRecycleCompletion = null;
                if (recycleMarker) {
                    clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
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
        }
    };
}
