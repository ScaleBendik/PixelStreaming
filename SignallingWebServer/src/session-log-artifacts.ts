// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile } from 'child_process';
import { createHash, randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { promisify } from 'util';
import { gzip } from 'zlib';

const execFileAsync = promisify(execFile);
const gzipAsync = promisify(gzip);

const DEFAULT_OBJECT_PREFIX = 'pixelstreaming/session-log-artifacts';
const DEFAULT_MAX_BUNDLE_BYTES = 2 * 1024 * 1024;
const DEFAULT_MAX_ENTRY_BYTES = 512 * 1024;
const MAX_DRAIN_RECORDS = 3;

type QueueRecordStatus = 'pending_upload' | 'pending_registration';

interface LogCandidate {
    kind: string;
    path: string;
    required?: boolean;
}

interface BundleEntry {
    kind: string;
    path: string;
    exists: boolean;
    sizeBytes?: number;
    modifiedAtUtc?: string;
    tailBytes?: number;
    truncatedStart?: boolean;
    content?: string;
    error?: string;
}

interface ArtifactQueueRecord {
    id: string;
    status: QueueRecordStatus;
    createdAtUtc: string;
    updatedAtUtc: string;
    attempts: number;
    lastError?: string;
    localPath: string;
    bucketName: string;
    objectKey: string;
    request: SessionLogArtifactRegistrationRequest;
}

export interface SessionLogArtifactRuntimeOptions {
    enabled?: unknown;
    bucketName?: string;
    objectPrefix?: string;
    awsCliPath?: string;
    awsRegion?: string;
    queuePath?: string;
    maxBytes?: unknown;
    logFolder?: string;
    desiredStatePath?: string;
    watchdogLogPath?: string;
    unrealLogDirectory?: string;
    includeWilburLogs?: unknown;
    includeWatchdogLogs?: unknown;
    includeUnrealLogs?: unknown;
    includeStackRecycleLog?: unknown;
    includeRuntimeStatusSnapshot?: unknown;
}

export interface SessionLogArtifactRegistrationRequest {
    instanceId: string;
    region: string;
    sessionRequestId?: string;
    userSessionId?: string;
    sessionId?: string;
    artifactType: string;
    bucketName: string;
    objectKey: string;
    objectVersionId?: string;
    eTag?: string;
    sizeBytes?: number;
    checksumSha256?: string;
    timeRangeStartUtc?: string;
    timeRangeEndUtc?: string;
    uploadedAtUtc?: string;
    metadata: Record<string, string>;
}

export interface SessionLogArtifactCaptureContext {
    trigger: string;
    instanceId: string;
    region: string;
    sessionRequestId?: string;
    userSessionId?: string;
    sessionId?: string;
    instanceCommandId?: string;
    commandType?: string;
    runtimeStatus?: string;
    runtimeReason?: string;
    runtimeVersion?: string;
    recycleId?: string;
    recycleReason?: string;
    recycleRequestedAtUtc?: string;
    timeRangeStartUtc?: string;
    timeRangeEndUtc?: string;
    metadata?: Record<string, unknown>;
}

export interface SessionLogArtifactManagerOptions extends SessionLogArtifactRuntimeOptions {
    registerArtifact: (request: SessionLogArtifactRegistrationRequest) => Promise<void>;
    logger?: (message: string) => void;
}

export interface SessionLogArtifactManager {
    captureAndUpload(context: SessionLogArtifactCaptureContext): Promise<void>;
    drainQueue(): Promise<void>;
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

function parsePositiveInteger(rawValue: unknown, fallback: number): number {
    if (rawValue === undefined || rawValue === null || rawValue === '') return fallback;
    if (typeof rawValue !== 'string' && typeof rawValue !== 'number') return fallback;
    const parsed = Number.parseInt(String(rawValue), 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function normalizeOptionalText(value: unknown): string | undefined {
    if (typeof value !== 'string') {
        return undefined;
    }

    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

function normalizeGuidText(value: unknown): string | undefined {
    const normalized = normalizeOptionalText(value);
    if (!normalized) {
        return undefined;
    }

    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(normalized)
        ? normalized
        : undefined;
}

function truncateText(value: string, maxLength: number): string {
    if (value.length <= maxLength) {
        return value;
    }

    return `${value.slice(0, Math.max(0, maxLength - 3))}...`;
}

function normalizeMetadata(input: Record<string, unknown> | undefined): Record<string, string> {
    const metadata: Record<string, string> = {};
    if (!input) {
        return metadata;
    }

    for (const [key, value] of Object.entries(input)) {
        const normalizedKey = normalizeOptionalText(key);
        if (!normalizedKey || value === undefined || value === null) {
            continue;
        }

        if (typeof value === 'string') {
            const normalizedValue = normalizeOptionalText(value);
            if (normalizedValue) {
                metadata[normalizedKey] = truncateText(normalizedValue, 512);
            }
            continue;
        }

        if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
            metadata[normalizedKey] = truncateText(String(value), 512);
        }
    }

    return metadata;
}

function sanitizeKeySegment(value: string | undefined, fallback: string): string {
    const normalized = normalizeOptionalText(value) ?? fallback;
    const sanitized = normalized.replace(/[^a-zA-Z0-9._=-]+/g, '-').replace(/^-+|-+$/g, '');
    return sanitized.length > 0 ? sanitized.slice(0, 96) : fallback;
}

function normalizeObjectPrefix(value: string | undefined): string {
    const normalized = normalizeOptionalText(value) ?? DEFAULT_OBJECT_PREFIX;
    return normalized.replace(/^\/+|\/+$/g, '') || DEFAULT_OBJECT_PREFIX;
}

function resolveRepoRoot(): string {
    return path.resolve(__dirname, '..');
}

function resolvePathMaybeRelative(value: string | undefined, root: string): string | undefined {
    const normalized = normalizeOptionalText(value);
    if (!normalized) {
        return undefined;
    }

    return path.isAbsolute(normalized) ? normalized : path.resolve(root, normalized);
}

function listLatestFiles(directory: string, kind: string, limit: number): LogCandidate[] {
    let entries: fs.Dirent[];
    try {
        entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
        return [];
    }

    return entries
        .filter((entry) => entry.isFile())
        .map((entry) => path.join(directory, entry.name))
        .filter((filePath) => /\.(log|txt|json)$/i.test(filePath))
        .map((filePath) => {
            try {
                return { filePath, modifiedMs: fs.statSync(filePath).mtimeMs };
            } catch {
                return { filePath, modifiedMs: 0 };
            }
        })
        .sort((left, right) => right.modifiedMs - left.modifiedMs)
        .slice(0, limit)
        .map((entry) => ({ kind, path: entry.filePath }));
}

function addExistingCandidate(
    candidates: LogCandidate[],
    kind: string,
    filePath: string | undefined,
    required = false
): void {
    if (!filePath) {
        return;
    }

    candidates.push({ kind, path: filePath, required });
}

function discoverUnrealLogDirectories(options: SessionLogArtifactManagerOptions, repoRoot: string): string[] {
    const directories: string[] = [];
    const explicitDirectory =
        normalizeOptionalText(options.unrealLogDirectory) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_UNREAL_LOG_DIR) ??
        normalizeOptionalText(process.env.SCALEWORLD_UNREAL_LOG_DIR);
    if (explicitDirectory) {
        directories.push(
            path.isAbsolute(explicitDirectory) ? explicitDirectory : path.resolve(repoRoot, explicitDirectory)
        );
    }

    const installRoot =
        normalizeOptionalText(process.env.SCALEWORLD_INSTALL_ROOT) ?? 'C:\\PixelStreaming\\WindowsNoEditor';
    directories.push(path.join(installRoot, 'Saved', 'Logs'));
    directories.push(path.join(installRoot, 'ScaleWorld', 'Saved', 'Logs'));
    directories.push(path.join(installRoot, 'Windows', 'ScaleWorld', 'Saved', 'Logs'));

    const localAppData = normalizeOptionalText(process.env.LOCALAPPDATA);
    if (localAppData) {
        directories.push(path.join(localAppData, 'ScaleWorld', 'Saved', 'Logs'));
    }

    return Array.from(new Set(directories.map((item) => path.normalize(item))));
}

function discoverLogCandidates(
    options: SessionLogArtifactManagerOptions,
    repoRoot: string,
    logFolder: string,
    desiredStatePath: string | undefined
): LogCandidate[] {
    const candidates: LogCandidate[] = [];

    if (
        parseBoolean(
            options.includeWilburLogs ?? process.env.INSTANCE_AGENT_ARTIFACT_INCLUDE_WILBUR_LOGS,
            true
        )
    ) {
        candidates.push(...listLatestFiles(logFolder, 'wilbur_log', 5));
    }

    if (
        parseBoolean(
            options.includeWatchdogLogs ?? process.env.INSTANCE_AGENT_ARTIFACT_INCLUDE_WATCHDOG_LOGS,
            true
        )
    ) {
        const watchdogLogPath =
            resolvePathMaybeRelative(options.watchdogLogPath, repoRoot) ??
            resolvePathMaybeRelative(process.env.WATCHDOG_LOG_PATH, repoRoot) ??
            path.join(repoRoot, 'logs', 'scaleworld-watchdog.log');
        addExistingCandidate(candidates, 'watchdog_log', watchdogLogPath, true);
    }

    if (
        parseBoolean(
            options.includeStackRecycleLog ?? process.env.INSTANCE_AGENT_ARTIFACT_INCLUDE_STACK_RECYCLE_LOG,
            true
        )
    ) {
        addExistingCandidate(
            candidates,
            'stack_recycle_log',
            path.join(repoRoot, 'state', 'stack-recycle.log'),
            true
        );
        addExistingCandidate(
            candidates,
            'stack_recycle_launch_log',
            path.join(repoRoot, 'state', 'stack-recycle-launch.log'),
            true
        );
    }

    if (
        parseBoolean(
            options.includeRuntimeStatusSnapshot ??
                process.env.INSTANCE_AGENT_ARTIFACT_INCLUDE_RUNTIME_STATUS_SNAPSHOT,
            true
        )
    ) {
        addExistingCandidate(
            candidates,
            'runtime_status_snapshot',
            path.join(repoRoot, 'state', 'streamer-health.json'),
            true
        );
        addExistingCandidate(candidates, 'desired_state_snapshot', desiredStatePath, true);
    }

    if (
        parseBoolean(
            options.includeUnrealLogs ?? process.env.INSTANCE_AGENT_ARTIFACT_INCLUDE_UNREAL_LOGS,
            true
        )
    ) {
        for (const directory of discoverUnrealLogDirectories(options, repoRoot)) {
            candidates.push(...listLatestFiles(directory, 'unreal_log', 3));
        }
    }

    const deduped = new Map<string, LogCandidate>();
    for (const candidate of candidates) {
        const key = path.normalize(candidate.path).toLowerCase();
        if (!deduped.has(key)) {
            deduped.set(key, candidate);
        }
    }

    return Array.from(deduped.values());
}

function readTailUtf8(
    filePath: string,
    maxBytes: number
): { content: string; tailBytes: number; truncatedStart: boolean } {
    const stat = fs.statSync(filePath);
    const tailBytes = Math.min(Math.max(0, maxBytes), stat.size);
    const buffer = Buffer.alloc(tailBytes);
    const fd = fs.openSync(filePath, 'r');
    try {
        fs.readSync(fd, buffer, 0, tailBytes, Math.max(0, stat.size - tailBytes));
    } finally {
        fs.closeSync(fd);
    }

    return {
        content: buffer.toString('utf8').replace(/^\uFEFF/, ''),
        tailBytes,
        truncatedStart: stat.size > tailBytes
    };
}

function collectBundleEntries(candidates: LogCandidate[], maxBundleBytes: number): BundleEntry[] {
    const entries: BundleEntry[] = [];
    let remainingBytes = maxBundleBytes;
    const maxEntryBytes = Math.min(DEFAULT_MAX_ENTRY_BYTES, maxBundleBytes);

    for (const candidate of candidates) {
        if (remainingBytes <= 0 && !candidate.required) {
            continue;
        }

        try {
            const stat = fs.statSync(candidate.path);
            if (!stat.isFile()) {
                entries.push({
                    kind: candidate.kind,
                    path: candidate.path,
                    exists: false,
                    error: 'not_a_file'
                });
                continue;
            }

            const bytesForEntry = Math.max(0, Math.min(maxEntryBytes, remainingBytes));
            const tail = bytesForEntry > 0 ? readTailUtf8(candidate.path, bytesForEntry) : undefined;
            if (tail) {
                remainingBytes -= tail.tailBytes;
            }

            entries.push({
                kind: candidate.kind,
                path: candidate.path,
                exists: true,
                sizeBytes: stat.size,
                modifiedAtUtc: stat.mtime.toISOString(),
                tailBytes: tail?.tailBytes ?? 0,
                truncatedStart: tail?.truncatedStart ?? stat.size > 0,
                content: tail?.content ?? ''
            });
        } catch (error) {
            entries.push({
                kind: candidate.kind,
                path: candidate.path,
                exists: false,
                error: error instanceof Error ? error.message : String(error)
            });
        }
    }

    return entries;
}

function writeJsonAtomic(filePath: string, value: unknown): void {
    const directory = path.dirname(filePath);
    fs.mkdirSync(directory, { recursive: true });
    const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tempPath, JSON.stringify(value, null, 2), 'utf8');
    fs.renameSync(tempPath, filePath);
}

function readQueueRecord(filePath: string): ArtifactQueueRecord | null {
    try {
        return JSON.parse(fs.readFileSync(filePath, 'utf8')) as ArtifactQueueRecord;
    } catch {
        return null;
    }
}

function buildObjectKey(
    prefix: string,
    context: SessionLogArtifactCaptureContext,
    createdAtUtc: string,
    artifactId: string
): string {
    const created = new Date(createdAtUtc);
    const year = created.getUTCFullYear().toString().padStart(4, '0');
    const month = (created.getUTCMonth() + 1).toString().padStart(2, '0');
    const day = created.getUTCDate().toString().padStart(2, '0');
    const timestamp = createdAtUtc.replace(/[:.]/g, '-');
    const sessionSegment = sanitizeKeySegment(
        context.sessionRequestId ?? context.userSessionId ?? context.sessionId,
        'unmatched-session'
    );
    const trigger = sanitizeKeySegment(context.trigger, 'capture');
    const instance = sanitizeKeySegment(context.instanceId, 'unknown-instance');
    return `${prefix}/${year}/${month}/${day}/${instance}/${sessionSegment}/${timestamp}-${trigger}-${artifactId}.diagnostic-bundle.json.gz`;
}

function buildRegisterMetadata(
    context: SessionLogArtifactCaptureContext,
    includedEntryCount: number,
    missingEntryCount: number
): Record<string, string> {
    return normalizeMetadata({
        trigger: context.trigger,
        instanceCommandId: context.instanceCommandId,
        commandType: context.commandType,
        runtimeStatus: context.runtimeStatus,
        runtimeReason: context.runtimeReason,
        runtimeVersion: context.runtimeVersion,
        recycleId: context.recycleId,
        recycleReason: context.recycleReason,
        recycleRequestedAtUtc: context.recycleRequestedAtUtc,
        includedEntryCount,
        missingEntryCount,
        ...context.metadata
    });
}

function appendRegion(args: string[], region: string | undefined): string[] {
    const normalizedRegion = normalizeOptionalText(region);
    return normalizedRegion ? [...args, '--region', normalizedRegion] : args;
}

async function headObject(
    awsCliPath: string,
    region: string | undefined,
    bucketName: string,
    objectKey: string
): Promise<{ eTag?: string; objectVersionId?: string; sizeBytes?: number }> {
    const args = appendRegion(
        ['s3api', 'head-object', '--bucket', bucketName, '--key', objectKey, '--output', 'json'],
        region
    );
    const { stdout } = await execFileAsync(awsCliPath, args, { windowsHide: true });
    const parsed = JSON.parse(stdout || '{}') as {
        ETag?: unknown;
        VersionId?: unknown;
        ContentLength?: unknown;
    };

    const sizeBytes = typeof parsed.ContentLength === 'number' ? parsed.ContentLength : undefined;
    return {
        eTag: normalizeOptionalText(parsed.ETag)?.replace(/^"|"$/g, ''),
        objectVersionId: normalizeOptionalText(parsed.VersionId),
        sizeBytes
    };
}

export function createSessionLogArtifactManager(
    options: SessionLogArtifactManagerOptions
): SessionLogArtifactManager | null {
    const log = options.logger ?? (() => undefined);
    const enabled = parseBoolean(
        options.enabled ?? process.env.INSTANCE_AGENT_ARTIFACT_UPLOAD_ENABLED,
        false
    );
    if (!enabled) {
        log('[session-artifacts] Disabled.');
        return null;
    }

    const bucketName =
        normalizeOptionalText(options.bucketName) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_BUCKET);
    if (!bucketName) {
        log('[session-artifacts] Disabled because no artifact bucket was configured.');
        return null;
    }

    const repoRoot = resolveRepoRoot();
    const objectPrefix = normalizeObjectPrefix(
        options.objectPrefix ?? process.env.INSTANCE_AGENT_ARTIFACT_PREFIX
    );
    const awsCliPath =
        normalizeOptionalText(options.awsCliPath) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_AWS_CLI_PATH) ??
        'aws';
    const awsRegion =
        normalizeOptionalText(options.awsRegion) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_AWS_REGION);
    const queuePath =
        resolvePathMaybeRelative(options.queuePath, repoRoot) ??
        resolvePathMaybeRelative(process.env.INSTANCE_AGENT_ARTIFACT_QUEUE_PATH, repoRoot) ??
        path.join(repoRoot, 'state', 'session-artifact-queue');
    const bundlePath = path.join(queuePath, 'bundles');
    const maxBundleBytes = parsePositiveInteger(
        options.maxBytes ?? process.env.INSTANCE_AGENT_ARTIFACT_MAX_BYTES,
        DEFAULT_MAX_BUNDLE_BYTES
    );
    const logFolder =
        resolvePathMaybeRelative(options.logFolder, repoRoot) ??
        resolvePathMaybeRelative(process.env.INSTANCE_AGENT_ARTIFACT_WILBUR_LOG_FOLDER, repoRoot) ??
        path.join(repoRoot, 'logs');
    const desiredStatePath = resolvePathMaybeRelative(options.desiredStatePath, repoRoot);
    let drainPromise: Promise<void> | null = null;

    fs.mkdirSync(queuePath, { recursive: true });
    fs.mkdirSync(bundlePath, { recursive: true });
    log(
        `[session-artifacts] Enabled. bucket=${bucketName}, prefix=${objectPrefix}, queue=${queuePath}, maxBundleBytes=${maxBundleBytes}.`
    );

    const updateRecord = (record: ArtifactQueueRecord): void => {
        record.updatedAtUtc = new Date().toISOString();
        writeJsonAtomic(path.join(queuePath, `${record.id}.json`), record);
    };

    const uploadRecord = async (record: ArtifactQueueRecord): Promise<void> => {
        const destination = `s3://${record.bucketName}/${record.objectKey}`;
        const args = appendRegion(
            [
                's3',
                'cp',
                record.localPath,
                destination,
                '--only-show-errors',
                '--content-type',
                'application/gzip'
            ],
            awsRegion ?? record.request.region
        );
        const { stderr } = await execFileAsync(awsCliPath, args, { windowsHide: true });
        if (stderr && stderr.trim().length > 0) {
            log(`[session-artifacts] AWS CLI upload stderr: ${truncateText(stderr.trim(), 500)}`);
        }

        record.status = 'pending_registration';
        record.request.uploadedAtUtc = new Date().toISOString();
        try {
            const head = await headObject(
                awsCliPath,
                awsRegion ?? record.request.region,
                record.bucketName,
                record.objectKey
            );
            record.request.eTag = head.eTag ?? record.request.eTag;
            record.request.objectVersionId = head.objectVersionId ?? record.request.objectVersionId;
            record.request.sizeBytes = head.sizeBytes ?? record.request.sizeBytes;
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[session-artifacts] HeadObject failed for ${record.objectKey}: ${truncateText(message, 500)}`
            );
        }

        updateRecord(record);
        log(`[session-artifacts] Uploaded ${record.localPath} to ${destination}.`);
    };

    const registerRecord = async (record: ArtifactQueueRecord): Promise<void> => {
        await options.registerArtifact(record.request);
        try {
            fs.unlinkSync(path.join(queuePath, `${record.id}.json`));
        } catch {
            // best effort
        }

        try {
            if (fs.existsSync(record.localPath)) {
                fs.unlinkSync(record.localPath);
            }
        } catch {
            // best effort
        }

        log(`[session-artifacts] Registered artifact ${record.objectKey}.`);
    };

    const drainQueueCore = async (): Promise<void> => {
        let files: string[];
        try {
            files = fs
                .readdirSync(queuePath)
                .filter((fileName) => fileName.endsWith('.json'))
                .map((fileName) => path.join(queuePath, fileName))
                .sort();
        } catch {
            return;
        }

        let processed = 0;
        for (const filePath of files) {
            if (processed >= MAX_DRAIN_RECORDS) {
                break;
            }

            const record = readQueueRecord(filePath);
            if (!record) {
                continue;
            }

            try {
                if (record.status === 'pending_upload') {
                    await uploadRecord(record);
                }

                if (record.status === 'pending_registration') {
                    await registerRecord(record);
                }
                processed += 1;
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                record.attempts += 1;
                record.lastError = truncateText(message, 1000);
                updateRecord(record);
                log(
                    `[session-artifacts] Queue record ${record.id} failed (attempt=${record.attempts}): ${truncateText(message, 500)}`
                );
            }
        }
    };

    const drainQueue = async (): Promise<void> => {
        if (drainPromise) {
            return drainPromise;
        }

        drainPromise = drainQueueCore().finally(() => {
            drainPromise = null;
        });
        return drainPromise;
    };

    const captureAndUpload = async (context: SessionLogArtifactCaptureContext): Promise<void> => {
        const artifactId = randomUUID();
        const createdAtUtc = new Date().toISOString();
        const candidates = discoverLogCandidates(options, repoRoot, logFolder, desiredStatePath);
        const entries = collectBundleEntries(candidates, maxBundleBytes);
        const includedEntryCount = entries.filter(
            (entry) => entry.exists && (entry.tailBytes ?? 0) > 0
        ).length;
        const missingEntryCount = entries.filter((entry) => !entry.exists).length;
        const bundle = {
            schemaVersion: 1,
            artifactType: 'diagnostic_bundle',
            createdAtUtc,
            source: 'pixelstreaming-instance-agent',
            context: {
                trigger: context.trigger,
                instanceId: context.instanceId,
                region: context.region,
                sessionRequestId: context.sessionRequestId,
                userSessionId: context.userSessionId,
                sessionId: context.sessionId,
                instanceCommandId: context.instanceCommandId,
                commandType: context.commandType,
                runtimeStatus: context.runtimeStatus,
                runtimeReason: context.runtimeReason,
                runtimeVersion: context.runtimeVersion,
                recycleId: context.recycleId,
                recycleReason: context.recycleReason,
                recycleRequestedAtUtc: context.recycleRequestedAtUtc
            },
            summary: {
                candidateCount: candidates.length,
                includedEntryCount,
                missingEntryCount,
                maxBundleBytes
            },
            entries
        };
        const compressed = await gzipAsync(Buffer.from(JSON.stringify(bundle, null, 2), 'utf8'));
        const checksumSha256 = createHash('sha256').update(compressed).digest('hex');
        const localPath = path.join(bundlePath, `${artifactId}.diagnostic-bundle.json.gz`);
        fs.writeFileSync(localPath, compressed);

        const objectKey = buildObjectKey(objectPrefix, context, createdAtUtc, artifactId);
        const request: SessionLogArtifactRegistrationRequest = {
            instanceId: context.instanceId,
            region: context.region,
            sessionRequestId: normalizeGuidText(context.sessionRequestId),
            userSessionId: normalizeGuidText(context.userSessionId),
            sessionId: normalizeOptionalText(context.sessionId),
            artifactType: 'diagnostic_bundle',
            bucketName,
            objectKey,
            sizeBytes: compressed.length,
            checksumSha256,
            timeRangeStartUtc: normalizeOptionalText(
                context.timeRangeStartUtc ?? context.recycleRequestedAtUtc
            ),
            timeRangeEndUtc: normalizeOptionalText(context.timeRangeEndUtc ?? createdAtUtc),
            metadata: buildRegisterMetadata(context, includedEntryCount, missingEntryCount)
        };
        const record: ArtifactQueueRecord = {
            id: artifactId,
            status: 'pending_upload',
            createdAtUtc,
            updatedAtUtc: createdAtUtc,
            attempts: 0,
            localPath,
            bucketName,
            objectKey,
            request
        };

        updateRecord(record);
        log(
            `[session-artifacts] Captured diagnostic bundle ${localPath} (${compressed.length} bytes, entries=${includedEntryCount}, missing=${missingEntryCount}).`
        );
        await drainQueue();
    };

    return {
        captureAndUpload,
        drainQueue
    };
}
