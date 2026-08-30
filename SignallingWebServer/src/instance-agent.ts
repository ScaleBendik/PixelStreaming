// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import type { RuntimeStatusUpdate, SessionNetworkPathReport } from './runtime-status';
import {
    normalizeInstanceAgentDesiredStateSnapshot,
    readInstanceAgentDesiredStateSnapshot,
    type InstanceAgentDesiredStateSnapshot,
    writeInstanceAgentDesiredStateSnapshot
} from './instance-agent-state';
import {
    clearInstanceAgentRecycleMarkerSnapshot,
    isInstanceAgentRecycleReplacementProof,
    normalizeInstanceAgentRecycleToken,
    readInstanceAgentRecycleMarkerSnapshot,
    resolveInstanceAgentRecycleMarkerPath,
    type InstanceAgentRecycleMarkerSnapshot,
    writeInstanceAgentRecycleMarkerSnapshot
} from './instance-agent-recycle-state';
import {
    clearInstanceAgentCommandJournalSnapshot,
    isInstanceAgentCommandExpired,
    readInstanceAgentCommandJournalSnapshot,
    resolveInstanceAgentCommandJournalPath,
    writeInstanceAgentCommandJournalSnapshot,
    type InstanceAgentCommandExecutionStatus,
    type InstanceAgentCommandJournalSnapshot
} from './instance-agent-command-state';
import {
    appendInstanceAgentReconnectGraceElapsedEvidence,
    inspectInstanceAgentReconnectGraceElapsedEvidenceJournal,
    removeAcknowledgedInstanceAgentReconnectGraceElapsedEvidence,
    resolveInstanceAgentReconnectGraceElapsedEvidenceJournalPath,
    rotateInstanceAgentReconnectGraceElapsedEvidenceAfterAttempt,
    type InstanceAgentReconnectGraceElapsedEvidence
} from './instance-agent-reconnect-grace-evidence-state';
import type { ConnectTicketRuntimeGate } from './connect-ticket-runtime-state';
import {
    createSessionLogArtifactManager,
    type SessionLogArtifactManager,
    type SessionLogArtifactRegistrationRequest,
    type SessionLogArtifactRuntimeOptions
} from './session-log-artifacts';
import {
    createSessionScreenshotArtifactManager,
    type SessionScreenshotArtifactManager,
    type SessionScreenshotArtifactRuntimeOptions
} from './session-screenshot-artifacts';

const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';
const IMDS_DYNAMIC_BASE_URL = 'http://169.254.169.254/latest/dynamic/instance-identity';
const DEFAULT_HEARTBEAT_MS = 10_000;
const DEFAULT_FAST_POLLING_INTERVAL_MS = 2_000;
const DEFAULT_FAST_POLLING_WINDOW_MS = 20_000;
const RECONNECT_GRACE_EVIDENCE_NO_ACK_LOG_INTERVAL = 30;
const RECONNECT_GRACE_EVIDENCE_JOURNAL_FAILURE_LOG_INTERVAL = 30;
const DEFAULT_DESIRED_STATE_PATH = path.resolve(
    __dirname,
    '..',
    'state',
    'instance-agent-desired-state.json'
);
const MAX_PENDING_EVENTS = 100;

interface InstanceAgentControlResponse {
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
    commands?: InstanceAgentCommand[];
    acknowledgedReconnectGraceElapsedEvidenceId?: string | null;
}

interface InstanceAgentBootstrapResponse extends InstanceAgentControlResponse {
    agentToken: string;
    tokenExpiresAtUtc: string;
    heartbeatIntervalSeconds: number;
}

interface InstanceAgentHeartbeatResponse extends InstanceAgentControlResponse {
    tokenExpiresAtUtc: string;
    heartbeatIntervalSeconds: number;
}

