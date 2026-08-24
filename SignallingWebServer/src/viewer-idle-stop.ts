// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile, spawn } from 'child_process';
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { promisify } from 'util';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import type { IPlayer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import {
    canExecuteAcknowledgedInstanceCommand,
    type InstanceAgentClient,
    type InstanceAgentCommand
} from './instance-agent';
import type {
    ConnectTicketRuntimeGate,
    DurableManagedViewerEvidenceStatus
} from './connect-ticket-runtime-state';
import { RuntimeStatusPublisher, SignallingRuntimeStatusController } from './runtime-status';
import {
    normalizeInstanceAgentDesiredStateSnapshot,
    readInstanceAgentDesiredStateSnapshot,
    type InstanceAgentDesiredStateSnapshot
} from './instance-agent-state';
import {
    clearInstanceAgentRecycleMarkerSnapshot,
    isInstanceAgentRecycleReplacementProof,
    readInstanceAgentRecycleMarkerSnapshot,
    resolveInstanceAgentRecycleMarkerPath,
    writeInstanceAgentRecycleMarkerSnapshot
} from './instance-agent-recycle-state';

const execFileAsync = promisify(execFile);

const DEFAULT_IDLE_GRACE_MS = 5 * 60_000;
const DEFAULT_FIRST_VIEWER_GRACE_MS = 5 * 60_000;
const DEFAULT_FIRST_VIEWER_DELAY_MS = 0;
const DEFAULT_STOP_RETRY_MS = 60_000;
const DEFAULT_IDLE_STATUS_HEARTBEAT_MS = 60_000;
const DEFAULT_RESET_GRACE_MS = 15_000;
const DEFAULT_MAINTENANCE_REFRESH_MS = 60_000;
const DEFAULT_DESIRED_STATE_REFRESH_MS = 5_000;
const DEFAULT_RECYCLE_TERMINATE_DELAY_MS = 250;
const DEFAULT_RECYCLE_SELF_EXIT_DELAY_MS = 5_000;
const DEFAULT_RECYCLE_READY_TIMEOUT_SECONDS = 120;
const DEFAULT_DISCONNECT_FAST_POLLING_WINDOW_MS = 120_000;
const RECONNECT_GRACE_EVIDENCE_RETRY_MS = 1_000;
const RECONNECT_GRACE_EVIDENCE_RETRY_LOG_INTERVAL = 30;
const STACK_RECYCLE_RETRY_MS = 5_000;
const COMMERCIAL_RECYCLE_LAUNCH_MAX_ATTEMPTS = 3;
const DEFAULT_SHUTDOWN_LOG_ARTIFACT_CAPTURE_TIMEOUT_MS = 30_000;
const DEFAULT_SHUTDOWN_SCREENSHOT_ARTIFACT_CAPTURE_TIMEOUT_MS = 120_000;
const COMMAND_SUPERSESSION_CLOCK_SKEW_MS = 5_000;
const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';
const DEFAULT_MAINTENANCE_TAG_KEY = 'ScaleWorldMaintenanceMode';

export interface ViewerIdleOptions {
    enabled?: boolean;
    graceMs?: number;
    firstViewerGraceMs?: number;
    firstViewerDelayMs?: number;
    stopRetryMs?: number;
    idleStatusHeartbeatMs?: number;
    resetGraceMs?: number;
    maintenanceRefreshMs?: number;
    maintenanceTagKey?: string;
    desiredStatePath?: string;
    desiredStateRefreshMs?: number;
    shutdownLogArtifactCaptureTimeoutMs?: number;
    shutdownScreenshotArtifactCaptureTimeoutMs?: number;
    awsCliPath?: string;
    dryRun?: boolean;
    logger?: (message: string) => void;
    runtimeStatusPublisher?: RuntimeStatusPublisher | null;
    runtimeStatusController?: SignallingRuntimeStatusController | null;
    instanceAgentClient?: Pick<
        InstanceAgentClient,
        | 'getDesiredState'
        | 'getActiveCommand'
        | 'addDesiredStateListener'
        | 'addCommandListener'
        | 'isReconnectGraceRecoveryRecyclePending'
        | 'addReconnectGraceRecoveryListener'
        | 'acknowledgeCommand'
        | 'startCommand'
        | 'completeCommand'
        | 'failCommand'
        | 'captureSessionLogArtifact'
        | 'captureSessionScreenshotArtifact'
        | 'setReconnectGraceWindow'
        | 'recordReconnectGraceElapsedEvidence'
        | 'requestFastPolling'
    > | null;
    connectTicketRuntimeGate?: Pick<
        ConnectTicketRuntimeGate,
        'markTeardownStarted' | 'getDurableManagedViewerEvidenceStatus'
    > | null;
}

type RuntimeInstanceCommand = InstanceAgentCommand & { status?: string; attemptNumber?: number };
type ScaleWorldSessionPlayer = {
    scaleWorldSessionId?: string | null;
    scaleWorldSessionRequestId?: string | null;
    scaleWorldSessionIdentityValidated?: boolean;
    scaleWorldActiveSessionIdValidated?: boolean;
};
type ManagedSessionIdentity = {
    sessionRequestId: string;
    activeSessionId?: string;
};
type ReconnectGraceWindowState = {
    lastViewerDisconnectedAtUtc: string;
    reconnectGraceExpiresAtUtc: string;
    managedSessionIdentity: ManagedSessionIdentity | null;
    elapsedEvidenceId: string;
};

async function readCurrentInstanceIdentity(): Promise<{ instanceId: string; region: string }> {
    const token = await readImdsToken();
    const [instanceId, region] = await Promise.all([
        readImdsValue('instance-id', token),
        readImdsValue('placement/region', token)
    ]);
    return {
        instanceId: instanceId.trim(),
        region: region.trim()
    };
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

function parseNonNegativeInteger(
    rawValue: unknown,
    fallback: number,
    label: string,
    log: (message: string) => void
): number {
    if (rawValue === undefined || rawValue === null || rawValue === '') return fallback;
    const rawValueText =
        typeof rawValue === 'string' ||
        typeof rawValue === 'number' ||
        typeof rawValue === 'boolean' ||
        typeof rawValue === 'bigint'
            ? String(rawValue)
            : Object.prototype.toString.call(rawValue);
    const parsed = Number.parseInt(rawValueText, 10);
    if (Number.isNaN(parsed) || parsed < 0) {
        log(`[idle-stop] Invalid ${label} value '${rawValueText}'. Using fallback ${fallback}.`);
        return fallback;
    }
    return parsed;
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

async function stopCurrentInstance(
    awsCliPath: string,
    dryRun: boolean,
    log: (message: string) => void
): Promise<void> {
    const { instanceId, region } = await readCurrentInstanceIdentity();

    if (dryRun) {
        log(`[idle-stop] DRY RUN: would stop instance ${instanceId} in region ${region}.`);
        return;
    }

    const args = ['ec2', 'stop-instances', '--region', region, '--instance-ids', instanceId];
    const { stdout, stderr } = await execFileAsync(awsCliPath, args, { windowsHide: true });
    if (stdout && stdout.trim().length > 0) log(`[idle-stop] StopInstances output: ${stdout.trim()}`);
    if (stderr && stderr.trim().length > 0) log(`[idle-stop] StopInstances stderr: ${stderr.trim()}`);
    log(`[idle-stop] StopInstances requested for ${instanceId} (${region}).`);
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, timeoutMessage: string): Promise<T> {
    if (timeoutMs <= 0) {
        return promise;
    }

    let timeout: NodeJS.Timeout | null = null;
    try {
        return await Promise.race([
            promise,
            new Promise<T>((_, reject) => {
                timeout = setTimeout(() => reject(new Error(timeoutMessage)), timeoutMs);
            })
        ]);
    } finally {
        if (timeout) {
            clearTimeout(timeout);
        }
    }
}

function normalizeArtifactMetadataText(value: unknown): string | null {
    if (typeof value !== 'string') {
        return null;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : null;
}

async function captureShutdownSessionArtifacts(
    instanceAgentClient:
        | Pick<InstanceAgentClient, 'captureSessionLogArtifact' | 'captureSessionScreenshotArtifact'>
        | null
        | undefined,
    command: RuntimeInstanceCommand | null | undefined,
    trigger: string,
    reason: string,
    log: (message: string) => void,
    logTimeoutMs: number,
    screenshotTimeoutMs: number,
    metadata: Record<string, unknown> = {}
): Promise<void> {
    if (!instanceAgentClient) {
        return;
    }

    const captureMetadata: Record<string, unknown> = {
        reason,
        source: 'viewer-idle-stop',
        ...metadata
    };
    const commandSessionRequestId = normalizeArtifactMetadataText(command?.sessionRequestId);
    const metadataSessionRequestId = normalizeArtifactMetadataText(captureMetadata.sessionRequestId);
    const metadataUserSessionId = normalizeArtifactMetadataText(captureMetadata.userSessionId);
    const metadataSessionId = normalizeArtifactMetadataText(captureMetadata.sessionId);
    const allowLastSessionCorrelation =
        captureMetadata.allowLastSessionCorrelation === true ||
        normalizeArtifactMetadataText(captureMetadata.allowLastSessionCorrelation)?.toLowerCase() === 'true';
    const selectedArtifactSessionKey =
        commandSessionRequestId ?? metadataSessionRequestId ?? metadataUserSessionId ?? metadataSessionId;

    log(
        `[idle-stop] Shutdown artifact correlation '${trigger}': commandPresent=${command ? 'true' : 'false'}, commandSessionRequestId=${commandSessionRequestId ?? '(none)'}, metadataSessionRequestId=${metadataSessionRequestId ?? '(none)'}, metadataUserSessionId=${metadataUserSessionId ?? '(none)'}, metadataSessionId=${metadataSessionId ?? '(none)'}, allowLastSessionCorrelation=${allowLastSessionCorrelation ? 'true' : 'false'}, selectedArtifactSessionKey=${selectedArtifactSessionKey ?? '(none)'}.`
    );

    if (!command) {
        log(
            selectedArtifactSessionKey
                ? `[idle-stop] Capturing shutdown artifacts '${trigger}' without an active shutdown command using metadata session identity ${selectedArtifactSessionKey}.`
                : allowLastSessionCorrelation
                  ? `[idle-stop] Capturing shutdown artifacts '${trigger}' without an active shutdown command using recent session correlation fallback.`
                  : `[idle-stop] Capturing shutdown artifacts '${trigger}' without an active shutdown command; session registration will be skipped unless metadata includes session identity.`
        );
        const instanceTimeMetadata = {
            ...captureMetadata,
            correlation: selectedArtifactSessionKey
                ? 'metadata_session'
                : allowLastSessionCorrelation
                  ? 'recent_session_context'
                  : 'instance_time'
        };
        try {
            await withTimeout(
                instanceAgentClient.captureSessionScreenshotArtifact(trigger, null, instanceTimeMetadata),
                screenshotTimeoutMs,
                `Timed out after ${screenshotTimeoutMs} ms.`
            );
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[idle-stop] Screenshot artifact capture '${trigger}' without shutdown command failed: ${message}`
            );
        }

        try {
            await withTimeout(
                instanceAgentClient.captureSessionLogArtifact(trigger, null, instanceTimeMetadata),
                logTimeoutMs,
                `Timed out after ${logTimeoutMs} ms.`
            );
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[idle-stop] Diagnostic artifact capture '${trigger}' without shutdown command failed: ${message}`
            );
        }
        return;
    }

    try {
        await withTimeout(
            instanceAgentClient.captureSessionScreenshotArtifact(trigger, command, captureMetadata),
            screenshotTimeoutMs,
            `Timed out after ${screenshotTimeoutMs} ms.`
        );
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        log(
            `[idle-stop] Screenshot artifact capture '${trigger}' for shutdown command ${command.instanceCommandId} failed: ${message}`
        );
    }

    try {
        await withTimeout(
            instanceAgentClient.captureSessionLogArtifact(trigger, command, captureMetadata),
            logTimeoutMs,
            `Timed out after ${logTimeoutMs} ms.`
        );
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        log(
            `[idle-stop] Diagnostic artifact capture '${trigger}' for shutdown command ${command.instanceCommandId} failed: ${message}`
        );
    }
}

async function readCurrentMaintenanceMode(
    awsCliPath: string,
    maintenanceTagKey: string
): Promise<string | null> {
    const { instanceId, region } = await readCurrentInstanceIdentity();
    const args = [
        'ec2',
        'describe-tags',
        '--region',
        region,
        '--filters',
        `Name=resource-id,Values=${instanceId}`,
        `Name=key,Values=${maintenanceTagKey}`,
        '--query',
        'Tags[0].Value',
        '--output',
        'text'
    ];
    const { stdout } = await execFileAsync(awsCliPath, args, { windowsHide: true });
    const normalized = stdout.trim();
    if (
        normalized.length === 0 ||
        normalized.toLowerCase() === 'none' ||
        normalized.toLowerCase() === 'null'
    ) {
        return null;
    }

    return normalized;
}

function mapPendingReason(reason: string): string {
    switch (reason) {
        case 'grace-after-last-viewer':
            return 'grace_after_last_viewer';
        case 'retry-after-failure':
            return 'retry_after_stop_failure';
        case 'no-viewer-ever-connected':
            return 'waiting_for_first_viewer_timeout';
        default:
            return reason.replace(/[^a-z0-9]+/gi, '_').toLowerCase();
    }
}

function mapStopReason(reason: string): string {
    switch (reason) {
        case 'grace-after-last-viewer':
            return 'idle_timeout';
        case 'retry-after-failure':
            return 'retry_after_stop_failure';
        case 'no-viewer-ever-connected':
            return 'no_viewer_ever_connected';
        default:
            return reason.replace(/[^a-z0-9]+/gi, '_').toLowerCase();
    }
}

export function resolveFirstViewerTimeoutStopReason(
    durableManagedViewerEvidenceStatus: DurableManagedViewerEvidenceStatus
):
    | 'no-viewer-ever-connected'
    | 'managed-viewer-history-continuity-lost'
    | 'managed-viewer-evidence-unavailable' {
    if (durableManagedViewerEvidenceStatus === 'present') {
        return 'managed-viewer-history-continuity-lost';
    }
    if (durableManagedViewerEvidenceStatus === 'unavailable') {
        return 'managed-viewer-evidence-unavailable';
    }
    return 'no-viewer-ever-connected';
}

export function wireViewerIdleStop(server: SignallingServer, options: ViewerIdleOptions = {}): void {
    const log = options.logger ?? ((message: string) => Logger.info(message));
    const enabled = parseBoolean(options.enabled ?? process.env.VIEWER_IDLE_STOP_ENABLED ?? true, true);
    if (!enabled) {
        log('[idle-stop] Disabled.');
        return;
    }

    const graceMs = parseNonNegativeInteger(
        options.graceMs ?? process.env.VIEWER_IDLE_GRACE_MS,
        DEFAULT_IDLE_GRACE_MS,
        'VIEWER_IDLE_GRACE_MS',
        log
    );
    const firstViewerGraceMs = parseNonNegativeInteger(
        options.firstViewerGraceMs ?? process.env.VIEWER_IDLE_FIRST_VIEWER_GRACE_MS,
        DEFAULT_FIRST_VIEWER_GRACE_MS,
        'VIEWER_IDLE_FIRST_VIEWER_GRACE_MS',
        log
    );
    const firstViewerDelayMs = parseNonNegativeInteger(
        options.firstViewerDelayMs ?? process.env.VIEWER_IDLE_FIRST_VIEWER_DELAY_MS,
        DEFAULT_FIRST_VIEWER_DELAY_MS,
        'VIEWER_IDLE_FIRST_VIEWER_DELAY_MS',
        log
    );
    const stopRetryMs = parseNonNegativeInteger(
        options.stopRetryMs ?? process.env.VIEWER_IDLE_STOP_RETRY_MS,
        DEFAULT_STOP_RETRY_MS,
        'VIEWER_IDLE_STOP_RETRY_MS',
        log
    );
    const idleStatusHeartbeatMs = parseNonNegativeInteger(
        options.idleStatusHeartbeatMs ?? process.env.VIEWER_IDLE_STATUS_HEARTBEAT_MS,
        DEFAULT_IDLE_STATUS_HEARTBEAT_MS,
        'VIEWER_IDLE_STATUS_HEARTBEAT_MS',
        log
    );
    const resetGraceMs = parseNonNegativeInteger(
        options.resetGraceMs ?? process.env.VIEWER_IDLE_RESET_GRACE_MS,
        DEFAULT_RESET_GRACE_MS,
        'VIEWER_IDLE_RESET_GRACE_MS',
        log
    );
    const maintenanceRefreshMs = parseNonNegativeInteger(
        options.maintenanceRefreshMs ?? process.env.VIEWER_IDLE_MAINTENANCE_REFRESH_MS,
        DEFAULT_MAINTENANCE_REFRESH_MS,
        'VIEWER_IDLE_MAINTENANCE_REFRESH_MS',
        log
    );
    const desiredStateRefreshMs = parseNonNegativeInteger(
        options.desiredStateRefreshMs ?? process.env.VIEWER_IDLE_DESIRED_STATE_REFRESH_MS,
        DEFAULT_DESIRED_STATE_REFRESH_MS,
        'VIEWER_IDLE_DESIRED_STATE_REFRESH_MS',
        log
    );
    const shutdownLogArtifactCaptureTimeoutMs = parseNonNegativeInteger(
        options.shutdownLogArtifactCaptureTimeoutMs ??
            process.env.VIEWER_IDLE_SHUTDOWN_LOG_ARTIFACT_CAPTURE_TIMEOUT_MS ??
            process.env.VIEWER_IDLE_SHUTDOWN_ARTIFACT_CAPTURE_TIMEOUT_MS,
        DEFAULT_SHUTDOWN_LOG_ARTIFACT_CAPTURE_TIMEOUT_MS,
        'VIEWER_IDLE_SHUTDOWN_LOG_ARTIFACT_CAPTURE_TIMEOUT_MS',
        log
    );
    const shutdownScreenshotArtifactCaptureTimeoutMs = parseNonNegativeInteger(
        options.shutdownScreenshotArtifactCaptureTimeoutMs ??
            process.env.VIEWER_IDLE_SHUTDOWN_SCREENSHOT_ARTIFACT_CAPTURE_TIMEOUT_MS ??
            process.env.VIEWER_IDLE_SHUTDOWN_ARTIFACT_CAPTURE_TIMEOUT_MS,
        DEFAULT_SHUTDOWN_SCREENSHOT_ARTIFACT_CAPTURE_TIMEOUT_MS,
        'VIEWER_IDLE_SHUTDOWN_SCREENSHOT_ARTIFACT_CAPTURE_TIMEOUT_MS',
        log
    );
    const dryRun = parseBoolean(options.dryRun ?? process.env.VIEWER_IDLE_STOP_DRY_RUN ?? false, false);
    const awsCliPath = String(options.awsCliPath ?? process.env.VIEWER_IDLE_AWS_CLI_PATH ?? 'aws');
    const maintenanceTagKey = String(
        options.maintenanceTagKey ??
            process.env.VIEWER_IDLE_MAINTENANCE_TAG_KEY ??
            DEFAULT_MAINTENANCE_TAG_KEY
    ).trim();
    const desiredStatePath = String(
        options.desiredStatePath ?? process.env.VIEWER_IDLE_DESIRED_STATE_PATH ?? ''
    ).trim();
    const runtimeStatusPublisher = options.runtimeStatusPublisher ?? null;
    const runtimeStatusController = options.runtimeStatusController ?? null;
    const recycleMarkerPath = resolveInstanceAgentRecycleMarkerPath(desiredStatePath);
    const recycleHelperScriptPath = path.resolve(
        __dirname,
        '..',
        'platform_scripts',
        'powershell',
        'invoke_stack_recycle.ps1'
    );
    const recycleLauncherScriptPath = path.resolve(
        __dirname,
        '..',
        'platform_scripts',
        'cmd',
        'start_stack_recycle.bat'
    );
    const recycleRepoRoot = path.resolve(__dirname, '..');

    const recoveredRecycleMarkerAtStartup = readInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
    const recoveredReplacementAtStartup = isInstanceAgentRecycleReplacementProof(
        recoveredRecycleMarkerAtStartup
    );

    let zeroViewersTimer: NodeJS.Timeout | null = null;
    let firstViewerTimer: NodeJS.Timeout | null = null;
    let transientStatusHeartbeatTimer: NodeJS.Timeout | null = null;
    let reconnectGraceTimer: NodeJS.Timeout | null = null;
    let resetTimer: NodeJS.Timeout | null = null;
    let reconnectGraceWindowPhase: 'inactive' | 'waiting' | 'persisting_elapsed' | 'elapsed' = 'inactive';
    let reconnectGraceWindowState: ReconnectGraceWindowState | null = null;
    let reconnectGraceEvidenceRetryTimer: NodeJS.Timeout | null = null;
    let reconnectGraceEvidenceRetryAttempts = 0;
    let reconnectGraceEvidenceContinuation: (() => void) | null = null;
    let commercialReconnectGraceTeardownCommitted = false;
    let commercialReconnectGraceCutoffDurable = false;
    let recycleExitFallbackTimer: NodeJS.Timeout | null = null;
    let recycleLaunchRetryTimer: NodeJS.Timeout | null = null;
    let recycleLaunchRetryAttempts = 0;
    let stopInFlight = false;
    let hasSeenViewer = server.playerRegistry.count() > 0;
    let hasSeenManagedSessionViewer = false;
    let lastManagedSessionRequestId: string | null = null;
    let lastManagedSessionObservedAtMs: number | null = null;
    const managedSessionIdentitiesByPlayerId = new Map<string, ManagedSessionIdentity>();
    let currentMaintenanceMode: string | null = null;
    let maintenanceStateInitialized = false;
    let maintenanceRefreshInFlight = false;
    let lastMaintenanceReadFailure: string | null = null;
    let desiredStateRefreshTimer: NodeJS.Timeout | null = null;
    let currentDesiredState: InstanceAgentDesiredStateSnapshot = options.instanceAgentClient
        ? options.instanceAgentClient.getDesiredState()
        : desiredStatePath.length > 0
          ? readInstanceAgentDesiredStateSnapshot(desiredStatePath, log)
          : normalizeInstanceAgentDesiredStateSnapshot(undefined);
    const recoveredRecycleTokenAtStartup = recoveredReplacementAtStartup
        ? currentDesiredState.recycleRequestedToken
        : null;
    let activeCommand: RuntimeInstanceCommand | null =
        options.instanceAgentClient?.getActiveCommand() ?? null;
    let observedCommand: RuntimeInstanceCommand | null = null;
    let pendingImmediateRecycleToken: string | null = null;
    let resetInFlight = false;
    let recycleLaunchRequested = false;
    let passiveReconnectRecycleRequested = false;
    let desiredStateShutdownResumeRequested = false;

    if (server.playerRegistry.count() === 0 && currentDesiredState.recycleRequestedToken) {
        if (currentDesiredState.recycleRequestedToken === recoveredRecycleTokenAtStartup) {
            log(
                `[idle-stop] Recycle request token ${currentDesiredState.recycleRequestedToken} was loaded on startup while a recycle marker is still present. Treating it as already launched and waiting for instance-agent completion.`
            );
        } else {
            pendingImmediateRecycleToken = currentDesiredState.recycleRequestedToken;
            log(
                `[idle-stop] Recycle request token ${currentDesiredState.recycleRequestedToken} was loaded on startup. Keeping recycle intent armed until the runtime can honor it.`
            );
        }
    }

    if (activeCommand) {
        log(
            `[idle-stop] Recovered active instance command ${activeCommand.instanceCommandId} (${activeCommand.commandType}, status=${activeCommand.status}).`
        );
    }

    const publishStatus = (
        status: string,
        reason: string,
        options: { heartbeatOnly?: boolean; preserveStatusAtUtc?: boolean } = {}
    ): void => {
        if (!runtimeStatusPublisher) return;
        void runtimeStatusPublisher.publish({
            status,
            reason,
            source: 'viewer-idle-stop',
            heartbeatOnly: options.heartbeatOnly,
            preserveStatusAtUtc: options.preserveStatusAtUtc
        });
    };
    const isCommercialReconnectDeadlineLocked = (): boolean =>
        commercialReconnectGraceTeardownCommitted ||
        (reconnectGraceWindowPhase === 'persisting_elapsed' &&
            reconnectGraceWindowState?.managedSessionIdentity !== null &&
            reconnectGraceWindowState?.managedSessionIdentity !== undefined);
    const hasManagedReconnectGraceWindow = (): boolean =>
        (reconnectGraceWindowPhase === 'waiting' || reconnectGraceWindowPhase === 'persisting_elapsed') &&
        reconnectGraceWindowState?.managedSessionIdentity !== null &&
        reconnectGraceWindowState?.managedSessionIdentity !== undefined;
    const restoreRuntimeDerivedStatus = (restoreOptions: { preserveStatusAtUtc?: boolean } = {}): void => {
        if (isCommercialReconnectDeadlineLocked()) {
            log(
                '[idle-stop] Suppressed derived Ready restoration while a commercial reconnect deadline/teardown is authoritative.'
            );
            return;
        }

        runtimeStatusController?.restoreDerivedStatus(restoreOptions);
    };

    const startReconnectGraceWindow = (
        startedAtMs: number,
        delayMs: number,
        managedSessionIdentity: ManagedSessionIdentity | null
    ): void => {
        const normalizedDelayMs = Math.max(0, delayMs);
        const lastViewerDisconnectedAtUtc = new Date(startedAtMs).toISOString();
        const reconnectGraceExpiresAtUtc = new Date(startedAtMs + normalizedDelayMs).toISOString();
        reconnectGraceWindowPhase = 'waiting';
        commercialReconnectGraceCutoffDurable = false;
        reconnectGraceWindowState = {
            lastViewerDisconnectedAtUtc,
            reconnectGraceExpiresAtUtc,
            managedSessionIdentity: managedSessionIdentity ? { ...managedSessionIdentity } : null,
            elapsedEvidenceId: randomUUID()
        };
        options.instanceAgentClient?.setReconnectGraceWindow({
            lastViewerDisconnectedAtUtc,
            reconnectGraceExpiresAtUtc
        });
    };
    const markReconnectGraceWindowElapsed = (): boolean => {
        if (reconnectGraceWindowPhase === 'elapsed') {
            return true;
        }
        if (reconnectGraceWindowPhase !== 'waiting' && reconnectGraceWindowPhase !== 'persisting_elapsed') {
            return false;
        }

        const elapsedWindow = reconnectGraceWindowState;
        const managedSessionIdentity = elapsedWindow?.managedSessionIdentity;
        if (!elapsedWindow || !managedSessionIdentity) {
            reconnectGraceWindowPhase = 'elapsed';
            log(
                '[idle-stop] Reconnect grace elapsed without a connect-ticket-validated session request identity; commercial elapsed evidence was not emitted (fail closed).'
            );
            return true;
        }

        if (!options.instanceAgentClient) {
            reconnectGraceWindowPhase = 'persisting_elapsed';
            return false;
        }

        reconnectGraceWindowPhase = 'persisting_elapsed';
        const evidenceId = elapsedWindow.elapsedEvidenceId;
        const recorded = options.instanceAgentClient.recordReconnectGraceElapsedEvidence({
            evidenceId,
            sessionRequestId: managedSessionIdentity.sessionRequestId,
            activeSessionId: managedSessionIdentity.activeSessionId,
            lastViewerDisconnectedAtUtc: elapsedWindow.lastViewerDisconnectedAtUtc,
            reconnectGraceExpiresAtUtc: elapsedWindow.reconnectGraceExpiresAtUtc,
            phase: 'elapsed'
        });
        if (recorded) {
            reconnectGraceWindowPhase = 'elapsed';
            log(
                `[idle-stop] Durably recorded reconnect-grace elapsed evidence ${evidenceId} for session request ${managedSessionIdentity.sessionRequestId}${managedSessionIdentity.activeSessionId ? ` and active session ${managedSessionIdentity.activeSessionId}` : ''}.`
            );
            return true;
        } else {
            return false;
        }
    };
    const clearReconnectGraceWindow = (): void => {
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return;
        }
        if (reconnectGraceWindowPhase === 'inactive' && !reconnectGraceWindowState) {
            return;
        }

        reconnectGraceWindowPhase = 'inactive';
        reconnectGraceWindowState = null;
        options.instanceAgentClient?.setReconnectGraceWindow(null);
    };
    const scheduleReconnectGraceEvidenceRetry = (): void => {
        if (reconnectGraceEvidenceRetryTimer) {
            return;
        }

        reconnectGraceEvidenceRetryAttempts += 1;
        if (
            reconnectGraceEvidenceRetryAttempts === 1 ||
            reconnectGraceEvidenceRetryAttempts % RECONNECT_GRACE_EVIDENCE_RETRY_LOG_INTERVAL === 0
        ) {
            const evidenceId = reconnectGraceWindowState?.elapsedEvidenceId ?? 'unknown';
            log(
                `[idle-stop] CRITICAL: Commercial reconnect deadline state for evidence ${evidenceId} is not fully durable; retry ${reconnectGraceEvidenceRetryAttempts} will run in ${RECONNECT_GRACE_EVIDENCE_RETRY_MS} ms and teardown remains blocked.`
            );
        }

        reconnectGraceEvidenceRetryTimer = setTimeout(() => {
            reconnectGraceEvidenceRetryTimer = null;
            if (!makeCommercialReconnectDeadlineDurable()) {
                scheduleReconnectGraceEvidenceRetry();
                return;
            }

            reconnectGraceEvidenceRetryAttempts = 0;
            const continuation = reconnectGraceEvidenceContinuation;
            reconnectGraceEvidenceContinuation = null;
            continuation?.();
        }, RECONNECT_GRACE_EVIDENCE_RETRY_MS);
    };
    const makeCommercialReconnectDeadlineDurable = (): boolean => {
        const elapsedWindow = reconnectGraceWindowState;
        if (elapsedWindow?.managedSessionIdentity) {
            reconnectGraceWindowPhase = 'persisting_elapsed';
            if (!markReconnectGraceWindowElapsed()) {
                return false;
            }

            // Keep the runtime gate closed to late viewers while the second durable write is retried.
            reconnectGraceWindowPhase = 'persisting_elapsed';
            if (!commercialReconnectGraceCutoffDurable) {
                commercialReconnectGraceCutoffDurable =
                    options.connectTicketRuntimeGate?.markTeardownStarted({
                        reason: 'reconnect_grace_elapsed',
                        occurredAtUtc: elapsedWindow.reconnectGraceExpiresAtUtc
                    }) === true;
                if (!commercialReconnectGraceCutoffDurable) {
                    return false;
                }
            }

            commercialReconnectGraceTeardownCommitted = true;
            reconnectGraceWindowPhase = 'elapsed';
            return true;
        }

        return markReconnectGraceWindowElapsed();
    };
    const continueAfterReconnectGraceEvidenceIsDurable = (continuation: () => void): void => {
        if (makeCommercialReconnectDeadlineDurable()) {
            continuation();
            return;
        }

        if (!reconnectGraceEvidenceContinuation) {
            reconnectGraceEvidenceContinuation = continuation;
        }
        scheduleReconnectGraceEvidenceRetry();
    };

    const clearZeroTimer = (): void => {
        if (zeroViewersTimer) {
            clearTimeout(zeroViewersTimer);
            zeroViewersTimer = null;
        }
    };
    const clearFirstViewerTimer = (): void => {
        if (firstViewerTimer) {
            clearTimeout(firstViewerTimer);
            firstViewerTimer = null;
        }
    };
    const clearTransientStatusHeartbeat = (): void => {
        if (!transientStatusHeartbeatTimer) return;
        clearInterval(transientStatusHeartbeatTimer);
        transientStatusHeartbeatTimer = null;
    };
    const clearReconnectGraceTimer = (): void => {
        if (!reconnectGraceTimer) return;
        clearTimeout(reconnectGraceTimer);
        reconnectGraceTimer = null;
    };
    const clearResetTimer = (): void => {
        if (!resetTimer) return;
        clearTimeout(resetTimer);
        resetTimer = null;
    };
    const clearDesiredStateRefreshTimer = (): void => {
        if (!desiredStateRefreshTimer) return;
        clearInterval(desiredStateRefreshTimer);
        desiredStateRefreshTimer = null;
    };
    const clearRecycleExitFallbackTimer = (): void => {
        if (!recycleExitFallbackTimer) return;
        clearTimeout(recycleExitFallbackTimer);
        recycleExitFallbackTimer = null;
    };
    const startTransientStatusHeartbeat = (status: string, reason: string): void => {
        clearTransientStatusHeartbeat();
        if (idleStatusHeartbeatMs <= 0 || !runtimeStatusPublisher) {
            return;
        }
        transientStatusHeartbeatTimer = setInterval(() => {
            publishStatus(status, reason, { heartbeatOnly: true });
        }, idleStatusHeartbeatMs);
    };
    const isMaintenanceActive = (): boolean => (currentMaintenanceMode?.trim().length ?? 0) > 0;
    const isRecycleToWarmCommand = (
        command: { commandType?: string | null; instanceCommandId?: string | null } | null | undefined
    ): boolean => (command?.commandType?.trim().toLowerCase() ?? '') === 'recycletowarm';
    const isShutdownCommand = (
        command: { commandType?: string | null; instanceCommandId?: string | null } | null | undefined
    ): boolean => (command?.commandType?.trim().toLowerCase() ?? '') === 'shutdown';
    const markConnectTicketTeardownStarted = (
        reason: string,
        command?: RuntimeInstanceCommand | null,
        occurredAtUtc?: string | null
    ): boolean => {
        const persisted =
            options.connectTicketRuntimeGate?.markTeardownStarted({
                reason,
                commandType: command?.commandType,
                instanceCommandId: command?.instanceCommandId,
                occurredAtUtc: occurredAtUtc ?? undefined
            }) === true;
        if (!persisted) {
            log(
                `[idle-stop] CRITICAL: Teardown cutoff for '${reason}' could not be persisted; managed admission is blocked and destructive teardown must not proceed.`
            );
        }
        return persisted;
    };
    const normalizeOptionalText = (value?: string | null): string | null => {
        const normalized = value?.trim() ?? '';
        return normalized.length > 0 ? normalized : null;
    };
    const commandMatchesCurrentManagedSession = (
        command: { sessionRequestId?: string | null; requestedAtUtc?: string | null } | null | undefined
    ): boolean => {
        const commandSessionRequestId = normalizeOptionalText(command?.sessionRequestId);
        if (!commandSessionRequestId || !lastManagedSessionRequestId) {
            return true;
        }

        if (commandSessionRequestId.toLowerCase() === lastManagedSessionRequestId.toLowerCase()) {
            return true;
        }

        if (lastManagedSessionObservedAtMs === null) {
            return true;
        }

        // The last managed session id can survive warm reuse. Only treat a
        // different command as stale when it predates the latest managed viewer.
        const commandRequestedAtMs = Date.parse(normalizeOptionalText(command?.requestedAtUtc) ?? '');
        if (!Number.isFinite(commandRequestedAtMs)) {
            return true;
        }

        return commandRequestedAtMs > lastManagedSessionObservedAtMs - COMMAND_SUPERSESSION_CLOCK_SKEW_MS;
    };
    const isCommandSupersededByCurrentManagedSession = (
        command: { sessionRequestId?: string | null; requestedAtUtc?: string | null } | null | undefined
    ): boolean => !commandMatchesCurrentManagedSession(command);
    const readActiveCommand = (): RuntimeInstanceCommand | null => {
        if (options.instanceAgentClient) {
            activeCommand = options.instanceAgentClient.getActiveCommand();
        }
        return activeCommand ?? observedCommand;
    };
    const getActiveRecycleCommand = () => {
        const currentActiveCommand = readActiveCommand();
        return isRecycleToWarmCommand(currentActiveCommand) &&
            commandMatchesCurrentManagedSession(currentActiveCommand)
            ? currentActiveCommand
            : null;
    };
    const getActiveShutdownCommand = () => {
        const currentActiveCommand = readActiveCommand();
        return isShutdownCommand(currentActiveCommand) &&
            commandMatchesCurrentManagedSession(currentActiveCommand)
            ? currentActiveCommand
            : null;
    };
    const hasRecycleLaunchMarker = (): boolean =>
        isInstanceAgentRecycleReplacementProof(
            readInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log)
        );
    const hasRecycleLaunchInProgress = (): boolean => recycleLaunchRequested || hasRecycleLaunchMarker();
    const isRecoveredRecycleTokenStillInProgress = (token: string | null | undefined): boolean =>
        token === recoveredRecycleTokenAtStartup && hasRecycleLaunchMarker();
    const canHoldWarmReadyWithoutShutdown = (): boolean =>
        currentDesiredState.warmHoldEnabled &&
        !currentDesiredState.drainEnabled &&
        !currentDesiredState.shutdownRequested;
    const hasPendingImmediateRecycle = (): boolean =>
        pendingImmediateRecycleToken !== null &&
        pendingImmediateRecycleToken === currentDesiredState.recycleRequestedToken;
    const hasImmediateRecycleRequest = (): boolean =>
        hasPendingImmediateRecycle() && !hasRecycleLaunchInProgress();
    const hasPassiveReconnectRecycleRequest = (): boolean =>
        passiveReconnectRecycleRequested && !hasRecycleLaunchInProgress();
    const hasExplicitRecycleIntent = (): boolean =>
        getActiveRecycleCommand() !== null || hasImmediateRecycleRequest();
    const hasRecycleIntent = (): boolean => hasExplicitRecycleIntent() || hasPassiveReconnectRecycleRequest();
    const shouldSuppressNoViewerIdleAutomation = (): boolean =>
        canHoldWarmReadyWithoutShutdown() && getActiveShutdownCommand() === null && !hasRecycleIntent();
    const isWarmHoldActive = (): boolean => shouldSuppressNoViewerIdleAutomation() && !hasSeenViewer;
    const shouldResetIntoWarmReady = (): boolean => hasRecycleIntent();
    const readValidatedManagedSessionViewerIdentity = (playerId?: string): ManagedSessionIdentity | null => {
        const normalizedPlayerId = normalizeOptionalText(playerId);
        if (!normalizedPlayerId) {
            return null;
        }

        const player = server.playerRegistry.get(normalizedPlayerId) as ScaleWorldSessionPlayer | undefined;
        const sessionRequestId = normalizeOptionalText(player?.scaleWorldSessionRequestId);
        if (!sessionRequestId || player?.scaleWorldSessionIdentityValidated !== true) {
            return null;
        }

        const activeSessionId =
            player.scaleWorldActiveSessionIdValidated === true
                ? (normalizeOptionalText(player.scaleWorldSessionId) ?? undefined)
                : undefined;
        return { sessionRequestId, activeSessionId };
    };
    const countManagedSessionViewers = (sessionRequestId?: string): number => {
        const normalizedSessionRequestId = normalizeOptionalText(sessionRequestId);
        let count = 0;
        for (const identity of managedSessionIdentitiesByPlayerId.values()) {
            if (
                !normalizedSessionRequestId ||
                identity.sessionRequestId.toLowerCase() === normalizedSessionRequestId.toLowerCase()
            ) {
                count += 1;
            }
        }
        return count;
    };
    const hasViewerThatCancelsReconnectGrace = (
        managedSessionIdentity: ManagedSessionIdentity | null
    ): boolean =>
        managedSessionIdentity
            ? countManagedSessionViewers(managedSessionIdentity.sessionRequestId) > 0
            : server.playerRegistry.count() > 0;
    const markManagedSessionViewer = (
        playerId?: string,
        useStoredIdentityFallback: boolean = false
    ): ManagedSessionIdentity | null => {
        const normalizedPlayerId = normalizeOptionalText(playerId);
        if (!normalizedPlayerId) {
            return null;
        }

        const storedIdentity = managedSessionIdentitiesByPlayerId.get(normalizedPlayerId) ?? null;
        if (useStoredIdentityFallback) {
            return storedIdentity;
        }

        const identity = readValidatedManagedSessionViewerIdentity(normalizedPlayerId);
        if (!identity) {
            managedSessionIdentitiesByPlayerId.delete(normalizedPlayerId);
            return null;
        }

        hasSeenManagedSessionViewer = true;
        lastManagedSessionRequestId = identity.sessionRequestId;
        lastManagedSessionObservedAtMs = Date.now();
        managedSessionIdentitiesByPlayerId.set(normalizedPlayerId, identity);
        return identity;
    };
    const resolveShutdownArtifactSessionRequestId = (
        reason: string,
        requestedSessionRequestId?: string | null
    ): string | null => {
        const requested = normalizeOptionalText(requestedSessionRequestId);
        if (requested) {
            return requested;
        }

        if (!hasSeenViewer || !hasSeenManagedSessionViewer || reason === 'warm_pool_capacity_release') {
            return null;
        }

        return lastManagedSessionRequestId;
    };
    const resolveRecycleMarkerSessionRequestId = (
        command: { sessionRequestId?: string | null } | null | undefined
    ): string | null => {
        const commandSessionRequestId = normalizeOptionalText(command?.sessionRequestId);
        if (commandSessionRequestId) {
            return commandSessionRequestId;
        }

        if (!hasSeenViewer || !hasSeenManagedSessionViewer) {
            return null;
        }

        return lastManagedSessionRequestId;
    };
    const disconnectPlayersForExplicitTeardown = (command: RuntimeInstanceCommand): number => {
        const players: IPlayer[] = server.playerRegistry.listPlayers();
        if (players.length === 0) {
            return 0;
        }

        const operation = isShutdownCommand(command) ? 'shutdown' : 'recycle';
        log(
            `[idle-stop] ${operation} command ${command.instanceCommandId} requested while ${players.length} viewer(s) are still connected. Disconnecting viewers before teardown.`
        );

        for (const player of players) {
            try {
                player.protocol.disconnect(4001, 'Connect ticket revoked: ScaleWorld session ended');
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(
                    `[idle-stop] Failed to disconnect viewer ${player.playerId} for ${operation} command ${command.instanceCommandId}: ${message}`
                );
            }
        }

        return players.length;
    };
    const failSupersededCommand = async (
        command: RuntimeInstanceCommand | InstanceAgentCommand,
        source: string
    ): Promise<boolean> => {
        if (!isCommandSupersededByCurrentManagedSession(command)) {
            return false;
        }

        log(
            `[idle-stop] Cancelling stale ${command.commandType} command ${command.instanceCommandId} from ${source} because it targets session request ${command.sessionRequestId ?? '(none)'} while the current managed session request is ${lastManagedSessionRequestId}.`
        );

        if (!options.instanceAgentClient) {
            return true;
        }

        try {
            await options.instanceAgentClient.failCommand(command, {
                failureCode: 'superseded_by_current_session',
                failureMessage:
                    'Command targets an older session request after a newer managed session connected.',
                terminalStatus: 'Cancelled',
                occurredAtUtc: new Date().toISOString()
            });
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[idle-stop] Failed to cancel stale command ${command.instanceCommandId} from ${source}: ${message}`
            );
        } finally {
            refreshActiveCommand();
        }

        return true;
    };
    const failSupersededActiveCommand = (source: string): void => {
        const command = readActiveCommand();
        if (!command || !isCommandSupersededByCurrentManagedSession(command)) {
            return;
        }

        void failSupersededCommand(command, source);
    };
    const resolveDesiredStateShutdownReason = (): string => {
        if (getActiveShutdownCommand()) {
            return 'command_shutdown_requested';
        }

        const desiredStateMessage = currentDesiredState.message?.trim().toLowerCase() ?? '';
        if (
            desiredStateMessage.startsWith('automatic warm release') ||
            desiredStateMessage.startsWith('warm-pool capacity release')
        ) {
            return 'warm_pool_capacity_release';
        }

        return 'agent_shutdown_requested';
    };
    const refreshActiveCommand = (): void => {
        readActiveCommand();
    };
    const tryStartLaunchedRecycleCommand = async (reason: string): Promise<void> => {
        const commandToStart = getActiveRecycleCommand();
        if (
            !commandToStart ||
            commandToStart.status === 'running' ||
            !options.instanceAgentClient ||
            !hasRecycleLaunchInProgress()
        ) {
            return;
        }

        try {
            const startResult = await options.instanceAgentClient.startCommand(commandToStart, {
                occurredAtUtc: new Date().toISOString()
            });
            refreshActiveCommand();
            if (!canExecuteAcknowledgedInstanceCommand(startResult)) {
                passiveReconnectRecycleRequested = true;
                log(
                    `[idle-stop] Recycle command ${commandToStart.instanceCommandId} became invalid after its recycle was launched (status=${startResult.commandStatus}). The non-destructive cleanup will finish without that command generation.`
                );
                return;
            }
            log(
                `[idle-stop] Marked recycle command ${commandToStart.instanceCommandId} as started after recycle launch (${reason}).`
            );
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[idle-stop] Failed to mark launched recycle command ${commandToStart.instanceCommandId} as started: ${message}`
            );
        }
    };
    const tryResumeActiveRecycleCommand = (): void => {
        if (
            !getActiveRecycleCommand() ||
            resetInFlight ||
            hasRecycleLaunchInProgress() ||
            server.playerRegistry.count() > 0 ||
            !maintenanceStateInitialized ||
            isMaintenanceActive()
        ) {
            return;
        }

        startResetWindow(true);
    };
    const tryResumeActiveShutdownCommand = (): void => {
        if (
            !getActiveShutdownCommand() ||
            stopInFlight ||
            server.playerRegistry.count() > 0 ||
            !maintenanceStateInitialized ||
            isMaintenanceActive()
        ) {
            return;
        }

        void requestStop('command_shutdown_requested');
    };
    const tryResumeDesiredStateShutdown = (): boolean => {
        if (
            !currentDesiredState.shutdownRequested ||
            desiredStateShutdownResumeRequested ||
            stopInFlight ||
            server.playerRegistry.count() > 0 ||
            !maintenanceStateInitialized ||
            isMaintenanceActive()
        ) {
            return false;
        }

        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();
        desiredStateShutdownResumeRequested = true;
        log('[idle-stop] Resuming shutdown requested by desired state.');
        void requestStop(resolveDesiredStateShutdownReason())
            .then((accepted) => {
                if (!accepted) {
                    desiredStateShutdownResumeRequested = false;
                }
            })
            .catch(() => {
                desiredStateShutdownResumeRequested = false;
            });
        return true;
    };
    const clearAllIdleStopTimers = (): void => {
        if (hasManagedReconnectGraceWindow()) {
            clearFirstViewerTimer();
            clearResetTimer();
            log(
                '[idle-stop] Preserving the managed commercial reconnect timer across an idle-automation cancellation request.'
            );
            return;
        }

        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();
        clearReconnectGraceTimer();
        clearResetTimer();
        clearReconnectGraceWindow();
    };
    const ensureFirstViewerWindow = (): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive() || shouldSuppressNoViewerIdleAutomation()) {
            clearFirstViewerTimer();
            return;
        }

        if (hasSeenViewer || server.playerRegistry.count() > 0 || firstViewerGraceMs <= 0) {
            clearFirstViewerTimer();
            return;
        }

        if (firstViewerTimer) {
            return;
        }

        firstViewerTimer = setTimeout(() => {
            firstViewerTimer = null;
            if (
                hasSeenViewer ||
                server.playerRegistry.count() > 0 ||
                isMaintenanceActive() ||
                isWarmHoldActive()
            ) {
                return;
            }

            const durableManagedViewerEvidenceStatus =
                options.connectTicketRuntimeGate?.getDurableManagedViewerEvidenceStatus() ?? 'none';
            const reason = resolveFirstViewerTimeoutStopReason(durableManagedViewerEvidenceStatus);
            if (reason !== 'no-viewer-ever-connected') {
                log(
                    durableManagedViewerEvidenceStatus === 'present'
                        ? '[idle-stop] CRITICAL: Refusing no-viewer-ever-connected after restart because durable evidence proves a managed viewer was previously admitted. No disconnect boundary is inferred; cleanup is reported with an unsupported continuity-loss reason.'
                        : '[idle-stop] CRITICAL: Refusing no-viewer-ever-connected because durable managed-viewer evidence cannot be verified. Admission and zero-use classification remain fail closed.'
                );
                void requestStop(reason);
                return;
            }
            void requestStop(reason);
        }, firstViewerDelayMs + firstViewerGraceMs);

        log(
            `[idle-stop] First-viewer window active (delay=${firstViewerDelayMs} ms, grace=${firstViewerGraceMs} ms).`
        );
    };
    const refreshMaintenanceMode = async (): Promise<void> => {
        if (maintenanceRefreshInFlight || maintenanceTagKey.length === 0) {
            return;
        }

        maintenanceRefreshInFlight = true;
        try {
            const nextMaintenanceMode = await readCurrentMaintenanceMode(awsCliPath, maintenanceTagKey);
            maintenanceStateInitialized = true;
            if (nextMaintenanceMode !== currentMaintenanceMode) {
                currentMaintenanceMode = nextMaintenanceMode;
                if (currentMaintenanceMode) {
                    log(
                        `[idle-stop] Maintenance mode '${currentMaintenanceMode}' detected. Suspending idle-stop timers.`
                    );
                    clearAllIdleStopTimers();
                } else {
                    log('[idle-stop] Maintenance mode cleared. Re-evaluating idle-stop timers.');
                    if (tryResumeDesiredStateShutdown()) {
                        return;
                    }
                    if (!resetInFlight && server.playerRegistry.count() === 0 && shouldResetIntoWarmReady()) {
                        if (hasRecycleLaunchInProgress()) {
                            return;
                        }
                        if (getActiveRecycleCommand()) {
                            tryResumeActiveRecycleCommand();
                        } else {
                            scheduleResetAfterLastViewer(graceMs);
                        }
                    } else {
                        ensureFirstViewerWindow();
                    }
                }
            } else if (!currentMaintenanceMode) {
                if (tryResumeDesiredStateShutdown()) {
                    return;
                }
                if (!resetInFlight && server.playerRegistry.count() === 0 && shouldResetIntoWarmReady()) {
                    if (hasRecycleLaunchInProgress()) {
                        return;
                    }
                    if (getActiveRecycleCommand()) {
                        tryResumeActiveRecycleCommand();
                    } else {
                        scheduleResetAfterLastViewer(graceMs);
                    }
                } else {
                    ensureFirstViewerWindow();
                }
            }

            lastMaintenanceReadFailure = null;
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            if (message !== lastMaintenanceReadFailure) {
                log(`[idle-stop] Failed to read maintenance mode: ${message}`);
                lastMaintenanceReadFailure = message;
            }
        } finally {
            maintenanceRefreshInFlight = false;
        }
    };
    const applyDesiredStateSnapshot = (
        nextDesiredState: InstanceAgentDesiredStateSnapshot,
        source: string
    ): void => {
        const recycleRequestedTokenChanged =
            nextDesiredState.recycleRequestedToken !== currentDesiredState.recycleRequestedToken;
        const shutdownRequestedChanged =
            nextDesiredState.shutdownRequested !== currentDesiredState.shutdownRequested;
        const changed =
            nextDesiredState.warmHoldEnabled !== currentDesiredState.warmHoldEnabled ||
            nextDesiredState.drainEnabled !== currentDesiredState.drainEnabled ||
            shutdownRequestedChanged ||
            recycleRequestedTokenChanged ||
            nextDesiredState.policyVersion !== currentDesiredState.policyVersion ||
            nextDesiredState.message !== currentDesiredState.message;
        currentDesiredState = nextDesiredState;
        if (!currentDesiredState.shutdownRequested) {
            desiredStateShutdownResumeRequested = false;
        }

        if (!changed) {
            tryResumeDesiredStateShutdown();
            return;
        }

        let desiredStateTeardownCutoffDurable = true;
        if (recycleRequestedTokenChanged) {
            if (currentDesiredState.recycleRequestedToken) {
                desiredStateTeardownCutoffDurable = markConnectTicketTeardownStarted(
                    'desired_state_recycle_request',
                    null,
                    currentDesiredState.updatedAtUtc
                );
                if (isRecoveredRecycleTokenStillInProgress(currentDesiredState.recycleRequestedToken)) {
                    pendingImmediateRecycleToken = null;
                    log(
                        `[idle-stop] Ignoring recovered recycle request token ${currentDesiredState.recycleRequestedToken} because this process started after that recycle was already launched.`
                    );
                } else {
                    pendingImmediateRecycleToken = currentDesiredState.recycleRequestedToken;
                    if (currentDesiredState.recycleRequestedToken === recoveredRecycleTokenAtStartup) {
                        log(
                            `[idle-stop] Recovered recycle request token ${currentDesiredState.recycleRequestedToken} is active again after its recycle marker cleared.`
                        );
                    }
                    if (hasRecycleLaunchInProgress()) {
                        log(
                            `[idle-stop] Recycle request token ${currentDesiredState.recycleRequestedToken} matches an in-progress recycle. Waiting for recycle completion before reuse.`
                        );
                    } else {
                        log(
                            `[idle-stop] Immediate recycle requested by desired state token ${currentDesiredState.recycleRequestedToken}.`
                        );
                    }
                }
            } else {
                pendingImmediateRecycleToken = null;
            }
        }
        if (shutdownRequestedChanged && currentDesiredState.shutdownRequested) {
            desiredStateTeardownCutoffDurable =
                markConnectTicketTeardownStarted(
                    'desired_state_shutdown_request',
                    null,
                    currentDesiredState.updatedAtUtc
                ) && desiredStateTeardownCutoffDurable;
        }

        log(
            `[idle-stop] Desired state updated from ${source}: warmHold=${currentDesiredState.warmHoldEnabled}, drain=${currentDesiredState.drainEnabled}, shutdown=${currentDesiredState.shutdownRequested}, recycleRequested=${currentDesiredState.recycleRequestedToken ? 'true' : 'false'}, policy=${currentDesiredState.policyVersion}.`
        );

        if (!desiredStateTeardownCutoffDurable) {
            if (currentDesiredState.shutdownRequested) {
                void requestStop(resolveDesiredStateShutdownReason());
            } else if (currentDesiredState.recycleRequestedToken) {
                startResetWindow(true);
            }
            return;
        }

        if (
            hasManagedReconnectGraceWindow() &&
            !currentDesiredState.shutdownRequested &&
            !currentDesiredState.recycleRequestedToken
        ) {
            log(
                '[idle-stop] Desired-state update leaves the active managed commercial reconnect window unchanged.'
            );
            return;
        }

        if (isWarmHoldActive()) {
            clearAllIdleStopTimers();
            restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        if (reconnectGraceTimer && shouldSuppressNoViewerIdleAutomation()) {
            return;
        }

        if (reconnectGraceTimer && !shouldResetIntoWarmReady()) {
            clearReconnectGraceTimer();
            clearReconnectGraceWindow();
            if (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0) {
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop(resolveDesiredStateShutdownReason());
                return;
            }

            if (canHoldWarmReadyWithoutShutdown()) {
                restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        if (resetTimer && shouldSuppressNoViewerIdleAutomation()) {
            clearResetTimer();
            clearReconnectGraceWindow();
            restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        if (resetTimer && !shouldResetIntoWarmReady()) {
            clearResetTimer();
            clearReconnectGraceWindow();
            if (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0) {
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop(resolveDesiredStateShutdownReason());
                return;
            }

            if (canHoldWarmReadyWithoutShutdown()) {
                restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        if (
            getActiveShutdownCommand() &&
            server.playerRegistry.count() === 0 &&
            maintenanceStateInitialized &&
            !isMaintenanceActive()
        ) {
            tryResumeActiveShutdownCommand();
            return;
        }

        if (tryResumeDesiredStateShutdown()) {
            return;
        }

        if (
            hasPendingImmediateRecycle() &&
            server.playerRegistry.count() === 0 &&
            maintenanceStateInitialized &&
            !isMaintenanceActive() &&
            shouldResetIntoWarmReady()
        ) {
            startResetWindow(true);
            return;
        }

        if (
            server.playerRegistry.count() === 0 &&
            maintenanceStateInitialized &&
            !isMaintenanceActive() &&
            shouldResetIntoWarmReady()
        ) {
            if (!resetInFlight && !hasRecycleLaunchInProgress()) {
                if (getActiveRecycleCommand()) {
                    tryResumeActiveRecycleCommand();
                } else {
                    scheduleResetAfterLastViewer(graceMs);
                }
            }
            return;
        }

        ensureFirstViewerWindow();
        if (
            (currentDesiredState.shutdownRequested || getActiveShutdownCommand()) &&
            server.playerRegistry.count() === 0
        ) {
            void requestStop(resolveDesiredStateShutdownReason());
        }
    };

    const refreshDesiredState = (): void => {
        if (desiredStatePath.length === 0) {
            return;
        }

        applyDesiredStateSnapshot(readInstanceAgentDesiredStateSnapshot(desiredStatePath, log), 'file');
    };

    const scheduleStop = (
        reason: string,
        delayMs: number,
        startsLastViewerReconnectWindow: boolean = false,
        managedSessionIdentity: ManagedSessionIdentity | null = null
    ): void => {
        if (
            !isCommercialReconnectDeadlineLocked() &&
            (!maintenanceStateInitialized || isMaintenanceActive())
        ) {
            return;
        }
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return;
        }

        if (startsLastViewerReconnectWindow && reconnectGraceWindowPhase !== 'inactive') {
            return;
        }
        if (!startsLastViewerReconnectWindow && reconnectGraceWindowPhase === 'waiting') {
            clearReconnectGraceWindow();
        }
        clearReconnectGraceTimer();
        if (!isCommercialReconnectDeadlineLocked() && shouldSuppressNoViewerIdleAutomation()) {
            clearAllIdleStopTimers();
            restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        clearZeroTimer();
        const mappedPendingReason = mapPendingReason(reason);
        publishStatus('idle_shutdown_pending', mappedPendingReason);
        startTransientStatusHeartbeat('idle_shutdown_pending', mappedPendingReason);
        const artifactSessionRequestId =
            reason === 'grace-after-last-viewer' ? lastManagedSessionRequestId : null;
        const scheduledAtMs = startsLastViewerReconnectWindow && delayMs > 0 ? Date.now() : null;
        zeroViewersTimer = setTimeout(() => {
            zeroViewersTimer = null;
            if (scheduledAtMs !== null) {
                if (hasViewerThatCancelsReconnectGrace(managedSessionIdentity)) {
                    clearReconnectGraceWindow();
                    restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                    return;
                }
                continueAfterReconnectGraceEvidenceIsDurable(() => {
                    void requestStop(reason, artifactSessionRequestId);
                });
                return;
            }
            void requestStop(reason, artifactSessionRequestId);
        }, delayMs);
        if (scheduledAtMs !== null) {
            startReconnectGraceWindow(scheduledAtMs, delayMs, managedSessionIdentity);
        }
        log(
            `[idle-stop] Scheduled stop in ${delayMs} ms (reason=${reason}, pendingReason=${mappedPendingReason}).`
        );
    };

    const scheduleResetAfterLastViewer = (
        delayMs: number,
        startsLastViewerReconnectWindow: boolean = false,
        managedSessionIdentity: ManagedSessionIdentity | null = null
    ): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive()) {
            return;
        }
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return;
        }

        if (resetInFlight || hasRecycleLaunchInProgress()) {
            return;
        }

        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();

        if (!shouldResetIntoWarmReady()) {
            if (reconnectGraceWindowPhase === 'waiting') {
                clearReconnectGraceWindow();
            }
            return;
        }

        if (hasPendingImmediateRecycle()) {
            startResetWindow(true);
            return;
        }

        if (getActiveRecycleCommand()) {
            startResetWindow(true);
            return;
        }

        if (reconnectGraceTimer) {
            return;
        }

        const shouldStartReconnectGraceWindow =
            startsLastViewerReconnectWindow || reconnectGraceWindowPhase === 'waiting' || hasSeenViewer;
        if (shouldStartReconnectGraceWindow) {
            clearReconnectGraceWindow();
        }

        publishStatus('reconnect_grace', 'waiting_for_viewer_reconnect');
        startTransientStatusHeartbeat('reconnect_grace', 'waiting_for_viewer_reconnect');

        const finishReconnectGrace = (): void => {
            if (commercialReconnectGraceTeardownCommitted) {
                if (currentDesiredState.shutdownRequested || getActiveShutdownCommand()) {
                    void requestStop(resolveDesiredStateShutdownReason());
                    return;
                }

                passiveReconnectRecycleRequested = true;
                startResetWindow(true);
                return;
            }

            if (!maintenanceStateInitialized || isMaintenanceActive()) {
                clearReconnectGraceWindow();
                return;
            }

            if (hasViewerThatCancelsReconnectGrace(managedSessionIdentity)) {
                clearReconnectGraceWindow();
                restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop(resolveDesiredStateShutdownReason());
                return;
            }

            if (!shouldResetIntoWarmReady()) {
                if (canHoldWarmReadyWithoutShutdown()) {
                    restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                    return;
                }

                scheduleStop('grace-after-last-viewer', 0);
                return;
            }

            startResetWindow();
        };

        if (delayMs <= 0) {
            finishReconnectGrace();
            return;
        }

        const scheduledAtMs = shouldStartReconnectGraceWindow ? Date.now() : null;
        reconnectGraceTimer = setTimeout(() => {
            reconnectGraceTimer = null;
            if (shouldStartReconnectGraceWindow) {
                if (hasViewerThatCancelsReconnectGrace(managedSessionIdentity)) {
                    clearReconnectGraceWindow();
                    restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                    return;
                }
                continueAfterReconnectGraceEvidenceIsDurable(finishReconnectGrace);
                return;
            }
            finishReconnectGrace();
        }, delayMs);
        if (scheduledAtMs !== null) {
            startReconnectGraceWindow(scheduledAtMs, delayMs, managedSessionIdentity);
        }

        log(`[idle-stop] Viewer reconnect window active for ${delayMs} ms before warm recycle.`);
    };

    const scheduleWarmHoldReconnectGrace = (
        delayMs: number,
        startsLastViewerReconnectWindow: boolean = false,
        managedSessionIdentity: ManagedSessionIdentity | null = null
    ): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive()) {
            return;
        }
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return;
        }

        if (!shouldSuppressNoViewerIdleAutomation()) {
            return;
        }

        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();

        if (reconnectGraceTimer) {
            return;
        }

        const shouldStartReconnectGraceWindow =
            startsLastViewerReconnectWindow || reconnectGraceWindowPhase === 'waiting' || hasSeenViewer;
        if (shouldStartReconnectGraceWindow) {
            clearReconnectGraceWindow();
        }

        publishStatus('reconnect_grace', 'waiting_for_viewer_reconnect');
        startTransientStatusHeartbeat('reconnect_grace', 'waiting_for_viewer_reconnect');

        const expireWarmHoldReconnectGrace = (): void => {
            if (commercialReconnectGraceTeardownCommitted) {
                if (getActiveShutdownCommand() || currentDesiredState.shutdownRequested) {
                    void requestStop(resolveDesiredStateShutdownReason());
                    return;
                }

                clearTransientStatusHeartbeat();
                passiveReconnectRecycleRequested = true;
                log(
                    '[idle-stop] Reconnect grace elapsed for a validated commercial session. Recycling remains authoritative after durable evidence recording.'
                );
                startResetWindow(true);
                return;
            }

            if (!maintenanceStateInitialized || isMaintenanceActive()) {
                clearReconnectGraceWindow();
                return;
            }

            if (hasViewerThatCancelsReconnectGrace(managedSessionIdentity)) {
                clearReconnectGraceWindow();
                restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            if (getActiveRecycleCommand() || hasPendingImmediateRecycle()) {
                startResetWindow(true);
                return;
            }

            if (getActiveShutdownCommand() || currentDesiredState.shutdownRequested) {
                void requestStop(resolveDesiredStateShutdownReason());
                return;
            }

            if (shouldSuppressNoViewerIdleAutomation()) {
                if (!hasSeenManagedSessionViewer) {
                    restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                    log(
                        '[idle-stop] Warm-held reconnect grace expired without managed session evidence. Restoring derived status without passive recycle.'
                    );
                    return;
                }

                clearTransientStatusHeartbeat();
                passiveReconnectRecycleRequested = true;
                if (!markConnectTicketTeardownStarted('passive_reconnect_grace_recycle')) {
                    publishStatus('resetting', 'teardown_cutoff_persistence_failed');
                    startResetWindow(true);
                    return;
                }
                log(
                    '[idle-stop] Reconnect grace expired without an explicit teardown command. Recycling warm instance for post-session cleanup.'
                );
                startResetWindow(true);
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
        };

        if (delayMs <= 0) {
            expireWarmHoldReconnectGrace();
            return;
        }

        const scheduledAtMs = shouldStartReconnectGraceWindow ? Date.now() : null;
        reconnectGraceTimer = setTimeout(() => {
            reconnectGraceTimer = null;
            if (shouldStartReconnectGraceWindow) {
                if (hasViewerThatCancelsReconnectGrace(managedSessionIdentity)) {
                    clearReconnectGraceWindow();
                    restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                    return;
                }
                continueAfterReconnectGraceEvidenceIsDurable(expireWarmHoldReconnectGrace);
                return;
            }
            expireWarmHoldReconnectGrace();
        }, delayMs);
        if (scheduledAtMs !== null) {
            startReconnectGraceWindow(scheduledAtMs, delayMs, managedSessionIdentity);
        }

        log(
            hasSeenManagedSessionViewer
                ? `[idle-stop] Viewer reconnect window active for ${delayMs} ms; warm hold will recycle when grace expires unless an explicit teardown command arrives first.`
                : `[idle-stop] Viewer reconnect window active for ${delayMs} ms; warm hold will restore ready without passive recycle if no managed session evidence appears.`
        );
    };

    const scheduleRetryIfStillIdle = (): void => {
        if (
            !commercialReconnectGraceTeardownCommitted &&
            (stopRetryMs <= 0 ||
                server.playerRegistry.count() > 0 ||
                !maintenanceStateInitialized ||
                isMaintenanceActive())
        ) {
            return;
        }

        publishStatus('idle_shutdown_pending', 'retry_after_stop_failure');
        scheduleStop('retry-after-failure', stopRetryMs > 0 ? stopRetryMs : STACK_RECYCLE_RETRY_MS);
    };

    const restoreAfterReset = (): void => {
        if (commercialReconnectGraceTeardownCommitted) {
            resetInFlight = true;
            publishStatus('resetting', 'commercial_recycle_retry_pending');
            log(
                '[idle-stop] CRITICAL: Suppressed logical warm restore after committed commercial teardown; the instance remains non-ready until recycle or stop succeeds.'
            );
            scheduleStackRecycleRetry('logical_restore_suppressed');
            return;
        }

        resetInFlight = false;
        recycleLaunchRequested = false;
        passiveReconnectRecycleRequested = false;
        clearReconnectGraceWindow();
        clearRecycleExitFallbackTimer();
        clearReconnectGraceTimer();
        clearResetTimer();
        if (server.playerRegistry.count() > 0 || !maintenanceStateInitialized || isMaintenanceActive()) {
            restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        hasSeenViewer = false;
        if (currentDesiredState.shutdownRequested) {
            void requestStop(resolveDesiredStateShutdownReason());
            return;
        }

        if (!canHoldWarmReadyWithoutShutdown()) {
            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        restoreRuntimeDerivedStatus();
    };

    const clearStackRecycleRetryTimer = (): void => {
        if (!recycleLaunchRetryTimer) {
            return;
        }

        clearTimeout(recycleLaunchRetryTimer);
        recycleLaunchRetryTimer = null;
    };

    const scheduleStackRecycleRetry = (reason: string): void => {
        if (recycleLaunchRetryTimer) {
            return;
        }

        publishStatus('resetting', 'recycle_launch_retry_pending');
        log(
            `[idle-stop] Full stack recycle remains pending after '${reason}'; retrying in ${STACK_RECYCLE_RETRY_MS} ms without restoring Ready.`
        );
        recycleLaunchRetryTimer = setTimeout(() => {
            recycleLaunchRetryTimer = null;
            void requestStackRecycle();
        }, STACK_RECYCLE_RETRY_MS);
    };

    const handleStackRecycleLaunchFailure = (message: string): void => {
        if (!commercialReconnectGraceTeardownCommitted) {
            log(
                `[idle-stop] Failed to request full stack recycle: ${message}. Falling back to logical warm restore.`
            );
            restoreAfterReset();
            return;
        }

        resetInFlight = true;
        passiveReconnectRecycleRequested = true;
        recycleLaunchRetryAttempts += 1;
        publishStatus('resetting', 'commercial_recycle_launch_failed');
        if (recycleLaunchRetryAttempts >= COMMERCIAL_RECYCLE_LAUNCH_MAX_ATTEMPTS) {
            clearStackRecycleRetryTimer();
            log(
                `[idle-stop] CRITICAL: Full stack recycle failed ${recycleLaunchRetryAttempts} time(s) after committed commercial teardown; escalating to instance stop without restoring Ready.`
            );
            void requestStop('commercial_recycle_launch_failed');
            return;
        }

        log(
            `[idle-stop] CRITICAL: Full stack recycle attempt ${recycleLaunchRetryAttempts} failed after committed commercial teardown: ${message}. The instance remains non-ready.`
        );
        scheduleStackRecycleRetry('commercial_recycle_launch_failed');
    };

    async function requestStackRecycle(): Promise<void> {
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return;
        }
        if (recycleLaunchRequested) {
            return;
        }

        if (
            !commercialReconnectGraceTeardownCommitted &&
            (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0)
        ) {
            restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        if (!shouldResetIntoWarmReady()) {
            if (canHoldWarmReadyWithoutShutdown()) {
                restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop(resolveDesiredStateShutdownReason());
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        const commandToStart = getActiveRecycleCommand();
        if (!commercialReconnectGraceCutoffDurable) {
            commercialReconnectGraceCutoffDurable = markConnectTicketTeardownStarted(
                commandToStart ? 'stack_recycle_command_launch' : 'stack_recycle_launch',
                commandToStart,
                commandToStart?.requestedAtUtc ?? currentDesiredState.updatedAtUtc
            );
            if (!commercialReconnectGraceCutoffDurable) {
                resetInFlight = true;
                publishStatus('resetting', 'teardown_cutoff_persistence_failed');
                scheduleStackRecycleRetry('teardown_cutoff_persistence_failed');
                return;
            }
        }

        try {
            if (commandToStart && options.instanceAgentClient) {
                try {
                    const startResult = await options.instanceAgentClient.startCommand(commandToStart, {
                        occurredAtUtc: new Date().toISOString()
                    });
                    refreshActiveCommand();
                    if (!canExecuteAcknowledgedInstanceCommand(startResult)) {
                        log(
                            `[idle-stop] Recycle command ${commandToStart.instanceCommandId} became invalid before execution (status=${startResult.commandStatus}). Continuing the already-committed cleanup without executing that command generation.`
                        );
                        passiveReconnectRecycleRequested = true;
                    }
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(
                        `[idle-stop] Failed to mark recycle command ${commandToStart.instanceCommandId} as started: ${message}`
                    );
                }
            }

            if (!fs.existsSync(recycleHelperScriptPath)) {
                throw new Error(`Recycle helper script '${recycleHelperScriptPath}' was not found.`);
            }
            if (!fs.existsSync(recycleLauncherScriptPath)) {
                throw new Error(`Recycle launcher script '${recycleLauncherScriptPath}' was not found.`);
            }
            const recycleMarker = writeInstanceAgentRecycleMarkerSnapshot(
                recycleMarkerPath,
                {
                    phase: 'intent',
                    requestedAtUtc: new Date().toISOString(),
                    reason: 'post_session_cleanup',
                    recycleId: randomUUID(),
                    sessionRequestId: resolveRecycleMarkerSessionRequestId(commandToStart) ?? undefined,
                    sourcePid: process.pid
                },
                log
            );
            const recycleProcess = spawn(
                'cmd.exe',
                [
                    '/d',
                    '/s',
                    '/c',
                    recycleLauncherScriptPath,
                    '-RepoRoot',
                    recycleRepoRoot,
                    '-RecycleMarkerPath',
                    recycleMarkerPath,
                    '-SourcePid',
                    String(process.pid),
                    '-WaitBeforeTerminateMilliseconds',
                    String(DEFAULT_RECYCLE_TERMINATE_DELAY_MS),
                    '-WaitForWilburTimeoutSeconds',
                    String(DEFAULT_RECYCLE_READY_TIMEOUT_SECONDS)
                ],
                {
                    detached: true,
                    stdio: 'ignore',
                    windowsHide: true
                }
            );
            recycleProcess.on('error', (error) => {
                recycleLaunchRequested = false;
                clearRecycleExitFallbackTimer();
                clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
                handleStackRecycleLaunchFailure(`Recycle helper process failed to start: ${error.message}`);
            });
            recycleProcess.unref();
            pendingImmediateRecycleToken = null;
            recycleLaunchRequested = true;
            recycleLaunchRetryAttempts = 0;
            clearStackRecycleRetryTimer();
            clearRecycleExitFallbackTimer();
            recycleExitFallbackTimer = setTimeout(() => {
                recycleExitFallbackTimer = null;
                if (!hasRecycleLaunchInProgress()) {
                    return;
                }

                log(
                    '[idle-stop] Recycle helper fallback: current Wilbur process is still alive after helper launch. Exiting so recycle can complete.'
                );
                process.exit(0);
            }, DEFAULT_RECYCLE_SELF_EXIT_DELAY_MS);
            log(
                `[idle-stop] Requested full stack recycle (${recycleMarker.recycleId ?? 'unknown'}) via '${recycleLauncherScriptPath}'.`
            );
        } catch (error) {
            recycleLaunchRequested = false;
            clearRecycleExitFallbackTimer();
            clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
            const message = error instanceof Error ? error.message : String(error);
            const commandToFail = getActiveRecycleCommand();
            if (options.instanceAgentClient && commandToFail) {
                void options.instanceAgentClient
                    .failCommand(commandToFail, {
                        failureCode: 'recycle_launch_failed',
                        failureMessage: message,
                        occurredAtUtc: new Date().toISOString()
                    })
                    .catch((reportError) => {
                        const reportMessage =
                            reportError instanceof Error ? reportError.message : String(reportError);
                        log(
                            `[idle-stop] Failed to report recycle command failure for ${commandToFail.instanceCommandId}: ${reportMessage}`
                        );
                    })
                    .finally(() => {
                        refreshActiveCommand();
                    });
            }
            handleStackRecycleLaunchFailure(message);
        }
    }

    const startResetWindow = (skipGrace: boolean = false): void => {
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return;
        }
        if (
            !commercialReconnectGraceTeardownCommitted &&
            (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0)
        ) {
            clearReconnectGraceWindow();
            return;
        }

        if (reconnectGraceWindowPhase === 'waiting') {
            clearReconnectGraceWindow();
        }

        clearReconnectGraceTimer();
        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();

        if (!shouldResetIntoWarmReady()) {
            return;
        }

        resetInFlight = true;
        publishStatus('resetting', 'post_session_cleanup');
        if (skipGrace || getActiveRecycleCommand() || resetGraceMs <= 0) {
            void requestStackRecycle();
            return;
        }

        if (resetTimer) {
            return;
        }

        resetTimer = setTimeout(() => {
            resetTimer = null;
            void requestStackRecycle();
        }, resetGraceMs);

        log(
            skipGrace
                ? '[idle-stop] Entered immediate warm reset path with no reconnect grace.'
                : `[idle-stop] Entered warm reset window for ${resetGraceMs} ms before full stack recycle.`
        );
    };

    const requestStop = async (
        reason: string,
        artifactSessionRequestId?: string | null
    ): Promise<boolean> => {
        if (reconnectGraceWindowPhase === 'persisting_elapsed') {
            return false;
        }
        if (stopInFlight) return false;
        const shutdownCommand = getActiveShutdownCommand();
        if (!commercialReconnectGraceCutoffDurable) {
            commercialReconnectGraceCutoffDurable = markConnectTicketTeardownStarted(
                shutdownCommand ? 'stack_shutdown_command_launch' : `stack_shutdown_${reason}`,
                shutdownCommand,
                shutdownCommand?.requestedAtUtc ?? currentDesiredState.updatedAtUtc
            );
            if (!commercialReconnectGraceCutoffDurable) {
                publishStatus('idle_shutdown_pending', 'teardown_cutoff_persistence_failed');
                scheduleStop(reason, STACK_RECYCLE_RETRY_MS);
                return false;
            }
        }
        resetInFlight = false;
        recycleLaunchRequested = false;
        passiveReconnectRecycleRequested = false;
        if (reconnectGraceWindowPhase === 'waiting') {
            clearReconnectGraceWindow();
        }
        clearRecycleExitFallbackTimer();
        clearTransientStatusHeartbeat();
        clearReconnectGraceTimer();
        clearResetTimer();
        if (
            !commercialReconnectGraceTeardownCommitted &&
            (!maintenanceStateInitialized || isMaintenanceActive())
        ) {
            clearReconnectGraceWindow();
            return false;
        }

        if (!commercialReconnectGraceTeardownCommitted && server.playerRegistry.count() > 0) {
            clearReconnectGraceWindow();
            log('[idle-stop] Stop request aborted because viewers are connected.');
            restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            return false;
        }

        if (!commercialReconnectGraceTeardownCommitted && shouldSuppressNoViewerIdleAutomation()) {
            clearReconnectGraceWindow();
            log(
                `[idle-stop] Stop request '${reason}' ignored because the instance is warm-held without an explicit teardown command.`
            );
            if (hasSeenViewer) {
                scheduleWarmHoldReconnectGrace(graceMs, true);
            } else {
                restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
            }
            return false;
        }

        stopInFlight = true;
        try {
            const commandToStart = getActiveShutdownCommand();
            if (commandToStart && options.instanceAgentClient) {
                try {
                    const startResult = await options.instanceAgentClient.startCommand(commandToStart, {
                        occurredAtUtc: new Date().toISOString()
                    });
                    refreshActiveCommand();
                    if (!canExecuteAcknowledgedInstanceCommand(startResult)) {
                        log(
                            `[idle-stop] Refusing instance stop because shutdown command ${commandToStart.instanceCommandId} became invalid before execution (status=${startResult.commandStatus}).`
                        );
                        return false;
                    }
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(
                        `[idle-stop] Failed to mark shutdown command ${commandToStart.instanceCommandId} as started: ${message}`
                    );
                }
            }

            const commandSessionRequestId = normalizeOptionalText(commandToStart?.sessionRequestId);
            const shutdownArtifactSessionRequestId = commandSessionRequestId
                ? null
                : resolveShutdownArtifactSessionRequestId(reason, artifactSessionRequestId);
            const allowLastSessionCorrelation =
                !commandSessionRequestId &&
                !shutdownArtifactSessionRequestId &&
                hasSeenViewer &&
                reason !== 'warm_pool_capacity_release';
            const shutdownArtifactMetadata: Record<string, unknown> | undefined =
                shutdownArtifactSessionRequestId || allowLastSessionCorrelation
                    ? {
                          sessionRequestId: shutdownArtifactSessionRequestId ?? undefined,
                          allowLastSessionCorrelation: allowLastSessionCorrelation ? true : undefined
                      }
                    : undefined;

            await captureShutdownSessionArtifacts(
                options.instanceAgentClient,
                commandToStart,
                'shutdown_requested',
                reason,
                log,
                shutdownLogArtifactCaptureTimeoutMs,
                shutdownScreenshotArtifactCaptureTimeoutMs,
                shutdownArtifactMetadata
            );

            publishStatus('stopping', mapStopReason(reason));
            log(`[idle-stop] Triggering stop (reason=${reason}).`);
            await stopCurrentInstance(awsCliPath, dryRun, log);
            const commandToComplete = getActiveShutdownCommand();
            if (commandToComplete && options.instanceAgentClient) {
                try {
                    await options.instanceAgentClient.completeCommand(commandToComplete, {
                        occurredAtUtc: new Date().toISOString(),
                        resultJson: JSON.stringify({
                            reason
                        })
                    });
                } catch (error) {
                    const message = error instanceof Error ? error.message : String(error);
                    log(
                        `[idle-stop] Failed to complete shutdown command ${commandToComplete.instanceCommandId}: ${message}`
                    );
                } finally {
                    refreshActiveCommand();
                }
            }
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(`[idle-stop] Stop request failed: ${message}`);
            const commandToFail = getActiveShutdownCommand();
            if (commandToFail && options.instanceAgentClient) {
                try {
                    await captureShutdownSessionArtifacts(
                        options.instanceAgentClient,
                        commandToFail,
                        'shutdown_failed',
                        reason,
                        log,
                        shutdownLogArtifactCaptureTimeoutMs,
                        shutdownScreenshotArtifactCaptureTimeoutMs,
                        { failureMessage: message }
                    );
                    await options.instanceAgentClient.failCommand(commandToFail, {
                        failureCode: 'shutdown_request_failed',
                        failureMessage: message,
                        occurredAtUtc: new Date().toISOString()
                    });
                } catch (reportError) {
                    const reportMessage =
                        reportError instanceof Error ? reportError.message : String(reportError);
                    log(
                        `[idle-stop] Failed to report shutdown command failure for ${commandToFail.instanceCommandId}: ${reportMessage}`
                    );
                } finally {
                    refreshActiveCommand();
                }
            }
            publishStatus('idle_shutdown_pending', 'stop_request_failed');
            scheduleRetryIfStillIdle();
        } finally {
            stopInFlight = false;
        }

        return true;
    };

    const onViewerAdded = (playerId?: string): void => {
        if (isCommercialReconnectDeadlineLocked()) {
            const latePlayer = playerId ? server.playerRegistry.get(playerId) : undefined;
            log(
                `[idle-stop] Rejecting viewer ${playerId ?? '(unknown)'} because the reconnect deadline has elapsed and commercial teardown is irrevocable.`
            );
            try {
                latePlayer?.protocol.disconnect(4001, 'Connect ticket rejected: reconnect grace has elapsed');
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(`[idle-stop] Failed to disconnect late viewer ${playerId ?? '(unknown)'}: ${message}`);
            }
            return;
        }

        hasSeenViewer = true;
        const candidateManagedIdentity = readValidatedManagedSessionViewerIdentity(playerId);
        const connectedManagedRequestId = managedSessionIdentitiesByPlayerId.values().next()
            .value?.sessionRequestId;
        const reconnectWindowManagedRequestId =
            reconnectGraceWindowPhase === 'waiting'
                ? reconnectGraceWindowState?.managedSessionIdentity?.sessionRequestId
                : undefined;
        const conflictingManagedRequestId = connectedManagedRequestId ?? reconnectWindowManagedRequestId;
        if (
            candidateManagedIdentity &&
            conflictingManagedRequestId &&
            candidateManagedIdentity.sessionRequestId.toLowerCase() !==
                conflictingManagedRequestId.toLowerCase()
        ) {
            const conflictingPlayer = playerId ? server.playerRegistry.get(playerId) : undefined;
            log(
                `[idle-stop] CRITICAL: Rejecting managed viewer ${playerId ?? '(unknown)'} for session request ${candidateManagedIdentity.sessionRequestId}; this instance is already owned by managed request ${conflictingManagedRequestId}.`
            );
            try {
                conflictingPlayer?.protocol.disconnect(
                    4001,
                    'Connect ticket rejected: instance is assigned to another managed session'
                );
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(
                    `[idle-stop] Failed to disconnect conflicting managed viewer ${playerId ?? '(unknown)'}: ${message}`
                );
            }
            return;
        }

        const managedIdentity = markManagedSessionViewer(playerId);
        if (
            !managedIdentity &&
            reconnectGraceWindowPhase === 'waiting' &&
            reconnectGraceWindowState?.managedSessionIdentity
        ) {
            log(
                `[idle-stop] Claimless viewer ${playerId ?? '(unknown)'} connected while managed request ${reconnectGraceWindowState.managedSessionIdentity.sessionRequestId} is in reconnect grace; commercial timing is unchanged.`
            );
            return;
        }

        failSupersededActiveCommand('viewer_connected');
        resetInFlight = false;
        recycleLaunchRequested = false;
        passiveReconnectRecycleRequested = false;
        clearRecycleExitFallbackTimer();
        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();
        clearReconnectGraceTimer();
        clearResetTimer();
        clearReconnectGraceWindow();
        restoreRuntimeDerivedStatus({ preserveStatusAtUtc: true });
        log(`[idle-stop] Viewer connected (count=${server.playerRegistry.count()}).`);
    };

    const onViewerRemoved = (removedPlayerId?: string): void => {
        if (isCommercialReconnectDeadlineLocked()) {
            log(
                `[idle-stop] Viewer ${removedPlayerId ?? '(unknown)'} disconnected after the reconnect deadline; existing teardown remains authoritative.`
            );
            return;
        }

        const removedManagedSessionIdentity = markManagedSessionViewer(removedPlayerId, true);
        const normalizedRemovedPlayerId = normalizeOptionalText(removedPlayerId);
        if (normalizedRemovedPlayerId) {
            managedSessionIdentitiesByPlayerId.delete(normalizedRemovedPlayerId);
        }
        const rawCount = server.playerRegistry.count();
        const removedEntryStillPresent =
            typeof removedPlayerId === 'string' && removedPlayerId.length > 0
                ? server.playerRegistry.has(removedPlayerId)
                : false;
        const effectiveCount = Math.max(0, rawCount - (removedEntryStillPresent ? 1 : 0));
        const remainingManagedViewerCount = removedManagedSessionIdentity
            ? countManagedSessionViewers(removedManagedSessionIdentity.sessionRequestId)
            : countManagedSessionViewers();
        log(
            `[idle-stop] Viewer disconnected (count=${effectiveCount}, managedCount=${remainingManagedViewerCount}, rawCount=${rawCount}, removedEntryStillPresent=${removedEntryStillPresent}).`
        );
        if (removedManagedSessionIdentity && remainingManagedViewerCount > 0) {
            return;
        }

        const handleZeroViewersAfterRemoval = (ignoreClaimlessViewers: boolean): void => {
            if (!ignoreClaimlessViewers && server.playerRegistry.count() > 0) {
                log(
                    '[idle-stop] Viewer disconnect handling skipped because viewers are connected after registry settled.'
                );
                return;
            }

            failSupersededActiveCommand('viewer_disconnected');

            if (maintenanceStateInitialized && !isMaintenanceActive() && shouldResetIntoWarmReady()) {
                options.instanceAgentClient?.requestFastPolling('viewer_disconnected_reconnect_grace', {
                    durationMs: Math.min(Math.max(graceMs, 20_000), DEFAULT_DISCONNECT_FAST_POLLING_WINDOW_MS)
                });
                if (getActiveRecycleCommand()) {
                    startResetWindow(true);
                    return;
                }
                if (hasPendingImmediateRecycle()) {
                    startResetWindow(true);
                    return;
                }

                scheduleResetAfterLastViewer(graceMs, true, removedManagedSessionIdentity);
                return;
            }

            if (maintenanceStateInitialized && !isMaintenanceActive() && getActiveShutdownCommand()) {
                void requestStop('command_shutdown_requested');
                return;
            }

            if (
                maintenanceStateInitialized &&
                !isMaintenanceActive() &&
                shouldSuppressNoViewerIdleAutomation()
            ) {
                options.instanceAgentClient?.requestFastPolling('viewer_disconnected_reconnect_grace', {
                    durationMs: Math.min(Math.max(graceMs, 20_000), DEFAULT_DISCONNECT_FAST_POLLING_WINDOW_MS)
                });
                scheduleWarmHoldReconnectGrace(graceMs, true, removedManagedSessionIdentity);
                return;
            }

            scheduleStop('grace-after-last-viewer', graceMs, true, removedManagedSessionIdentity);
        };

        if (removedManagedSessionIdentity) {
            log(
                `[idle-stop] Last validated managed viewer for session request ${removedManagedSessionIdentity.sessionRequestId} disconnected; starting its commercial reconnect grace independently of ${effectiveCount} claimless viewer(s).`
            );
            handleZeroViewersAfterRemoval(true);
            return;
        }

        if (reconnectGraceWindowPhase === 'waiting' && reconnectGraceWindowState?.managedSessionIdentity) {
            log(
                `[idle-stop] Claimless viewer ${removedPlayerId ?? '(unknown)'} disconnected during managed reconnect grace; commercial timing is unchanged.`
            );
            return;
        }

        if (effectiveCount !== 0) {
            return;
        }

        if (removedEntryStillPresent) {
            setTimeout(() => handleZeroViewersAfterRemoval(false), 0);
            return;
        }

        handleZeroViewersAfterRemoval(false);
    };

    server.playerRegistry.on('added', onViewerAdded);
    server.playerRegistry.on('removed', onViewerRemoved);
    log('[idle-stop] Wired to player registry events.');

    if (options.instanceAgentClient) {
        const instanceAgentClient = options.instanceAgentClient;
        options.instanceAgentClient.addReconnectGraceRecoveryListener(() => {
            if (!options.instanceAgentClient?.isReconnectGraceRecoveryRecyclePending()) {
                return;
            }
            if (commercialReconnectGraceTeardownCommitted) {
                return;
            }

            commercialReconnectGraceTeardownCommitted = true;
            commercialReconnectGraceCutoffDurable = false;
            passiveReconnectRecycleRequested = true;
            publishStatus('resetting', 'recovered_commercial_teardown_cleanup');
            log(
                '[idle-stop] Recovered commercial teardown state requires cleanup after authoritative control-state reconciliation. Keeping managed admission closed and forcing stack cleanup before Ready can return.'
            );
            if (currentDesiredState.shutdownRequested || getActiveShutdownCommand()) {
                void requestStop('recovered_commercial_teardown_cleanup');
                return;
            }

            startResetWindow(true);
        });
        options.instanceAgentClient.addDesiredStateListener((nextDesiredState, context) => {
            applyDesiredStateSnapshot(nextDesiredState, `agent:${context.source}`);
        });
        options.instanceAgentClient.addCommandListener((command: InstanceAgentCommand) => {
            void (async () => {
                let trackedCommand = readActiveCommand();
                if (trackedCommand && (await failSupersededCommand(trackedCommand, 'active-command'))) {
                    trackedCommand = null;
                }

                if (await failSupersededCommand(command, 'command-listener')) {
                    return;
                }

                if (trackedCommand && trackedCommand.instanceCommandId === command.instanceCommandId) {
                    return;
                }

                if (!isRecycleToWarmCommand(command) && !isShutdownCommand(command)) {
                    log(
                        `[idle-stop] Unsupported instance command ${command.instanceCommandId} (${command.commandType}). Reporting failure.`
                    );
                    try {
                        await options.instanceAgentClient?.failCommand(command, {
                            failureCode: 'unsupported_command',
                            failureMessage: `Unsupported command type '${command.commandType}'.`,
                            terminalStatus: 'Failed',
                            occurredAtUtc: new Date().toISOString()
                        });
                    } catch (error) {
                        const message = error instanceof Error ? error.message : String(error);
                        log(
                            `[idle-stop] Failed to report unsupported command ${command.instanceCommandId}: ${message}`
                        );
                    } finally {
                        refreshActiveCommand();
                    }
                    return;
                }

                if (trackedCommand && trackedCommand.instanceCommandId !== command.instanceCommandId) {
                    log(
                        `[idle-stop] Rejecting recycle command ${command.instanceCommandId} because command ${trackedCommand.instanceCommandId} is already active.`
                    );
                    try {
                        await options.instanceAgentClient?.failCommand(command, {
                            failureCode: 'command_conflict',
                            failureMessage: `Instance command '${trackedCommand.instanceCommandId}' is already active on this host.`,
                            terminalStatus: 'Cancelled',
                            occurredAtUtc: new Date().toISOString()
                        });
                    } catch (error) {
                        const message = error instanceof Error ? error.message : String(error);
                        log(
                            `[idle-stop] Failed to report conflicting command ${command.instanceCommandId}: ${message}`
                        );
                    }
                    return;
                }

                if (
                    !markConnectTicketTeardownStarted(
                        isShutdownCommand(command) ? 'explicit_shutdown_command' : 'explicit_recycle_command',
                        command,
                        command.requestedAtUtc
                    )
                ) {
                    log(
                        `[idle-stop] Command ${command.instanceCommandId} remains unacknowledged until its teardown cutoff can be persisted.`
                    );
                    return;
                }
                observedCommand = command;
                try {
                    const acknowledgement = await instanceAgentClient.acknowledgeCommand(command, {
                        occurredAtUtc: new Date().toISOString()
                    });
                    observedCommand = null;
                    refreshActiveCommand();
                    if (!canExecuteAcknowledgedInstanceCommand(acknowledgement)) {
                        log(
                            `[idle-stop] Refusing to execute teardown command ${command.instanceCommandId} because acknowledgement returned ${acknowledgement.commandStatus}.`
                        );
                        return;
                    }
                    if (server.playerRegistry.count() === 0) {
                        if (isShutdownCommand(command)) {
                            void requestStop('command_shutdown_requested');
                            return;
                        }

                        if (hasRecycleLaunchInProgress()) {
                            await tryStartLaunchedRecycleCommand('command_ack_after_recycle_launch');
                            return;
                        }

                        tryResumeActiveRecycleCommand();
                    } else {
                        disconnectPlayersForExplicitTeardown(command);
                    }
                } catch (error) {
                    if (observedCommand?.instanceCommandId === command.instanceCommandId) {
                        observedCommand = null;
                    }
                    const message = error instanceof Error ? error.message : String(error);
                    log(
                        `${isShutdownCommand(command) ? '[idle-stop] Failed to acknowledge shutdown command' : '[idle-stop] Failed to acknowledge recycle command'} ${command.instanceCommandId}: ${message}`
                    );
                }
            })();
        });
    }

    if (maintenanceRefreshMs > 0 && maintenanceTagKey.length > 0) {
        void refreshMaintenanceMode();
        setInterval(() => {
            void refreshMaintenanceMode();
        }, maintenanceRefreshMs);
    } else {
        maintenanceStateInitialized = true;
        ensureFirstViewerWindow();
        tryResumeActiveRecycleCommand();
        tryResumeActiveShutdownCommand();
        tryResumeDesiredStateShutdown();
    }

    if (desiredStatePath.length > 0 && desiredStateRefreshMs > 0) {
        refreshDesiredState();
        clearDesiredStateRefreshTimer();
        desiredStateRefreshTimer = setInterval(() => {
            refreshDesiredState();
        }, desiredStateRefreshMs);
    }

    tryResumeActiveRecycleCommand();
    tryResumeActiveShutdownCommand();
    tryResumeDesiredStateShutdown();
}