interface InstanceAgentEventBatchResponse {
    acceptedCount: number;
    desiredState: Partial<InstanceAgentDesiredStateSnapshot>;
    commands?: InstanceAgentCommand[];
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

interface ScaleWorldSessionPlayer {
    scaleWorldSessionId?: string | null;
    scaleWorldSessionRequestId?: string | null;
    scaleWorldSessionIdentityValidated?: boolean;
    scaleWorldActiveSessionIdValidated?: boolean;
}

interface PlayerSessionContext {
    sessionId?: string;
    sessionRequestId?: string;
}

interface InstanceAgentRuntimeSnapshot {
    status?: string;
    reason?: string;
    version?: string;
}

export interface InstanceAgentReconnectGraceWindow {
    lastViewerDisconnectedAtUtc: string;
    reconnectGraceExpiresAtUtc: string;
}

export function normalizeInstanceAgentReconnectGraceWindowForReport(
    window: InstanceAgentReconnectGraceWindow | null,
    currentRuntimeStatus: string | undefined,
    viewerCount: number
): InstanceAgentReconnectGraceWindow | null {
    const normalizedStatus = normalizeOptionalText(currentRuntimeStatus)?.toLowerCase();
    const disconnectedAtMs = window ? Date.parse(window.lastViewerDisconnectedAtUtc) : Number.NaN;
    const expiresAtMs = window ? Date.parse(window.reconnectGraceExpiresAtUtc) : Number.NaN;
    if (
        !window ||
        viewerCount !== 0 ||
        (normalizedStatus !== 'reconnect_grace' && normalizedStatus !== 'idle_shutdown_pending') ||
        !Number.isFinite(disconnectedAtMs) ||
        !Number.isFinite(expiresAtMs) ||
        expiresAtMs <= disconnectedAtMs
    ) {
        return null;
    }

    return {
        lastViewerDisconnectedAtUtc: window.lastViewerDisconnectedAtUtc,
        reconnectGraceExpiresAtUtc: window.reconnectGraceExpiresAtUtc
    };
}

interface RuntimeIdentityMetadataOptions {
    configuredLane?: string;
    configuredAgentVersion?: string;
    configuredRuntimeVersion?: string;
    desiredStatePath: string;
    sessionLogArtifacts?: SessionLogArtifactRuntimeOptions;
    sessionScreenshotArtifacts?: SessionScreenshotArtifactRuntimeOptions;
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

export function canExecuteAcknowledgedInstanceCommand(
    result: InstanceAgentCommandTransitionResult | null | undefined
): boolean {
    const status = normalizeOptionalText(result?.commandStatus)?.toLowerCase();
    return status === 'acked' || status === 'running';
}

export type InstanceAgentDesiredStateListener = (
    desiredState: InstanceAgentDesiredStateSnapshot,
    context: InstanceAgentDesiredStateListenerContext
) => void;

export type InstanceAgentCommandListener = (
    command: InstanceAgentCommand,
    context: InstanceAgentCommandListenerContext
) => void;

export type InstanceAgentReconnectGraceRecoveryListener = () => void;

export interface InstanceAgentControlResponseHandlers {
    applyCommands(commands: InstanceAgentCommand[] | null | undefined, source: string): void;
    applyDesiredState(
        desiredState: Partial<InstanceAgentDesiredStateSnapshot> | null | undefined,
        source: string
    ): void;
    handleReconnectGraceElapsedEvidenceResponse(
        submittedEvidence: InstanceAgentReconnectGraceElapsedEvidence | null,
        acknowledgedEvidenceId?: string | null
    ): void;
}

/**
 * Applies one authoritative control-plane response without exposing recovery listeners to stale
 * local intent. Evidence acknowledgement can synchronously start recycle/stop work, so it must be
 * observed only after the response's commands and desired state have replaced persisted state.
 */
export function applyInstanceAgentControlResponse(
    payload: InstanceAgentControlResponse,
    source: 'bootstrap' | 'heartbeat',
    submittedEvidence: InstanceAgentReconnectGraceElapsedEvidence | null,
    handlers: InstanceAgentControlResponseHandlers
): void {
    handlers.applyCommands(payload.commands, source);
    handlers.applyDesiredState(payload.desiredState, source);
    handlers.handleReconnectGraceElapsedEvidenceResponse(
        submittedEvidence,
        payload.acknowledgedReconnectGraceElapsedEvidenceId
    );
}

export interface InstanceAgentClient {
    recordRuntimeStatus(update: RuntimeStatusUpdate): void;
    recordSessionNetworkPath(update: SessionNetworkPathReport): void;
    setReconnectGraceWindow(window: InstanceAgentReconnectGraceWindow | null): void;
    recordReconnectGraceElapsedEvidence(evidence: InstanceAgentReconnectGraceElapsedEvidence): boolean;
    getDesiredState(): InstanceAgentDesiredStateSnapshot;
    getActiveCommand(): InstanceAgentCommandJournalSnapshot | null;
    addDesiredStateListener(listener: InstanceAgentDesiredStateListener): () => void;
    addCommandListener(listener: InstanceAgentCommandListener): () => void;
    isReconnectGraceRecoveryRecyclePending(): boolean;
    addReconnectGraceRecoveryListener(listener: InstanceAgentReconnectGraceRecoveryListener): () => void;
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
    captureSessionScreenshotArtifact(
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
    requireIdentityProof?: boolean;
    lane?: string;
    routeKey?: string;
    scopeValue?: string;
    agentVersion?: string;
    runtimeVersion?: string;
    heartbeatMs?: number;
    desiredStatePath?: string;
    connectTicketRuntimeGate?: Pick<
        ConnectTicketRuntimeGate,
        | 'getReconnectGraceEvidenceJournalBlockReason'
        | 'setReconnectGraceEvidenceJournalBlock'
        | 'markTeardownStarted'
        | 'isCommercialRecoveryRequired'
        | 'prepareCommercialRecoveryAfterReset'
        | 'completeCommercialRecoveryAfterReset'
        | 'getRecycleTokenCompletionStatus'
        | 'getCommercialRecoveryReadyNotBeforeEpochSeconds'
    >;
    sessionLogArtifacts?: SessionLogArtifactRuntimeOptions;
    sessionScreenshotArtifacts?: SessionScreenshotArtifactRuntimeOptions;
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

function normalizeCommand(value: InstanceAgentCommand | null | undefined): InstanceAgentCommand | null {
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

function normalizePathForComparison(value: string | undefined): string | undefined {
    const normalized = normalizeOptionalText(value);
    if (!normalized) {
        return undefined;
    }

    try {
        return path
            .resolve(normalized)
            .replace(/[\\/]+$/g, '')
            .toLowerCase();
    } catch {
        return normalized.replace(/[\\/]+$/g, '').toLowerCase();
    }
}

function resolveRealPath(value: string | undefined): string | undefined {
    const normalized = normalizeOptionalText(value);
    if (!normalized) {
        return undefined;
    }

    try {
        return fs.realpathSync.native(normalized);
    } catch {
        return undefined;
    }
}

function tryReadJsonObject(filePath: string): Record<string, unknown> | null {
    try {
        const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8')) as unknown;
        return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
            ? (parsed as Record<string, unknown>)
            : null;
    } catch {
        return null;
    }
}

function firstOptionalMetadataValue(
    metadata: Record<string, unknown> | null,
    ...keys: string[]
): string | undefined {
    if (!metadata) {
        return undefined;
    }

    for (const key of keys) {
        const value = normalizeOptionalText(metadata[key]);
        if (value) {
            return value;
        }
    }

    return undefined;
}

function collectCliOptionNames(): string {
    const optionNames = process.argv
        .slice(2)
        .filter((item) => item.startsWith('--'))
        .map((item) => item.slice(2).split('=')[0]?.trim())
        .filter((item): item is string => Boolean(item))
        .map((item) => item.replace(/[^a-zA-Z0-9_-]+/g, '_'))
        .filter((item, index, values) => values.indexOf(item) === index)
        .sort();

    return truncateDiagnosticText(optionNames.join(','), 512);
}

function buildRuntimeIdentityMetadata(options: RuntimeIdentityMetadataOptions): Record<string, unknown> {
    const signallingRoot = path.resolve(__dirname, '..');
    const pixelStreamingRoot = path.resolve(signallingRoot, '..');
    const installBase = normalizeOptionalText(process.env.SCALEWORLD_INSTALL_BASE) ?? 'C:\\PixelStreaming';
    const launchRoot = path.join(installBase, 'PixelStreaming');
    const pixelStreamingRootRealPath = resolveRealPath(pixelStreamingRoot);
    const launchRootRealPath = resolveRealPath(launchRoot);
    const runtimeBundleMetadataPath = path.join(pixelStreamingRoot, 'runtime-bundle-metadata.json');
    const runtimeBundleMetadata = tryReadJsonObject(runtimeBundleMetadataPath);

    const rootComparable = normalizePathForComparison(pixelStreamingRoot);
    const launchRootComparable = normalizePathForComparison(launchRoot);
    const rootRealComparable = normalizePathForComparison(pixelStreamingRootRealPath);
    const launchRootRealComparable = normalizePathForComparison(launchRootRealPath);

    const artifactOptions = options.sessionLogArtifacts ?? {};
    const screenshotOptions = options.sessionScreenshotArtifacts ?? {};
    const artifactBucketName =
        normalizeOptionalText(artifactOptions.bucketName) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_BUCKET);
    const screenshotBucketName =
        normalizeOptionalText(screenshotOptions.bucketName) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_BUCKET) ??
        artifactBucketName;

    return {
        schemaVersion: 1,
        nodeExecutable: process.execPath,
        entryPoint: process.argv[1],
        cliOptionNames: collectCliOptionNames(),
        workingDirectory: process.cwd(),
        scriptDirectory: __dirname,
        signallingRoot,
        pixelStreamingRoot,
        pixelStreamingRootRealPath,
        launchRoot,
        launchRootRealPath,
        activeRuntimeRoot: launchRoot,
        activeRuntimeRootRealPath: launchRootRealPath,
        isLaunchRoot:
            Boolean(rootComparable && launchRootComparable) && rootComparable === launchRootComparable,
        isLaunchRootRealPath:
            Boolean(rootRealComparable && launchRootRealComparable) &&
            rootRealComparable === launchRootRealComparable,
        isActiveRuntimeRoot:
            Boolean(rootComparable && launchRootComparable) && rootComparable === launchRootComparable,
        isActiveRuntimeRealPath:
            Boolean(rootRealComparable && launchRootRealComparable) &&
            rootRealComparable === launchRootRealComparable,
        deliveryMode: process.env.SCALEWORLD_PIXELSTREAMING_DELIVERY_MODE,
        gitSyncMode: process.env.SCALEWORLD_GIT_SYNC_MODE,
        streamingLane: process.env.SCALEWORLD_STREAMING_LANE,
        deploymentTrack: process.env.SCALEWORLD_DEPLOYMENT_TRACK,
        configuredLane: options.configuredLane,
        agentVersion: options.configuredAgentVersion,
        runtimeVersion: options.configuredRuntimeVersion,
        runtimeBundleMetadataPresent: runtimeBundleMetadata !== null,
        runtimeBundleId: firstOptionalMetadataValue(runtimeBundleMetadata, 'bundleId'),
        runtimeBundleManifestKey: firstOptionalMetadataValue(runtimeBundleMetadata, 'manifestKey'),
        runtimeBundleArtifactKey: firstOptionalMetadataValue(
            runtimeBundleMetadata,
            'runtimeZipKey',
            'artifactKey'
        ),
        runtimeBundleSourceCommit: firstOptionalMetadataValue(
            runtimeBundleMetadata,
            'pixelStreamingRepoCommit',
            'sourceCommit'
        ),
        runtimeBundleContractVersion: firstOptionalMetadataValue(
            runtimeBundleMetadata,
            'scaleWorldContractVersion',
            'contractVersion'
        ),
        desiredStatePath: options.desiredStatePath,
        artifactUploadEnabled: parseBoolean(
            artifactOptions.enabled ?? process.env.INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED,
            false
        ),
        artifactBucketConfigured: Boolean(artifactBucketName),
        artifactBucketName,
        artifactPrefix:
            normalizeOptionalText(artifactOptions.objectPrefix) ??
            normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_PREFIX),
        artifactQueuePath:
            normalizeOptionalText(artifactOptions.queuePath) ??
            normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_QUEUE_PATH),
        artifactLogFolder:
            normalizeOptionalText(artifactOptions.logFolder) ??
            normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_WILBUR_LOG_FOLDER),
        artifactUnrealLogDirectory:
            normalizeOptionalText(artifactOptions.unrealLogDirectory) ??
            normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_UNREAL_LOG_DIR) ??
            normalizeOptionalText(process.env.SCALEWORLD_UNREAL_LOG_DIR),
        screenshotArtifactUploadEnabled: parseBoolean(
            screenshotOptions.enabled ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED,
            false
        ),
        screenshotArtifactBucketConfigured: Boolean(screenshotBucketName),
        screenshotArtifactBucketName: screenshotBucketName,
        screenshotArtifactPrefix:
            normalizeOptionalText(screenshotOptions.objectPrefix) ??
            normalizeOptionalText(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_PREFIX),
        screenshotArtifactQueuePath:
            normalizeOptionalText(screenshotOptions.queuePath) ??
            normalizeOptionalText(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_QUEUE_PATH)
    };
}

function buildRuntimeIdentityLogMessage(metadata: Record<string, unknown>): string {
    const summary = {
        pixelStreamingRoot: metadata.pixelStreamingRoot,
        pixelStreamingRootRealPath: metadata.pixelStreamingRootRealPath,
        launchRoot: metadata.launchRoot,
        launchRootRealPath: metadata.launchRootRealPath,
        activeRuntimeRoot: metadata.activeRuntimeRoot,
        activeRuntimeRootRealPath: metadata.activeRuntimeRootRealPath,
        isLaunchRoot: metadata.isLaunchRoot,
        isLaunchRootRealPath: metadata.isLaunchRootRealPath,
        isActiveRuntimeRoot: metadata.isActiveRuntimeRoot,
        isActiveRuntimeRealPath: metadata.isActiveRuntimeRealPath,
        deliveryMode: metadata.deliveryMode,
        gitSyncMode: metadata.gitSyncMode,
        streamingLane: metadata.streamingLane,
        deploymentTrack: metadata.deploymentTrack,
        runtimeBundleId: metadata.runtimeBundleId,
        runtimeBundleSourceCommit: metadata.runtimeBundleSourceCommit,
        artifactUploadEnabled: metadata.artifactUploadEnabled,
        artifactBucketConfigured: metadata.artifactBucketConfigured,
        artifactPrefix: metadata.artifactPrefix,
        artifactQueuePath: metadata.artifactQueuePath,
        screenshotArtifactUploadEnabled: metadata.screenshotArtifactUploadEnabled,
        screenshotArtifactBucketConfigured: metadata.screenshotArtifactBucketConfigured,
        screenshotArtifactPrefix: metadata.screenshotArtifactPrefix,
        screenshotArtifactQueuePath: metadata.screenshotArtifactQueuePath
    };

    return `[instance-agent] Runtime identity ${JSON.stringify(summary)}`;
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

function isShutdownCommand(
    command:
        | Pick<InstanceAgentCommand, 'commandType'>
        | Pick<InstanceAgentCommandJournalSnapshot, 'commandType'>
        | null
        | undefined
): boolean {
    return normalizeOptionalText(command?.commandType)?.toLowerCase() === 'shutdown';
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
    const requireIdentityProof = parseBoolean(
        options.requireIdentityProof ?? process.env.INSTANCE_AGENT_REQUIRE_IDENTITY_PROOF ?? false,
        false
    );
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
    const reconnectGraceElapsedEvidenceJournalPath =
        resolveInstanceAgentReconnectGraceElapsedEvidenceJournalPath(desiredStatePath);
    const explicitHeartbeatMs = parseNonNegativeInteger(
        options.heartbeatMs ?? process.env.INSTANCE_AGENT_HEARTBEAT_MS,
        0
    );

    let currentDesiredState = readInstanceAgentDesiredStateSnapshot(desiredStatePath, log);
    let activeCommand = readInstanceAgentCommandJournalSnapshot(commandJournalPath, log);
    if (activeCommand && isInstanceAgentCommandExpired(activeCommand)) {
        log(
            `[instance-agent] Clearing expired recovered command ${activeCommand.instanceCommandId}; its timeout was ${activeCommand.timeoutAtUtc ?? 'invalid'}.`
        );
        clearInstanceAgentCommandJournalSnapshot(commandJournalPath, log);
        activeCommand = null;
    }
    const recoveredRecycleMarker = readInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
    if (
        isInstanceAgentRecycleReplacementProof(recoveredRecycleMarker) &&
        recoveredRecycleMarker.schemaVersion === 1 &&
        !normalizeInstanceAgentRecycleToken(recoveredRecycleMarker.recycleRequestedToken)
    ) {
        throw new Error(
            `Recovered legacy tokenless recycle marker ${recoveredRecycleMarker.recycleId}; its destructive request ownership cannot be proven, so recovery is failing closed instead of binding a possibly newer desired-state or command token.`
        );
    }
    let pendingRecycleCompletion: InstanceAgentRecycleMarkerSnapshot | null =
        isInstanceAgentRecycleReplacementProof(recoveredRecycleMarker) ? recoveredRecycleMarker : null;
    if (
        recoveredRecycleMarker &&
        options.connectTicketRuntimeGate &&
        !options.connectTicketRuntimeGate.isCommercialRecoveryRequired() &&
        !options.connectTicketRuntimeGate.markTeardownStarted({
            reason: 'recovered_recycle_marker',
            occurredAtUtc:
                recoveredRecycleMarker.replacementStartedAtUtc ?? recoveredRecycleMarker.requestedAtUtc
        })
    ) {
        throw new Error(
            'A durable recycle marker exists, but its connect-ticket recovery latch could not be restored.'
        );
    }
    let recoveredActiveCommandId = activeCommand?.instanceCommandId ?? null;
    let activeCommandConfirmedByApi = activeCommand === null;
    let desiredStateConfirmedByApi = false;
    let authoritativeTeardownCommandObserved = false;
    const getExposedDesiredState = (): InstanceAgentDesiredStateSnapshot =>
        desiredStateConfirmedByApi
            ? currentDesiredState
            : {
                  ...currentDesiredState,
                  warmHoldEnabled: true,
                  drainEnabled: false,
                  shutdownRequested: false,
                  recycleRequestedToken: undefined,
                  message: 'Awaiting authoritative control state before local teardown may resume.'
              };
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
    let reconnectGraceWindow: InstanceAgentReconnectGraceWindow | null = null;
    const initialReconnectGraceEvidenceJournalRead = inspectInstanceAgentReconnectGraceElapsedEvidenceJournal(
        reconnectGraceElapsedEvidenceJournalPath,
        log
    );
    const hadReconnectGraceEvidenceJournalPreflightBlock = Boolean(
        options.connectTicketRuntimeGate?.getReconnectGraceEvidenceJournalBlockReason()
    );
    let reconnectGraceElapsedEvidenceJournalBlocked =
        initialReconnectGraceEvidenceJournalRead.status === 'invalid' ||
        (initialReconnectGraceEvidenceJournalRead.status === 'missing' &&
            hadReconnectGraceEvidenceJournalPreflightBlock);
    let reconnectGraceElapsedEvidenceJournalFailureAttempts = 0;
    let reconnectGraceElapsedEvidences =
        initialReconnectGraceEvidenceJournalRead.status === 'valid'
            ? initialReconnectGraceEvidenceJournalRead.evidences
            : [];
    let reconnectGraceRecoveryRecycleRequired =
        reconnectGraceElapsedEvidences.length > 0 || recoveredRecycleMarker !== null;
    let deferredRecoveredCommercialRecovery =
        reconnectGraceElapsedEvidences.length === 0 &&
        recoveredRecycleMarker === null &&
        options.connectTicketRuntimeGate?.isCommercialRecoveryRequired() === true;
    let reconnectGraceEvidenceCutoffDurableThroughMs = 0;
    let pendingEvents: PendingInstanceAgentEvent[] = [];
    let completedRecycleMarkerAwaitingEventAck: InstanceAgentRecycleMarkerSnapshot | null = null;
    let acknowledgedRecycleMarkerToClear: InstanceAgentRecycleMarkerSnapshot | null = null;
    let resetInProgress = false;
    let artifactManager: SessionLogArtifactManager | null = null;
    let screenshotArtifactManager: SessionScreenshotArtifactManager | null = null;
    let lastPlayerSessionContext: PlayerSessionContext = {};
    let lastShutdownCommandSessionRequestId: string | undefined;
    const playerSessionContexts = new Map<string, PlayerSessionContext>();
    const reconnectGraceElapsedEvidenceNoAckAttempts = new Map<string, number>();
    const desiredStateListeners = new Set<InstanceAgentDesiredStateListener>();
    const commandListeners = new Set<InstanceAgentCommandListener>();
    const reconnectGraceRecoveryListeners = new Set<InstanceAgentReconnectGraceRecoveryListener>();

    const reconnectGraceEvidenceJournalBlockReason =
        'Commercial session admission is unavailable because local reconnect-grace billing evidence requires operator recovery.';
    const updateReconnectGraceEvidenceAdmissionBlock = (): void => {
        options.connectTicketRuntimeGate?.setReconnectGraceEvidenceJournalBlock(
            reconnectGraceElapsedEvidenceJournalBlocked || reconnectGraceRecoveryRecycleRequired
                ? reconnectGraceEvidenceJournalBlockReason
                : null
        );
    };
    if (initialReconnectGraceEvidenceJournalRead.status === 'invalid') {
        options.connectTicketRuntimeGate?.setReconnectGraceEvidenceJournalBlock(
            reconnectGraceEvidenceJournalBlockReason
        );
    } else if (initialReconnectGraceEvidenceJournalRead.status === 'valid') {
        reconnectGraceElapsedEvidenceJournalBlocked = false;
    }
    updateReconnectGraceEvidenceAdmissionBlock();

    if (pendingRecycleCompletion) {
        log(
            `[instance-agent] Replacement-started recycle proof detected (${pendingRecycleCompletion.recycleId}). Waiting for the replacement runtime Ready state before emitting reset completion.`
        );
    } else if (recoveredRecycleMarker) {
        log(
            `[instance-agent] Recovered pre-launch recycle intent (${recoveredRecycleMarker.recycleId}). Keeping admission blocked and requesting a fresh recycle launch; intent alone is not replacement proof.`
        );
    }

    if (activeCommand) {
        log(
            `[instance-agent] Recovered active command ${activeCommand.instanceCommandId} (${activeCommand.commandType}, status=${activeCommand.status}, attempt=${activeCommand.attemptNumber}).`
        );
    }

    if (reconnectGraceElapsedEvidences.length > 0) {
        log(
            `[instance-agent] Recovered ${reconnectGraceElapsedEvidences.length} unacknowledged reconnect-grace elapsed evidence record(s).`
        );
    }

    const queueEvent = (
        eventType: string,
        metadata: Record<string, unknown>,
        sessionId?: string,
        occurredAtUtc?: string
    ): void => {
        pendingEvents.push({
            eventType,
            occurredAtUtc: normalizeOptionalText(occurredAtUtc) ?? new Date().toISOString(),
            sessionId: normalizeOptionalText(sessionId),
            metadata: normalizeEventMetadata(metadata)
        });

        if (pendingEvents.length > MAX_PENDING_EVENTS) {
            pendingEvents = pendingEvents.slice(pendingEvents.length - MAX_PENDING_EVENTS);
        }
    };

    const ensureCompletedRecycleMarkerEventQueued = (): void => {
        const marker = completedRecycleMarkerAwaitingEventAck;
        if (
            !marker ||
            pendingEvents.some(
                (event) =>
                    event.eventType === 'reset_completed' && event.metadata.recycleId === marker.recycleId
            )
        ) {
            return;
        }

        queueEvent(
            'reset_completed',
            {
                status: 'ready',
                reason: 'reset_completed_event_ack_retry',
                source: 'instance_agent_recovery',
                version: runtimeSnapshot.version,
                recycleId: marker.recycleId,
                recycleReason: marker.reason,
                recycleRequestedAtUtc: marker.requestedAtUtc,
                recycleRequestedToken: marker.recycleRequestedToken,
                sessionRequestId: marker.sessionRequestId,
                userSessionId: marker.userSessionId,
                sessionId: marker.sessionId
            },
            marker.sessionId,
            marker.resetCompletedAtUtc
        );
        log(
            `[instance-agent] Re-queued reset_completed for recycle ${marker.recycleId} while waiting for control-plane acknowledgement.`
        );
    };

    const tryClearAcknowledgedRecycleMarker = (): void => {
        const marker = acknowledgedRecycleMarkerToClear;
        if (!marker) {
            return;
        }

        if (clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log, marker.recycleId)) {
            acknowledgedRecycleMarkerToClear = null;
            log(
                `[instance-agent] Recycle marker ${marker.recycleId} cleared after reset_completed was acknowledged by the control plane.`
            );
        } else {
            log(
                `[instance-agent] CRITICAL: reset_completed was acknowledged for recycle ${marker.recycleId}, but its durable marker could not be cleared. Retrying without replaying the stack recycle.`
            );
        }
    };

    const readPlayerSessionContext = (playerId?: string): PlayerSessionContext => {
        const normalizedPlayerId = normalizeOptionalText(playerId);
        if (!normalizedPlayerId) {
            return {};
        }

        const player = server.playerRegistry.get(normalizedPlayerId) as ScaleWorldSessionPlayer | undefined;
        const sessionRequestIdValidated = player?.scaleWorldSessionIdentityValidated === true;
        const activeSessionIdValidated = player?.scaleWorldActiveSessionIdValidated === true;
        return {
            sessionId:
                sessionRequestIdValidated && activeSessionIdValidated
                    ? normalizeOptionalText(player?.scaleWorldSessionId)
                    : undefined,
            sessionRequestId: sessionRequestIdValidated
                ? normalizeOptionalText(player?.scaleWorldSessionRequestId)
                : undefined
        };
    };

    const hasPlayerSessionContext = (context: PlayerSessionContext): boolean =>
        Boolean(context.sessionId ?? context.sessionRequestId);

    const rememberPlayerSessionContext = (context: PlayerSessionContext): void => {
        const sessionId = normalizeOptionalText(context.sessionId);
        const sessionRequestId = normalizeOptionalText(context.sessionRequestId);
        if (!sessionId && !sessionRequestId) {
            return;
        }

        lastPlayerSessionContext = {
            sessionId: sessionId ?? lastPlayerSessionContext.sessionId,
            sessionRequestId: sessionRequestId ?? lastPlayerSessionContext.sessionRequestId
        };
    };

    const rememberShutdownCommandSessionContext = (command: InstanceAgentCommand): void => {
        if (!isShutdownCommand(command)) {
            return;
        }

        lastShutdownCommandSessionRequestId = normalizeOptionalText(command.sessionRequestId);
    };

    const allowLastSessionCorrelation = (metadata: Record<string, unknown>): boolean =>
        metadata.allowLastSessionCorrelation === true ||
        normalizeOptionalText(metadata.allowLastSessionCorrelation)?.toLowerCase() === 'true';

    const resolveLastSessionArtifactContext = (): PlayerSessionContext => ({
        sessionId: lastPlayerSessionContext.sessionId,
        sessionRequestId: lastShutdownCommandSessionRequestId ?? lastPlayerSessionContext.sessionRequestId
    });

    const buildPlayerSessionMetadata = (context: PlayerSessionContext): Record<string, unknown> => ({
        sessionId: context.sessionId,
        sessionRequestId: context.sessionRequestId
    });

    const getPlayerEventSessionId = (context: PlayerSessionContext): string | undefined =>
        context.sessionId ?? context.sessionRequestId;

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
        activeCommandConfirmedByApi = true;

        return activeCommand;
    };

    const clearActiveCommand = (): void => {
        activeCommand = null;
        recoveredActiveCommandId = null;
        activeCommandConfirmedByApi = true;
        clearInstanceAgentCommandJournalSnapshot(commandJournalPath, log);
    };

    const invalidateRecoveredCommand = (command: InstanceAgentCommand, reason: string): void => {
        if (activeCommand?.instanceCommandId === command.instanceCommandId) {
            clearActiveCommand();
        }
        log(
            `[instance-agent] Teardown command ${command.instanceCommandId} was invalidated by ${reason}; destructive execution remains blocked pending authoritative desired-state refresh and commercial recovery.`
        );
        deferredRecoveredCommercialRecovery = false;
        reconnectGraceRecoveryRecycleRequired = true;
        desiredStateConfirmedByApi = false;
        updateReconnectGraceEvidenceAdmissionBlock();
        requestFastPolling('teardown_command_invalidated');
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

        const wasConfirmedByApi = desiredStateConfirmedByApi;
        currentDesiredState = writeInstanceAgentDesiredStateSnapshot(desiredStatePath, nextState, log);
        desiredStateConfirmedByApi = true;
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
        if (changed || !wasConfirmedByApi) {
            for (const listener of desiredStateListeners) {
                try {
                    listener(currentDesiredState, { source });
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(`[instance-agent] Desired-state listener failed: ${message}`);
                }
            }
        }
        if (
            deferredRecoveredCommercialRecovery &&
            !authoritativeTeardownCommandObserved &&
            activeCommand === null &&
            !currentDesiredState.shutdownRequested &&
            !currentDesiredState.recycleRequestedToken
        ) {
            deferredRecoveredCommercialRecovery = false;
            reconnectGraceRecoveryRecycleRequired = true;
            updateReconnectGraceEvidenceAdmissionBlock();
            log(
                '[instance-agent] Authoritative control state invalidated recovered local teardown state. Requiring one safe commercial recovery recycle before admission can reopen.'
            );
            notifyReconnectGraceRecoveryReady();
        } else if (!wasConfirmedByApi && reconnectGraceRecoveryRecycleRequired) {
            notifyReconnectGraceRecoveryReady();
        }
    };

    const applyCommands = (values: InstanceAgentCommand[] | null | undefined, source: string): void => {
        if (!Array.isArray(values)) {
            return;
        }

        const deliverableCommands: InstanceAgentCommand[] = [];
        const openCommandIds = new Set<string>();
        for (const rawCommand of values) {
            const command = normalizeCommand(rawCommand);
            if (!command) {
                continue;
            }

            if (isInstanceAgentCommandExpired(command)) {
                log(
                    `[instance-agent] Ignoring expired command ${command.instanceCommandId} from ${source}; its timeout was ${command.timeoutAtUtc ?? 'invalid'}.`
                );
                continue;
            }

            deliverableCommands.push(command);
            openCommandIds.add(command.instanceCommandId);
        }
        authoritativeTeardownCommandObserved = deliverableCommands.some(
            (command) => isRecycleToWarmCommand(command) || isShutdownCommand(command)
        );

        if (activeCommand && !openCommandIds.has(activeCommand.instanceCommandId)) {
            const commandToInvalidate = activeCommand;
            const wasTeardownCommand =
                isRecycleToWarmCommand(commandToInvalidate) || isShutdownCommand(commandToInvalidate);
            log(
                `[instance-agent] Clearing stale active command ${activeCommand.instanceCommandId} because the API ${source} response no longer lists it as open.`
            );
            if (wasTeardownCommand) {
                const recycleTokenStatus = isRecycleToWarmCommand(commandToInvalidate)
                    ? (options.connectTicketRuntimeGate?.getRecycleTokenCompletionStatus(
                          commandToInvalidate.instanceCommandId
                      ) ?? 'unavailable')
                    : 'open';
                if (recycleTokenStatus === 'completed') {
                    log(
                        `[instance-agent] Recovered recycle command ${commandToInvalidate.instanceCommandId} is already completed durably. Clearing its local journal without requesting another recovery recycle.`
                    );
                    clearActiveCommand();
                } else if (recycleTokenStatus === 'unavailable') {
                    requestFastPolling('recycle_token_fence_unavailable');
                } else {
                    invalidateRecoveredCommand(commandToInvalidate, `${source} response`);
                }
            } else {
                clearActiveCommand();
            }
        } else if (activeCommand && openCommandIds.has(activeCommand.instanceCommandId)) {
            activeCommandConfirmedByApi = true;
        }

        if (deliverableCommands.length === 0) {
            return;
        }

        for (const command of deliverableCommands) {
            rememberShutdownCommandSessionContext(command);
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
            screenshotArtifactManager?.attachSessionContext({
                trigger: 'instance_command_received',
                instanceId: command.instanceId,
                region: command.region,
                sessionRequestId: command.sessionRequestId,
                runtimeStatus: runtimeSnapshot.status,
                runtimeReason: runtimeSnapshot.reason,
                runtimeVersion: runtimeSnapshot.version,
                lane: configuredLane,
                metadata: {
                    instanceCommandId: command.instanceCommandId,
                    commandType: command.commandType,
                    commandSource: source
                }
            });

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

    const notifyReconnectGraceRecoveryReady = (): void => {
        if (
            !reconnectGraceRecoveryRecycleRequired ||
            reconnectGraceElapsedEvidences.length > 0 ||
            pendingRecycleCompletion
        ) {
            return;
        }

        for (const listener of reconnectGraceRecoveryListeners) {
            try {
                listener();
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(`[instance-agent] Reconnect-grace recovery listener failed: ${message}`);
            }
        }
    };

    const resolveReconnectGraceWindowForReport = (
        viewerCount: number
    ): InstanceAgentReconnectGraceWindow | null => {
        const nextWindow = normalizeInstanceAgentReconnectGraceWindowForReport(
            reconnectGraceWindow,
            runtimeSnapshot.status,
            viewerCount
        );
        if (reconnectGraceWindow && !nextWindow) {
            const normalizedStatus = normalizeOptionalText(runtimeSnapshot.status) ?? 'unknown';
            const readyDiagnostic = normalizedStatus.toLowerCase() === 'ready' ? ' Ready' : '';
            log(
                `[instance-agent] Cleared inconsistent live reconnect-grace telemetry before a${readyDiagnostic} report (runtimeStatus=${normalizedStatus}, viewerCount=${viewerCount}); durable elapsed evidence is retained independently.`
            );
            reconnectGraceWindow = null;
        }
        return nextWindow;
    };

    const ensureReconnectGraceEvidenceCutoffDurable = (): boolean => {
        if (reconnectGraceElapsedEvidences.length === 0) {
            return true;
        }

        const latestExpiryMs = Math.max(
            ...reconnectGraceElapsedEvidences.map((evidence) =>
                Date.parse(evidence.reconnectGraceExpiresAtUtc)
            )
        );
        if (reconnectGraceEvidenceCutoffDurableThroughMs >= latestExpiryMs) {
            return true;
        }

        const persisted =
            options.connectTicketRuntimeGate?.markTeardownStarted({
                reason: 'reconnect_grace_elapsed_evidence_pending',
                occurredAtUtc: new Date(latestExpiryMs).toISOString()
            }) === true;
        if (!persisted) {
            log(
                '[instance-agent] CRITICAL: Pending reconnect-grace evidence cannot be replayed because its teardown cutoff/recovery latch is not durable.'
            );
            return false;
        }

        reconnectGraceRecoveryRecycleRequired = true;
        reconnectGraceEvidenceCutoffDurableThroughMs = latestExpiryMs;
        updateReconnectGraceEvidenceAdmissionBlock();
        return true;
    };

    const refreshReconnectGraceElapsedEvidenceJournalHealth = (): boolean => {
        const result = inspectInstanceAgentReconnectGraceElapsedEvidenceJournal(
            reconnectGraceElapsedEvidenceJournalPath,
            () => undefined
        );
        const journalWasExpected =
            reconnectGraceElapsedEvidenceJournalBlocked || reconnectGraceElapsedEvidences.length > 0;
        if (result.status === 'invalid' || (result.status === 'missing' && journalWasExpected)) {
            reconnectGraceElapsedEvidenceJournalBlocked = true;
            reconnectGraceElapsedEvidenceJournalFailureAttempts += 1;
            updateReconnectGraceEvidenceAdmissionBlock();
            if (
                reconnectGraceElapsedEvidenceJournalFailureAttempts === 1 ||
                reconnectGraceElapsedEvidenceJournalFailureAttempts %
                    RECONNECT_GRACE_EVIDENCE_JOURNAL_FAILURE_LOG_INTERVAL ===
                    0
            ) {
                const detail =
                    result.status === 'invalid'
                        ? result.error
                        : 'The journal disappeared after evidence or an invalid state had already been observed.';
                log(
                    `[instance-agent] CRITICAL: Reconnect-grace elapsed-evidence journal recovery is blocked (attempt=${reconnectGraceElapsedEvidenceJournalFailureAttempts}): ${detail} The file will not be overwritten or treated as empty; bootstrap, readiness, and managed admission remain blocked until a valid journal is restored.`
                );
            }
            return false;
        }

        if (result.status === 'valid') {
            reconnectGraceElapsedEvidences = result.evidences;
            if (reconnectGraceElapsedEvidenceJournalBlocked) {
                log(
                    `[instance-agent] Reconnect-grace elapsed-evidence journal recovered with ${result.evidences.length} pending record(s); bootstrap may resume${reconnectGraceRecoveryRecycleRequired ? ', while managed admission stays blocked through recovery recycle' : ''}.`
                );
            }
            reconnectGraceElapsedEvidenceJournalBlocked = false;
            reconnectGraceElapsedEvidenceJournalFailureAttempts = 0;
            updateReconnectGraceEvidenceAdmissionBlock();
        }

        return true;
    };

    const handleReconnectGraceElapsedEvidenceResponse = (
        submittedEvidence: InstanceAgentReconnectGraceElapsedEvidence | null,
        acknowledgedEvidenceId?: string | null
    ): void => {
        const normalizedAcknowledgedEvidenceId = normalizeOptionalText(acknowledgedEvidenceId);
        if (!submittedEvidence) {
            if (normalizedAcknowledgedEvidenceId) {
                log(
                    `[instance-agent] Ignoring unexpected reconnect-grace elapsed evidence acknowledgement '${normalizedAcknowledgedEvidenceId}' because no evidence was submitted.`
                );
            }
            return;
        }

        if (
            normalizedAcknowledgedEvidenceId &&
            normalizedAcknowledgedEvidenceId !== submittedEvidence.evidenceId
        ) {
            log(
                `[instance-agent] Ignoring reconnect-grace elapsed evidence acknowledgement '${normalizedAcknowledgedEvidenceId}' because it does not exactly match submitted evidence '${submittedEvidence.evidenceId}'.`
            );
        }

        if (normalizedAcknowledgedEvidenceId === submittedEvidence.evidenceId) {
            const acknowledgementCutoffUtc = new Date().toISOString();
            const acknowledgementCutoffPersisted =
                options.connectTicketRuntimeGate?.markTeardownStarted({
                    reason: 'reconnect_grace_elapsed_evidence_acknowledged',
                    occurredAtUtc: acknowledgementCutoffUtc
                }) === true;
            if (!acknowledgementCutoffPersisted) {
                log(
                    `[instance-agent] CRITICAL: Evidence '${submittedEvidence.evidenceId}' was acknowledged, but the acknowledgement-time ticket cutoff/recovery latch could not be persisted. The journal record will be retained and replayed.`
                );
                return;
            }

            reconnectGraceRecoveryRecycleRequired = true;
            reconnectGraceEvidenceCutoffDurableThroughMs = Math.max(
                reconnectGraceEvidenceCutoffDurableThroughMs,
                Date.parse(acknowledgementCutoffUtc)
            );
            updateReconnectGraceEvidenceAdmissionBlock();
            const remaining = removeAcknowledgedInstanceAgentReconnectGraceElapsedEvidence(
                reconnectGraceElapsedEvidenceJournalPath,
                submittedEvidence.evidenceId,
                log
            );
            if (
                !remaining ||
                remaining.some((candidate) => candidate.evidenceId === submittedEvidence.evidenceId)
            ) {
                log(
                    `[instance-agent] Could not durably remove acknowledged reconnect-grace elapsed evidence '${submittedEvidence.evidenceId}'; it will be retried.`
                );
                refreshReconnectGraceElapsedEvidenceJournalHealth();
                return;
            }

            reconnectGraceElapsedEvidences = remaining;
            reconnectGraceElapsedEvidenceNoAckAttempts.delete(submittedEvidence.evidenceId);
            log(
                `[instance-agent] Removed acknowledged reconnect-grace elapsed evidence '${submittedEvidence.evidenceId}' from the durable journal.`
            );
            if (remaining.length > 0) {
                requestFastPolling('reconnect_grace_elapsed_evidence_pending');
            } else {
                notifyReconnectGraceRecoveryReady();
            }
            return;
        }

        const noAckAttempt =
            (reconnectGraceElapsedEvidenceNoAckAttempts.get(submittedEvidence.evidenceId) ?? 0) + 1;
        reconnectGraceElapsedEvidenceNoAckAttempts.set(submittedEvidence.evidenceId, noAckAttempt);
        if (noAckAttempt === 1 || noAckAttempt % RECONNECT_GRACE_EVIDENCE_NO_ACK_LOG_INTERVAL === 0) {
            log(
                `[instance-agent] Reconnect-grace elapsed evidence '${submittedEvidence.evidenceId}' was not acknowledged (attempt=${noAckAttempt}); retaining it and advancing the durable retry cursor.`
            );
        }

        const rotated = rotateInstanceAgentReconnectGraceElapsedEvidenceAfterAttempt(
            reconnectGraceElapsedEvidenceJournalPath,
            submittedEvidence.evidenceId,
            log
        );
        if (!rotated) {
            log(
                `[instance-agent] Could not durably advance the reconnect-grace elapsed evidence retry cursor after '${submittedEvidence.evidenceId}'.`
            );
            refreshReconnectGraceElapsedEvidenceJournalHealth();
            return;
        }

        reconnectGraceElapsedEvidences = rotated;
        if (rotated.length > 1) {
            requestFastPolling('reconnect_grace_elapsed_evidence_round_robin');
        }
    };

    const resolveBootstrapIdentity = async (): Promise<BootstrapIdentity> => {
        if (!bootstrapIdentityPromise) {
            bootstrapIdentityPromise = (async () => {
                const tokenValue = await readImdsToken();
                const [resolvedInstanceId, resolvedRegion, identityDocumentJson, identitySignature] =
                    await Promise.all([
                        configuredInstanceId
                            ? Promise.resolve(configuredInstanceId)
                            : readImdsValue('instance-id', tokenValue),
                        configuredRegion
                            ? Promise.resolve(configuredRegion)
                            : readImdsValue('placement/region', tokenValue),
                        readImdsDynamicValue('document', tokenValue),
                        readImdsDynamicValue('signature', tokenValue)
                    ]);

                return {
                    instanceId: resolvedInstanceId.trim(),
                    region: resolvedRegion.trim(),
                    identityDocumentJson: identityDocumentJson.trim(),
                    identitySignature: identitySignature.trim()
                };
            })().catch((error) => {
                bootstrapIdentityPromise = null;
                const message = error instanceof Error ? error.message : String(error);
                if (requireIdentityProof) {
                    throw new Error(
                        `EC2 identity proof is required for instance-agent bootstrap: ${message}`
                    );
                }

                if (configuredInstanceId && configuredRegion) {
                    log(
                        `[instance-agent] Could not attach EC2 identity proof during bootstrap; continuing with configured instance identity: ${message}`
                    );
                    return {
                        instanceId: configuredInstanceId,
                        region: configuredRegion
                    };
                }

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
            } else {
                invalidateRecoveredCommand(command, `acknowledgement status ${result.commandStatus}`);
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
        } else {
            const recoveredStatus = normalizeOpenCommandExecutionStatus(result.commandStatus);
            if (recoveredStatus) {
                persistActiveCommand(command, recoveredStatus, result.recordedAtUtc);
                log(
                    `[instance-agent] Recovered open command state during start: id=${command.instanceCommandId}, type=${command.commandType}, status=${result.commandStatus}.`
                );
            } else {
                invalidateRecoveredCommand(command, `start status ${result.commandStatus}`);
            }
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
            if (activeCommand?.instanceCommandId === command.instanceCommandId) {
                clearActiveCommand();
            }
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
            if (activeCommand?.instanceCommandId === command.instanceCommandId) {
                clearActiveCommand();
            }
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
        getCurrentInstanceIdentity: resolveBootstrapIdentity,
        logger: log
    });
    artifactManager?.cleanStartupLogs({
        preserveRecycleLogs:
            recoveredRecycleMarker !== null ||
            (activeCommand !== null && isRecycleToWarmCommand(activeCommand))
    });
    artifactManager?.cleanStartupQueue({
        preserveQueue:
            recoveredRecycleMarker !== null ||
            (activeCommand !== null && isRecycleToWarmCommand(activeCommand))
    });
    screenshotArtifactManager = createSessionScreenshotArtifactManager({
        ...(options.sessionScreenshotArtifacts ?? {}),
        lane: configuredLane ?? options.sessionScreenshotArtifacts?.lane,
        runtimeVersion:
            configuredRuntimeVersion ??
            runtimeSnapshot.version ??
            options.sessionScreenshotArtifacts?.runtimeVersion,
        registerArtifact,
        getCurrentInstanceIdentity: resolveBootstrapIdentity,
        logger: log
    });
    screenshotArtifactManager?.cleanStartupScreenshots({
        preserveActiveSession:
            recoveredRecycleMarker !== null ||
            (activeCommand !== null && isRecycleToWarmCommand(activeCommand))
    });
    screenshotArtifactManager?.cleanStartupQueue({
        preserveActiveSession:
            recoveredRecycleMarker !== null ||
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
            const commandSessionRequestId = normalizeOptionalText(command?.sessionRequestId);
            const metadataSessionRequestId = normalizeOptionalText(metadata.sessionRequestId);
            const metadataUserSessionId = normalizeOptionalText(metadata.userSessionId);
            const metadataSessionId = normalizeOptionalText(metadata.sessionId);
            const fallbackSessionContext = allowLastSessionCorrelation(metadata)
                ? resolveLastSessionArtifactContext()
                : {};
            const fallbackSessionRequestId = normalizeOptionalText(fallbackSessionContext.sessionRequestId);
            const fallbackSessionId = normalizeOptionalText(fallbackSessionContext.sessionId);
            const selectedSessionRequestId =
                commandSessionRequestId ?? metadataSessionRequestId ?? fallbackSessionRequestId;
            const selectedUserSessionId = metadataUserSessionId;
            const selectedSessionId =
                metadataSessionId ??
                (!selectedSessionRequestId && !selectedUserSessionId ? fallbackSessionId : undefined);

            if (
                !commandSessionRequestId &&
                !metadataSessionRequestId &&
                !metadataUserSessionId &&
                !metadataSessionId &&
                (fallbackSessionRequestId || fallbackSessionId)
            ) {
                log(
                    `[session-artifacts] ${trigger} using recent session correlation: sessionRequestId=${fallbackSessionRequestId ?? '(none)'}, sessionId=${fallbackSessionId ?? '(none)'}.`
                );
            }

            await artifactManager.captureAndUpload({
                trigger,
                instanceId: identity.instanceId,
                region: identity.region,
                sessionRequestId: selectedSessionRequestId,
                userSessionId: selectedUserSessionId,
                sessionId: selectedSessionId,
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

    const captureSessionScreenshotArtifact = async (
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
        if (!screenshotArtifactManager) {
            return;
        }

        try {
            const identity = await resolveBootstrapIdentity();
            const result = await screenshotArtifactManager.completeSessionAndUpload({
                trigger,
                instanceId: identity.instanceId,
                region: identity.region,
                sessionRequestId:
                    normalizeOptionalText(command?.sessionRequestId) ??
                    normalizeOptionalText(metadata.sessionRequestId),
                userSessionId: normalizeOptionalText(metadata.userSessionId),
                sessionId: normalizeOptionalText(metadata.sessionId),
                runtimeStatus: runtimeSnapshot.status,
                runtimeReason: runtimeSnapshot.reason,
                runtimeVersion: runtimeSnapshot.version,
                lane: configuredLane,
                timeRangeEndUtc: new Date().toISOString(),
                metadata: {
                    instanceCommandId: normalizeOptionalText(command?.instanceCommandId),
                    commandType: normalizeOptionalText(command?.commandType),
                    ...metadata
                }
            });
            if (result.status === 'no_screenshots') {
                queueEvent('screenshot_artifact_empty', {
                    trigger,
                    sessionRequestId: result.sessionRequestId,
                    screenshotCount: result.screenshotCount,
                    changedFileCount: result.changedFileCount,
                    discoveredFileCount: result.discoveredFileCount,
                    sourceFolder: result.sourceFolder,
                    timeRangeStartUtc: result.timeRangeStartUtc,
                    timeRangeEndUtc: result.timeRangeEndUtc,
                    instanceCommandId: normalizeOptionalText(command?.instanceCommandId),
                    commandType: normalizeOptionalText(command?.commandType),
                    ...metadata
                });
                void flushEvents().catch(() => undefined);
            }
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(`[screenshot-artifacts] ${trigger} capture failed: ${message}`);
            throw error;
        }
    };

    const startSessionScreenshotArtifacts = async (
        metadata: Record<string, unknown> = {},
        sessionContext: PlayerSessionContext = {}
    ): Promise<void> => {
        if (!screenshotArtifactManager) {
            return;
        }

        try {
            const identity = await resolveBootstrapIdentity();
            screenshotArtifactManager.startSession({
                trigger: 'viewer_connected',
                instanceId: identity.instanceId,
                region: identity.region,
                sessionRequestId: sessionContext.sessionRequestId,
                sessionId: sessionContext.sessionId,
                runtimeStatus: runtimeSnapshot.status,
                runtimeReason: runtimeSnapshot.reason,
                runtimeVersion: runtimeSnapshot.version,
                lane: configuredLane,
                timeRangeStartUtc: new Date().toISOString(),
                metadata: {
                    ...metadata,
                    ...buildPlayerSessionMetadata(sessionContext)
                }
            });
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(`[screenshot-artifacts] Failed to capture session baseline: ${message}`);
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
            const sentAtUtc = new Date().toISOString();
            const submittedReconnectGraceElapsedEvidence = reconnectGraceElapsedEvidences[0] ?? null;
            const viewerCount = server.playerRegistry.count();
            const reportedReconnectGraceWindow = resolveReconnectGraceWindowForReport(viewerCount);
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
                    viewerCount,
                    lastViewerDisconnectedAtUtc:
                        reportedReconnectGraceWindow?.lastViewerDisconnectedAtUtc ?? null,
                    reconnectGraceExpiresAtUtc:
                        reportedReconnectGraceWindow?.reconnectGraceExpiresAtUtc ?? null,
                    reconnectGraceElapsedEvidence: submittedReconnectGraceElapsedEvidence,
                    runtimeReady:
                        runtimeSnapshot.status === 'ready' && !reconnectGraceRecoveryRecycleRequired,
                    streamerHealthy:
                        runtimeSnapshot.status === 'ready' && !reconnectGraceRecoveryRecycleRequired,
                    sentAtUtc,
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
            applyInstanceAgentControlResponse(payload, 'bootstrap', submittedReconnectGraceElapsedEvidence, {
                applyCommands,
                applyDesiredState,
                handleReconnectGraceElapsedEvidenceResponse
            });
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
        const sentAtUtc = new Date().toISOString();
        const submittedReconnectGraceElapsedEvidence = reconnectGraceElapsedEvidences[0] ?? null;
        const viewerCount = server.playerRegistry.count();
        const reportedReconnectGraceWindow = resolveReconnectGraceWindowForReport(viewerCount);
        const response = await authorizedFetch('/agent/heartbeat', 'POST', {
            instanceId: identity.instanceId,
            region: identity.region,
            agentVersion: configuredAgentVersion,
            runtimeVersion: configuredRuntimeVersion ?? runtimeSnapshot.version,
            currentRuntimeStatus: runtimeSnapshot.status,
            currentRuntimeReason: runtimeSnapshot.reason,
            viewerCount,
            lastViewerDisconnectedAtUtc: reportedReconnectGraceWindow?.lastViewerDisconnectedAtUtc ?? null,
            reconnectGraceExpiresAtUtc: reportedReconnectGraceWindow?.reconnectGraceExpiresAtUtc ?? null,
            reconnectGraceElapsedEvidence: submittedReconnectGraceElapsedEvidence,
            runtimeReady: runtimeSnapshot.status === 'ready' && !reconnectGraceRecoveryRecycleRequired,
            streamerHealthy: runtimeSnapshot.status === 'ready' && !reconnectGraceRecoveryRecycleRequired,
            sentAtUtc
        });
        if (!response.ok) {
            throw new Error(await describeErrorResponse(response, 'Heartbeat'));
        }

        const payload = await parseJsonResponse<InstanceAgentHeartbeatResponse>(response);
        applyInstanceAgentControlResponse(payload, 'heartbeat', submittedReconnectGraceElapsedEvidence, {
            applyCommands,
            applyDesiredState,
            handleReconnectGraceElapsedEvidenceResponse
        });
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
        const acceptedCount = Math.min(eventsToSend.length, Math.max(0, payload.acceptedCount));
        const acceptedEvents = eventsToSend.slice(0, acceptedCount);
        pendingEvents = pendingEvents.slice(acceptedCount);
        const acceptedCompletedRecycleMarker = completedRecycleMarkerAwaitingEventAck;
        const acceptedResetCompletion = Boolean(
            acceptedCompletedRecycleMarker &&
                acceptedEvents.some(
                    (event) =>
                        event.eventType === 'reset_completed' &&
                        event.metadata.recycleId === acceptedCompletedRecycleMarker.recycleId
                )
        );
        const acceptedRecycleToken = normalizeInstanceAgentRecycleToken(
            acceptedCompletedRecycleMarker?.recycleRequestedToken
        );
        const responseRecycleToken = normalizeInstanceAgentRecycleToken(
            payload.desiredState?.recycleRequestedToken
        );
        const resetCompletionStillNeedsControlReconciliation = Boolean(
            acceptedResetCompletion && acceptedRecycleToken && responseRecycleToken === acceptedRecycleToken
        );
        if (acceptedResetCompletion && !resetCompletionStillNeedsControlReconciliation) {
            acknowledgedRecycleMarkerToClear = acceptedCompletedRecycleMarker;
            completedRecycleMarkerAwaitingEventAck = null;
            tryClearAcknowledgedRecycleMarker();
        } else if (resetCompletionStillNeedsControlReconciliation) {
            log(
                `[instance-agent] reset_completed for recycle ${acceptedCompletedRecycleMarker?.recycleId ?? 'unknown'} was accepted, but desired state still requests its token. Retaining the durable marker through a Ready heartbeat and replaying the same completion evidence.`
            );
        }
        applyCommands(payload.commands, 'events');
        applyDesiredState(payload.desiredState, 'events');
        if (resetCompletionStillNeedsControlReconciliation) {
            ensureCompletedRecycleMarkerEventQueued();
            requestFastPolling('reset_completed_control_reconciliation');
        }
    };

    const tryStartRecoveredRecycleCommand = async (): Promise<void> => {
        if (
            !activeCommand ||
            !activeCommandConfirmedByApi ||
            !isRecycleToWarmCommand(activeCommand) ||
            activeCommand.status !== 'acked' ||
            !pendingRecycleCompletion
        ) {
            return;
        }
        const pendingRecycleToken = normalizeInstanceAgentRecycleToken(
            pendingRecycleCompletion.recycleRequestedToken
        );
        if (
            !pendingRecycleToken ||
            normalizeInstanceAgentRecycleToken(activeCommand.instanceCommandId) !== pendingRecycleToken
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
            !activeCommandConfirmedByApi ||
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
        const commandToFinalize = activeCommand;
        if (
            (options.connectTicketRuntimeGate?.getRecycleTokenCompletionStatus(
                commandToFinalize.instanceCommandId
            ) ?? 'unavailable') !== 'completed'
        ) {
            return;
        }

        try {
            await captureSessionLogArtifact('reset_recovered_ready', commandToFinalize, {
                source: 'ready_recovery'
            }).catch(() => undefined);
            await captureSessionScreenshotArtifact('reset_recovered_ready', commandToFinalize, {
                source: 'ready_recovery'
            }).catch(() => undefined);
            await completeCommand(commandToFinalize, {
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
                `[instance-agent] Failed to finalize recovered recycle command ${commandToFinalize.instanceCommandId}: ${message}`
            );
        }
    };

    const runTick = async (): Promise<void> => {
        if (tickInFlight) {
            return;
        }

        tickInFlight = true;
        try {
            if (!refreshReconnectGraceElapsedEvidenceJournalHealth()) {
                return;
            }
            if (!ensureReconnectGraceEvidenceCutoffDurable()) {
                return;
            }
            await ensureBootstrap();
            ensureCompletedRecycleMarkerEventQueued();
            await artifactManager?.drainQueue();
            await screenshotArtifactManager?.drainQueue();
            ensureCompletedRecycleMarkerEventQueued();
            await flushEvents();
            await sendHeartbeat();
            ensureCompletedRecycleMarkerEventQueued();
            await flushEvents();
            await tryStartRecoveredRecycleCommand();
            await tryFinalizeRecoveredActiveCommand();
            tryClearAcknowledgedRecycleMarker();
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
    const runtimeIdentityMetadata = buildRuntimeIdentityMetadata({
        configuredLane,
        configuredAgentVersion,
        configuredRuntimeVersion,
        desiredStatePath,
        sessionLogArtifacts: options.sessionLogArtifacts,
        sessionScreenshotArtifacts: options.sessionScreenshotArtifacts
    });
    queueEvent('runtime_identity', runtimeIdentityMetadata);
    log(buildRuntimeIdentityLogMessage(runtimeIdentityMetadata));

    server.playerRegistry.on('added', (playerId: string) => {
        const viewerCount = server.playerRegistry.count();
        const sessionContext = readPlayerSessionContext(playerId);
        const normalizedPlayerId = normalizeOptionalText(playerId);
        if (normalizedPlayerId && hasPlayerSessionContext(sessionContext)) {
            playerSessionContexts.set(normalizedPlayerId, sessionContext);
            rememberPlayerSessionContext(sessionContext);
        } else if (normalizedPlayerId) {
            playerSessionContexts.delete(normalizedPlayerId);
        }
        queueEvent(
            'viewer_connected',
            {
                playerId,
                viewerCount,
                ...buildPlayerSessionMetadata(sessionContext)
            },
            getPlayerEventSessionId(sessionContext)
        );
        void startSessionScreenshotArtifacts({ playerId, viewerCount }, sessionContext);
        requestFastPolling('viewer_connected');
    });
    server.playerRegistry.on(
        'scaleWorldMediaEvidenceCapable',
        (playerId: string, evidence: Record<string, unknown> = {}) => {
            const sessionContext = readPlayerSessionContext(playerId);
            if (!hasPlayerSessionContext(sessionContext)) {
                return;
            }

            queueEvent(
                'viewer_media_evidence_capable',
                {
                    playerId,
                    viewerCount: server.playerRegistry.count(),
                    ...evidence,
                    ...buildPlayerSessionMetadata(sessionContext)
                },
                getPlayerEventSessionId(sessionContext)
            );
            requestFastPolling('viewer_media_evidence_capable');
        }
    );
    server.playerRegistry.on(
        'scaleWorldMediaReceived',
        (playerId: string, evidence: Record<string, unknown> = {}) => {
            const sessionContext = readPlayerSessionContext(playerId);
            if (!hasPlayerSessionContext(sessionContext)) {
                return;
            }

            queueEvent(
                'viewer_media_received',
                {
                    playerId,
                    viewerCount: server.playerRegistry.count(),
                    ...evidence,
                    ...buildPlayerSessionMetadata(sessionContext)
                },
                getPlayerEventSessionId(sessionContext)
            );
            requestFastPolling('viewer_media_received');
        }
    );
    server.playerRegistry.on(
        'scaleWorldMediaFlowObserved',
        (playerId: string, evidence: Record<string, unknown> = {}) => {
            const sessionContext = readPlayerSessionContext(playerId);
            if (!hasPlayerSessionContext(sessionContext)) {
                return;
            }

            queueEvent(
                'viewer_media_flow_observed',
                {
                    playerId,
                    viewerCount: server.playerRegistry.count(),
                    ...evidence,
                    ...buildPlayerSessionMetadata(sessionContext)
                },
                getPlayerEventSessionId(sessionContext)
            );
            requestFastPolling('viewer_media_flow_observed');
        }
    );
    server.playerRegistry.on('removed', (playerId?: string) => {
        const rawCount = server.playerRegistry.count();
        const normalizedPlayerId = normalizeOptionalText(playerId);
        const removedEntryStillPresent =
            typeof playerId === 'string' && playerId.length > 0 ? server.playerRegistry.has(playerId) : false;
        const sessionContext = removedEntryStillPresent
            ? readPlayerSessionContext(playerId)
            : normalizedPlayerId
              ? (playerSessionContexts.get(normalizedPlayerId) ?? {})
              : {};
        rememberPlayerSessionContext(sessionContext);
        queueEvent(
            'viewer_disconnected',
            {
                playerId,
                viewerCount: Math.max(0, rawCount - (removedEntryStillPresent ? 1 : 0)),
                ...buildPlayerSessionMetadata(sessionContext)
            },
            getPlayerEventSessionId(sessionContext)
        );
        if (normalizedPlayerId) {
            playerSessionContexts.delete(normalizedPlayerId);
        }
        requestFastPolling('viewer_disconnected');
    });

    scheduleHeartbeat(heartbeatMs);
    if (reconnectGraceElapsedEvidences.length > 0) {
        requestFastPolling('recovered_reconnect_grace_elapsed_evidence');
    } else {
        void runTick();
    }

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

            let completedCommercialRecoveryThisUpdate = false;
            if (
                nextStatus === 'ready' &&
                pendingRecycleCompletion &&
                options.connectTicketRuntimeGate?.isCommercialRecoveryRequired() === true
            ) {
                const expectedRecycleId = pendingRecycleCompletion.recycleId;
                const expectedRecycleToken = normalizeInstanceAgentRecycleToken(
                    pendingRecycleCompletion.recycleRequestedToken
                );
                let durableReplacementProof: InstanceAgentRecycleMarkerSnapshot | null = null;
                try {
                    const currentMarker = readInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
                    if (
                        isInstanceAgentRecycleReplacementProof(currentMarker) &&
                        currentMarker.recycleId === expectedRecycleId &&
                        normalizeInstanceAgentRecycleToken(currentMarker.recycleRequestedToken) ===
                            expectedRecycleToken
                    ) {
                        durableReplacementProof = currentMarker;
                    }
                } catch {
                    // The marker reader already logged the invalid/unreadable state.
                }
                if (!durableReplacementProof) {
                    log(
                        `[instance-agent] CRITICAL: Runtime reached Ready, but durable replacement-started proof for recycle ${expectedRecycleId} is missing or changed. Keeping readiness and admission blocked.`
                    );
                    return;
                }
                pendingRecycleCompletion = durableReplacementProof;

                const readyNotBeforeEpochSeconds =
                    options.connectTicketRuntimeGate.prepareCommercialRecoveryAfterReset();
                if (readyNotBeforeEpochSeconds === null) {
                    log(
                        '[instance-agent] CRITICAL: Runtime reached Ready after recycle, but the recovery-ready ticket cutoff could not be durably prepared. Keeping the recycle marker, readiness, and admission blocked.'
                    );
                    return;
                }
                if (Math.floor(Date.now() / 1000) <= readyNotBeforeEpochSeconds) {
                    log(
                        `[instance-agent] Runtime reached Ready after recycle, but commercial admission remains blocked through ${new Date(readyNotBeforeEpochSeconds * 1000).toISOString()} so cleanup-era tickets cannot survive the reset.`
                    );
                    return;
                }
                if (
                    !options.connectTicketRuntimeGate.completeCommercialRecoveryAfterReset(
                        durableReplacementProof.recycleRequestedToken
                    )
                ) {
                    log(
                        '[instance-agent] CRITICAL: Runtime reached Ready after recycle, but commercial recovery completion was not durable. Keeping the recycle marker, readiness, and admission blocked.'
                    );
                    return;
                }

                reconnectGraceRecoveryRecycleRequired = false;
                completedCommercialRecoveryThisUpdate = true;
                updateReconnectGraceEvidenceAdmissionBlock();
                log(
                    '[instance-agent] Commercial recovery completion is durable after reset reached Ready; admission may reopen after recycle finalization.'
                );
            }

            const shouldRetryPendingReadyRecycleCompletion =
                nextStatus === 'ready' &&
                pendingRecycleCompletion !== null &&
                options.connectTicketRuntimeGate?.isCommercialRecoveryRequired() !== true;
            if (
                update.heartbeatOnly === true &&
                !completedCommercialRecoveryThisUpdate &&
                !shouldRetryPendingReadyRecycleCompletion
            ) {
                return;
            }

            if (
                previousStatus === nextStatus &&
                previousReason === nextReason &&
                !completedCommercialRecoveryThisUpdate &&
                !shouldRetryPendingReadyRecycleCompletion
            ) {
                return;
            }

            if (
                nextStatus === 'ready' &&
                (resetInProgress || pendingRecycleCompletion) &&
                options.connectTicketRuntimeGate?.isCommercialRecoveryRequired() === true
            ) {
                log(
                    '[instance-agent] CRITICAL: Suppressing reset_completed because commercial recovery is still durable-blocked; pre-launch intent or an unproven replacement Ready cannot release ownership.'
                );
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
                    version: update.version,
                    sessionRequestId: activeCommand?.sessionRequestId
                });
            } else if ((resetInProgress || pendingRecycleCompletion) && nextStatus === 'ready') {
                let recycleMarker = pendingRecycleCompletion;
                if (recycleMarker && !recycleMarker.resetCompletedAtUtc) {
                    try {
                        recycleMarker = writeInstanceAgentRecycleMarkerSnapshot(
                            recycleMarkerPath,
                            {
                                ...recycleMarker,
                                resetCompletedAtUtc: new Date().toISOString()
                            },
                            log
                        );
                    } catch {
                        log(
                            `[instance-agent] CRITICAL: Runtime reached Ready for recycle ${recycleMarker.recycleId}, but its stable reset-completion timestamp could not be persisted. Retaining the marker and retrying before event emission.`
                        );
                        return;
                    }
                }
                const recycleMarkerToken = normalizeInstanceAgentRecycleToken(
                    recycleMarker?.recycleRequestedToken
                );
                const activeCommandBelongsToRecycleMarker =
                    !recycleMarker ||
                    Boolean(
                        activeCommand &&
                            isRecycleToWarmCommand(activeCommand) &&
                            recycleMarkerToken &&
                            normalizeInstanceAgentRecycleToken(activeCommand.instanceCommandId) ===
                                recycleMarkerToken
                    );
                const correlatedActiveCommand = activeCommandBelongsToRecycleMarker ? activeCommand : null;
                resetInProgress = false;
                pendingRecycleCompletion = null;
                if (recycleMarker) {
                    completedRecycleMarkerAwaitingEventAck = recycleMarker;
                    log(
                        `[instance-agent] Recycle marker ${recycleMarker.recycleId} completed after the replacement runtime became ready. Retaining it until reset_completed is acknowledged by the control plane.`
                    );
                } else {
                    log(
                        '[instance-agent] Reset completed after runtime became ready. Emitting reset_completed.'
                    );
                }
                queueEvent(
                    'reset_completed',
                    {
                        status: nextStatus,
                        reason: nextReason,
                        source: update.source,
                        version: update.version,
                        recycleId: recycleMarker?.recycleId,
                        recycleReason: recycleMarker?.reason,
                        recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                        recycleRequestedToken: recycleMarker?.recycleRequestedToken,
                        sessionRequestId:
                            correlatedActiveCommand?.sessionRequestId ?? recycleMarker?.sessionRequestId,
                        userSessionId: recycleMarker?.userSessionId,
                        sessionId: recycleMarker?.sessionId
                    },
                    undefined,
                    recycleMarker?.resetCompletedAtUtc
                );
                if (
                    activeCommandConfirmedByApi &&
                    correlatedActiveCommand &&
                    isRecycleToWarmCommand(correlatedActiveCommand)
                ) {
                    const commandToComplete = correlatedActiveCommand;
                    void captureSessionLogArtifact('reset_completed', commandToComplete, {
                        recycleId: recycleMarker?.recycleId,
                        recycleReason: recycleMarker?.reason,
                        recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                        source: update.source
                    }).catch(() => undefined);
                    void captureSessionScreenshotArtifact('reset_completed', commandToComplete, {
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
                } else {
                    if (
                        recycleMarker &&
                        activeCommandConfirmedByApi &&
                        activeCommand &&
                        isRecycleToWarmCommand(activeCommand) &&
                        !activeCommandBelongsToRecycleMarker
                    ) {
                        log(
                            `[instance-agent] Recycle ${recycleMarker.recycleId} completed without terminalizing newer recycle command ${activeCommand.instanceCommandId}; only the marker-owned token may complete it.`
                        );
                    }
                    const recycleSessionMetadata = {
                        recycleId: recycleMarker?.recycleId,
                        recycleReason: recycleMarker?.reason,
                        recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                        recycleRequestedToken: recycleMarker?.recycleRequestedToken,
                        sessionRequestId: recycleMarker?.sessionRequestId,
                        userSessionId: recycleMarker?.userSessionId,
                        sessionId: recycleMarker?.sessionId,
                        source: update.source,
                        correlation: recycleMarker?.sessionRequestId
                            ? 'recycle_marker_session'
                            : 'instance_time'
                    };
                    if (recycleMarker) {
                        void captureSessionLogArtifact('reset_completed', null, recycleSessionMetadata).catch(
                            () => undefined
                        );
                    }
                    void captureSessionScreenshotArtifact('reset_completed', null, {
                        ...recycleSessionMetadata
                    }).catch(() => undefined);
                }
            } else if (
                (resetInProgress || pendingRecycleCompletion) &&
                (nextStatus === 'stopping' || nextStatus === 'idle_shutdown_pending')
            ) {
                resetInProgress = false;
                const recycleMarker = pendingRecycleCompletion;
                const recycleMarkerToken = normalizeInstanceAgentRecycleToken(
                    recycleMarker?.recycleRequestedToken
                );
                const activeCommandBelongsToRecycleMarker =
                    !recycleMarker ||
                    Boolean(
                        activeCommand &&
                            isRecycleToWarmCommand(activeCommand) &&
                            recycleMarkerToken &&
                            normalizeInstanceAgentRecycleToken(activeCommand.instanceCommandId) ===
                                recycleMarkerToken
                    );
                const correlatedActiveCommand = activeCommandBelongsToRecycleMarker ? activeCommand : null;
                pendingRecycleCompletion = null;
                if (recycleMarker) {
                    clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log, recycleMarker.recycleId);
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
                    recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                    recycleRequestedToken: recycleMarker?.recycleRequestedToken,
                    sessionRequestId:
                        correlatedActiveCommand?.sessionRequestId ?? recycleMarker?.sessionRequestId,
                    userSessionId: recycleMarker?.userSessionId,
                    sessionId: recycleMarker?.sessionId
                });
                if (
                    activeCommandConfirmedByApi &&
                    correlatedActiveCommand &&
                    isRecycleToWarmCommand(correlatedActiveCommand)
                ) {
                    const commandToFail = correlatedActiveCommand;
                    void captureSessionLogArtifact('reset_cancelled', commandToFail, {
                        recycleId: recycleMarker?.recycleId,
                        recycleReason: recycleMarker?.reason,
                        recycleRequestedAtUtc: recycleMarker?.requestedAtUtc,
                        source: update.source,
                        cancelledStatus: nextStatus,
                        cancelledReason: nextReason
                    }).catch(() => undefined);
                    void captureSessionScreenshotArtifact('reset_cancelled', commandToFail, {
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
                } else if (
                    recycleMarker &&
                    activeCommandConfirmedByApi &&
                    activeCommand &&
                    isRecycleToWarmCommand(activeCommand) &&
                    !activeCommandBelongsToRecycleMarker
                ) {
                    log(
                        `[instance-agent] Recycle ${recycleMarker.recycleId} was cancelled without failing newer recycle command ${activeCommand.instanceCommandId}; only the marker-owned token may fail it.`
                    );
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
                    sessionRequestId: update.sessionRequestId,
                    usesTurn: update.usesTurn,
                    candidateType: update.candidateType,
                    relayProtocol: update.relayProtocol
                },
                update.sessionRequestId ?? update.sessionId
            );
        },
        setReconnectGraceWindow(window: InstanceAgentReconnectGraceWindow | null) {
            const nextWindow = window
                ? {
                      lastViewerDisconnectedAtUtc: window.lastViewerDisconnectedAtUtc,
                      reconnectGraceExpiresAtUtc: window.reconnectGraceExpiresAtUtc
                  }
                : null;
            if (
                reconnectGraceWindow?.lastViewerDisconnectedAtUtc ===
                    nextWindow?.lastViewerDisconnectedAtUtc &&
                reconnectGraceWindow?.reconnectGraceExpiresAtUtc === nextWindow?.reconnectGraceExpiresAtUtc
            ) {
                return;
            }

            reconnectGraceWindow = nextWindow;
            requestFastPolling('reconnect_grace_window_changed');
        },
        recordReconnectGraceElapsedEvidence(evidence: InstanceAgentReconnectGraceElapsedEvidence): boolean {
            if (
                reconnectGraceElapsedEvidenceJournalBlocked &&
                !refreshReconnectGraceElapsedEvidenceJournalHealth()
            ) {
                return false;
            }

            const pending = appendInstanceAgentReconnectGraceElapsedEvidence(
                reconnectGraceElapsedEvidenceJournalPath,
                evidence,
                log
            );
            if (!pending) {
                refreshReconnectGraceElapsedEvidenceJournalHealth();
                return false;
            }

            reconnectGraceElapsedEvidences = pending;
            reconnectGraceEvidenceCutoffDurableThroughMs = 0;
            if (reconnectGraceElapsedEvidenceJournalBlocked) {
                reconnectGraceElapsedEvidenceJournalBlocked = false;
                reconnectGraceElapsedEvidenceJournalFailureAttempts = 0;
                updateReconnectGraceEvidenceAdmissionBlock();
            }
            requestFastPolling('reconnect_grace_elapsed_evidence_recorded');
            return true;
        },
        getDesiredState() {
            return getExposedDesiredState();
        },
        getActiveCommand() {
            return activeCommandConfirmedByApi ? activeCommand : null;
        },
        addDesiredStateListener(listener: InstanceAgentDesiredStateListener) {
            desiredStateListeners.add(listener);
            try {
                listener(getExposedDesiredState(), { source: 'current' });
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
        isReconnectGraceRecoveryRecyclePending() {
            return (
                reconnectGraceRecoveryRecycleRequired &&
                reconnectGraceElapsedEvidences.length === 0 &&
                !pendingRecycleCompletion
            );
        },
        addReconnectGraceRecoveryListener(listener: InstanceAgentReconnectGraceRecoveryListener) {
            reconnectGraceRecoveryListeners.add(listener);
            if (
                reconnectGraceRecoveryRecycleRequired &&
                reconnectGraceElapsedEvidences.length === 0 &&
                !pendingRecycleCompletion
            ) {
                try {
                    listener();
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(`[instance-agent] Reconnect-grace recovery listener failed: ${message}`);
                }
            }
            return () => {
                reconnectGraceRecoveryListeners.delete(listener);
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
        captureSessionScreenshotArtifact(trigger, command, metadata) {
            return captureSessionScreenshotArtifact(trigger, command, metadata);
        },
        requestFastPolling(reason: string, options?: { durationMs?: number; intervalMs?: number }) {
            requestFastPolling(reason, options);
        }
    };
}
