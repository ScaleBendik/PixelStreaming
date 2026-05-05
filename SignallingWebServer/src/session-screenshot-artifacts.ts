// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile } from 'child_process';
import { createHash, randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

const DEFAULT_OBJECT_PREFIX = 'PixelStreamingScreenshots/nonprod';
const DEFAULT_MAX_FILE_COUNT = 200;
const DEFAULT_MAX_BUNDLE_BYTES = 100 * 1024 * 1024;
const DEFAULT_RETENTION_DAYS = 7;
const DEFAULT_SETTLE_DELAY_MS = 2_000;
const MAX_DRAIN_RECORDS = 3;
const MAX_DISCOVERED_SCREENSHOTS = 10_000;
const SCREENSHOT_START_SKEW_MS = 5_000;

type QueueRecordStatus = 'pending_upload' | 'pending_registration';

interface SourceFileSnapshot {
    path: string;
    sizeBytes: number;
    modifiedMs: number;
    modifiedAtUtc: string;
}

interface SelectedScreenshot extends SourceFileSnapshot {
    relativePath: string;
    archivePath: string;
    checksumSha256: string;
}

interface SourceFileCleanupEntry extends SourceFileSnapshot {
    checksumSha256: string;
}

interface ActiveScreenshotSession {
    startedAtUtc: string;
    baselineCapturedAtUtc: string;
    baseline: Map<string, SourceFileSnapshot>;
    baselineFileCount: number;
    baselineTruncated: boolean;
    context: Partial<SessionScreenshotArtifactCaptureContext>;
}

interface ActiveScreenshotSessionSnapshot {
    startedAtUtc: string;
    baselineCapturedAtUtc: string;
    baseline: SourceFileSnapshot[];
    baselineFileCount: number;
    baselineTruncated: boolean;
    context: Partial<SessionScreenshotArtifactCaptureContext>;
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
    sourceFiles?: SourceFileCleanupEntry[];
    request: SessionScreenshotArtifactRegistrationRequest;
}

export interface SessionScreenshotArtifactRuntimeOptions {
    enabled?: unknown;
    bucketName?: string;
    objectPrefix?: string;
    sourceFolder?: string;
    awsCliPath?: string;
    awsRegion?: string;
    queuePath?: string;
    maxFiles?: unknown;
    maxBytes?: unknown;
    retentionDays?: unknown;
    settleDelayMs?: unknown;
    lane?: string;
    runtimeVersion?: string;
    powershellPath?: string;
}

export interface SessionScreenshotArtifactRegistrationRequest {
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

export interface SessionScreenshotArtifactCaptureContext {
    trigger: string;
    instanceId: string;
    region: string;
    sessionRequestId?: string;
    userSessionId?: string;
    sessionId?: string;
    runtimeStatus?: string;
    runtimeReason?: string;
    runtimeVersion?: string;
    lane?: string;
    timeRangeStartUtc?: string;
    timeRangeEndUtc?: string;
    metadata?: Record<string, unknown>;
}

export interface SessionScreenshotArtifactManagerOptions extends SessionScreenshotArtifactRuntimeOptions {
    registerArtifact: (request: SessionScreenshotArtifactRegistrationRequest) => Promise<void>;
    logger?: (message: string) => void;
}

export type SessionScreenshotArtifactCompletionStatus =
    | 'captured'
    | 'no_screenshots'
    | 'skipped_no_session_request';

export interface SessionScreenshotArtifactCompletionResult {
    status: SessionScreenshotArtifactCompletionStatus;
    sessionRequestId?: string;
    artifactId?: string;
    objectKey?: string;
    screenshotCount: number;
    changedFileCount?: number;
    discoveredFileCount?: number;
    sourceFolder: string;
    trigger?: string;
    timeRangeStartUtc?: string;
    timeRangeEndUtc?: string;
}

export interface SessionScreenshotArtifactManager {
    startSession(context: Partial<SessionScreenshotArtifactCaptureContext>): void;
    attachSessionContext(context: Partial<SessionScreenshotArtifactCaptureContext>): void;
    completeSessionAndUpload(
        context: SessionScreenshotArtifactCaptureContext
    ): Promise<SessionScreenshotArtifactCompletionResult>;
    drainQueue(): Promise<void>;
    cleanStartupScreenshots(options?: { preserveActiveSession?: boolean }): void;
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
    if (typeof value !== 'string') return undefined;
    const normalized = value.trim();
    return normalized.length > 0 ? normalized : undefined;
}

function normalizeGuidText(value: unknown): string | undefined {
    const normalized = normalizeOptionalText(value);
    if (!normalized) return undefined;
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(normalized)
        ? normalized
        : undefined;
}

function truncateText(value: string, maxLength: number): string {
    return value.length <= maxLength ? value : `${value.slice(0, Math.max(0, maxLength - 3))}...`;
}
function normalizeMetadata(input: Record<string, unknown> | undefined): Record<string, string> {
    const metadata: Record<string, string> = {};
    for (const [key, value] of Object.entries(input ?? {})) {
        const normalizedKey = normalizeOptionalText(key);
        if (!normalizedKey || value === undefined || value === null) continue;
        if (typeof value === 'string') {
            const normalizedValue = normalizeOptionalText(value);
            if (normalizedValue) metadata[normalizedKey] = truncateText(normalizedValue, 512);
        } else if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
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

function sanitizeArchiveSegment(value: string, fallback: string): string {
    const normalized = normalizeOptionalText(value)?.replace(/[\\/]+/g, '-') ?? fallback;
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
    if (!normalized) return undefined;
    return path.isAbsolute(normalized) ? normalized : path.resolve(root, normalized);
}

function resolveDefaultScreenshotSourceFolder(repoRoot: string): string {
    const localAppData = normalizeOptionalText(process.env.LOCALAPPDATA);
    return localAppData
        ? path.join(localAppData, 'ScaleWorld', 'Saved', 'Screenshots', 'Windows')
        : path.join(repoRoot, 'screenshots');
}

function normalizePathKey(filePath: string): string {
    return path.resolve(filePath).toLowerCase();
}

function isSupportedScreenshotFile(filePath: string): boolean {
    return /\.(png|jpe?g|bmp|exr)$/i.test(filePath);
}

function listScreenshotFiles(
    directory: string,
    limit: number
): { files: SourceFileSnapshot[]; truncated: boolean } {
    const files: SourceFileSnapshot[] = [];
    const directories = [directory];
    let truncated = false;
    while (directories.length > 0) {
        const currentDirectory = directories.pop();
        if (!currentDirectory) continue;
        let entries: fs.Dirent[];
        try {
            entries = fs.readdirSync(currentDirectory, { withFileTypes: true });
        } catch {
            continue;
        }
        for (const entry of entries) {
            const entryPath = path.join(currentDirectory, entry.name);
            if (entry.isDirectory()) {
                directories.push(entryPath);
                continue;
            }
            if (!entry.isFile() || !isSupportedScreenshotFile(entryPath)) continue;
            if (files.length >= limit) {
                truncated = true;
                continue;
            }
            try {
                const stat = fs.statSync(entryPath);
                if (!stat.isFile()) continue;
                files.push({
                    path: entryPath,
                    sizeBytes: stat.size,
                    modifiedMs: stat.mtimeMs,
                    modifiedAtUtc: stat.mtime.toISOString()
                });
            } catch {
                // Ignore files that are removed while scanning.
            }
        }
    }
    return {
        files: files.sort((left, right) =>
            left.modifiedMs === right.modifiedMs
                ? left.path.localeCompare(right.path)
                : left.modifiedMs - right.modifiedMs
        ),
        truncated
    };
}

function snapshotBaseline(sourceFolder: string): ActiveScreenshotSession['baseline'] {
    const baseline = new Map<string, SourceFileSnapshot>();
    for (const file of listScreenshotFiles(sourceFolder, MAX_DISCOVERED_SCREENSHOTS).files) {
        baseline.set(normalizePathKey(file.path), file);
    }
    return baseline;
}

function hasChangedSinceBaseline(file: SourceFileSnapshot, session: ActiveScreenshotSession): boolean {
    const startedMs = Date.parse(session.startedAtUtc);
    const lowerBoundMs = Number.isFinite(startedMs) ? startedMs - SCREENSHOT_START_SKEW_MS : 0;
    const baseline = session.baseline.get(normalizePathKey(file.path));
    if (!baseline) return file.modifiedMs >= lowerBoundMs;
    return (
        file.modifiedMs > baseline.modifiedMs + 1 ||
        (file.sizeBytes !== baseline.sizeBytes && file.modifiedMs >= lowerBoundMs)
    );
}
function allocateArchivePath(
    sourceFolder: string,
    filePath: string,
    used: Set<string>
): { relativePath: string; archivePath: string } {
    const relative = path.relative(sourceFolder, filePath);
    const normalizedRelative =
        !relative || relative.startsWith('..') || path.isAbsolute(relative)
            ? path.basename(filePath)
            : relative;
    const parsed = path.parse(normalizedRelative);
    const directorySegments = parsed.dir
        .split(/[\\/]+/g)
        .map((segment) => sanitizeArchiveSegment(segment, 'folder'))
        .filter((segment) => segment.length > 0);
    const baseName = sanitizeArchiveSegment(parsed.name, 'screenshot');
    const extension = sanitizeArchiveSegment(parsed.ext || '.png', '.png');
    const relativePath = [...directorySegments, `${baseName}${extension}`].join('/');
    let archivePath = `screenshots/${relativePath}`;
    let attempt = 2;
    while (used.has(archivePath.toLowerCase())) {
        archivePath = `screenshots/${[...directorySegments, `${baseName}-${attempt}${extension}`].join('/')}`;
        attempt += 1;
    }
    used.add(archivePath.toLowerCase());
    return { relativePath, archivePath };
}

function writeJsonAtomic(filePath: string, value: unknown): void {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
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

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

function removeDirectoryBestEffort(directory: string): void {
    try {
        if (fs.existsSync(directory)) fs.rmSync(directory, { recursive: true, force: true });
    } catch {
        // best effort
    }
}

function writeActiveSessionSnapshot(filePath: string, session: ActiveScreenshotSession): void {
    const snapshot: ActiveScreenshotSessionSnapshot = {
        startedAtUtc: session.startedAtUtc,
        baselineCapturedAtUtc: session.baselineCapturedAtUtc,
        baseline: [...session.baseline.values()],
        baselineFileCount: session.baselineFileCount,
        baselineTruncated: session.baselineTruncated,
        context: session.context
    };
    writeJsonAtomic(filePath, snapshot);
}

function readActiveSessionSnapshot(filePath: string): ActiveScreenshotSession | null {
    try {
        const snapshot = JSON.parse(fs.readFileSync(filePath, 'utf8')) as ActiveScreenshotSessionSnapshot;
        if (
            !snapshot ||
            typeof snapshot.startedAtUtc !== 'string' ||
            typeof snapshot.baselineCapturedAtUtc !== 'string' ||
            !Array.isArray(snapshot.baseline)
        ) {
            return null;
        }

        const baseline = new Map<string, SourceFileSnapshot>();
        for (const file of snapshot.baseline) {
            if (!file || typeof file.path !== 'string') continue;
            baseline.set(normalizePathKey(file.path), file);
        }

        return {
            startedAtUtc: snapshot.startedAtUtc,
            baselineCapturedAtUtc: snapshot.baselineCapturedAtUtc,
            baseline,
            baselineFileCount:
                typeof snapshot.baselineFileCount === 'number' ? snapshot.baselineFileCount : baseline.size,
            baselineTruncated: snapshot.baselineTruncated === true,
            context: snapshot.context ?? {}
        };
    } catch {
        return null;
    }
}

function clearActiveSessionSnapshot(filePath: string): void {
    try {
        if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
    } catch {
        // best effort
    }
}

function buildObjectKey(
    prefix: string,
    lane: string | undefined,
    context: SessionScreenshotArtifactCaptureContext,
    createdAtUtc: string,
    artifactId: string
): string {
    const created = new Date(createdAtUtc);
    const year = created.getUTCFullYear().toString().padStart(4, '0');
    const month = (created.getUTCMonth() + 1).toString().padStart(2, '0');
    const day = created.getUTCDate().toString().padStart(2, '0');
    const sessionSegment = sanitizeKeySegment(
        context.sessionRequestId ?? context.userSessionId ?? context.sessionId,
        'unmatched-session'
    );
    const laneSegment = sanitizeKeySegment(lane, 'unknown-lane');
    const prefixSegments = prefix.split('/').filter((segment) => segment.length > 0);
    const appendLane =
        prefixSegments.length === 0 ||
        prefixSegments[prefixSegments.length - 1].toLowerCase() !== laneSegment.toLowerCase();
    return `${(appendLane ? [...prefixSegments, laneSegment] : prefixSegments).join('/')}/${year}/${month}/${day}/${sessionSegment}/${artifactId}/screenshots.zip`;
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
    return {
        eTag: normalizeOptionalText(parsed.ETag)?.replace(/^"|"$/g, ''),
        objectVersionId: normalizeOptionalText(parsed.VersionId),
        sizeBytes: typeof parsed.ContentLength === 'number' ? parsed.ContentLength : undefined
    };
}

async function createZipFromStaging(
    powershellPath: string,
    stagingPath: string,
    zipPath: string
): Promise<void> {
    const command = [
        "$ErrorActionPreference = 'Stop'",
        'if (Test-Path -LiteralPath $env:SCALEWORLD_SCREENSHOT_ZIP_PATH) { Remove-Item -LiteralPath $env:SCALEWORLD_SCREENSHOT_ZIP_PATH -Force }',
        "Compress-Archive -Path (Join-Path $env:SCALEWORLD_SCREENSHOT_STAGE_PATH '*') -DestinationPath $env:SCALEWORLD_SCREENSHOT_ZIP_PATH -Force"
    ].join('; ');
    await execFileAsync(powershellPath, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], {
        windowsHide: true,
        env: {
            ...process.env,
            SCALEWORLD_SCREENSHOT_STAGE_PATH: stagingPath,
            SCALEWORLD_SCREENSHOT_ZIP_PATH: zipPath
        }
    });
}
export function createSessionScreenshotArtifactManager(
    options: SessionScreenshotArtifactManagerOptions
): SessionScreenshotArtifactManager | null {
    const log = options.logger ?? (() => undefined);
    const enabled = parseBoolean(
        options.enabled ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_UPLOAD_ENABLED,
        false
    );
    if (!enabled) {
        log('[screenshot-artifacts] Disabled.');
        return null;
    }

    const bucketName =
        normalizeOptionalText(options.bucketName) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_BUCKET) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_BUCKET);
    if (!bucketName) {
        log('[screenshot-artifacts] Disabled because no screenshot artifact bucket was configured.');
        return null;
    }

    const repoRoot = resolveRepoRoot();
    const objectPrefix = normalizeObjectPrefix(
        options.objectPrefix ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_PREFIX
    );
    const sourceFolder =
        resolvePathMaybeRelative(
            options.sourceFolder ??
                process.env.INSTANCE_AGENT_SCREENSHOT_SOURCE_FOLDER ??
                process.env.SCALEWORLD_SCREENSHOT_DIR,
            repoRoot
        ) ?? resolveDefaultScreenshotSourceFolder(repoRoot);
    const awsCliPath =
        normalizeOptionalText(options.awsCliPath) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_AWS_CLI_PATH) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_AWS_CLI_PATH) ??
        'aws';
    const awsRegion =
        normalizeOptionalText(options.awsRegion) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_AWS_REGION) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_ARTIFACT_AWS_REGION);
    const powershellPath =
        normalizeOptionalText(
            options.powershellPath ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_POWERSHELL_PATH
        ) ?? 'powershell';
    const queuePath =
        resolvePathMaybeRelative(options.queuePath, repoRoot) ??
        resolvePathMaybeRelative(process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_QUEUE_PATH, repoRoot) ??
        path.join(repoRoot, 'state', 'session-screenshot-artifact-queue');
    const bundlePath = path.join(queuePath, 'bundles');
    const stagingRootPath = path.join(queuePath, 'staging');
    const activeSessionStatePath = path.join(queuePath, 'active-session', 'session.json');
    const maxFiles = parsePositiveInteger(
        options.maxFiles ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_FILES,
        DEFAULT_MAX_FILE_COUNT
    );
    const maxBundleBytes = parsePositiveInteger(
        options.maxBytes ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_MAX_BYTES,
        DEFAULT_MAX_BUNDLE_BYTES
    );
    const retentionDays = parsePositiveInteger(
        options.retentionDays ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_RETENTION_DAYS,
        DEFAULT_RETENTION_DAYS
    );
    const settleDelayMs = parsePositiveInteger(
        options.settleDelayMs ?? process.env.INSTANCE_AGENT_SCREENSHOT_ARTIFACT_SETTLE_DELAY_MS,
        DEFAULT_SETTLE_DELAY_MS
    );
    const configuredLane =
        normalizeOptionalText(options.lane) ??
        normalizeOptionalText(process.env.INSTANCE_AGENT_LANE) ??
        normalizeOptionalText(process.env.SCALEWORLD_LANE);
    const configuredRuntimeVersion = normalizeOptionalText(options.runtimeVersion);
    let activeSession: ActiveScreenshotSession | null = null;
    let drainPromise: Promise<void> | null = null;

    fs.mkdirSync(queuePath, { recursive: true });
    fs.mkdirSync(bundlePath, { recursive: true });
    fs.mkdirSync(stagingRootPath, { recursive: true });
    fs.mkdirSync(path.dirname(activeSessionStatePath), { recursive: true });
    activeSession = readActiveSessionSnapshot(activeSessionStatePath);
    log(
        `[screenshot-artifacts] Enabled. bucket=${bucketName}, prefix=${objectPrefix}, source=${sourceFolder}, queue=${queuePath}, maxFiles=${maxFiles}, maxBundleBytes=${maxBundleBytes}.`
    );
    if (activeSession) {
        log(
            `[screenshot-artifacts] Recovered active screenshot baseline from ${activeSessionStatePath} (files=${activeSession.baselineFileCount}).`
        );
    }

    const updateRecord = (record: ArtifactQueueRecord): void => {
        record.updatedAtUtc = new Date().toISOString();
        writeJsonAtomic(path.join(queuePath, `${record.id}.json`), record);
    };

    const cleanScreenshotSourceFolder = (reason: string): void => {
        const discovered = listScreenshotFiles(sourceFolder, MAX_DISCOVERED_SCREENSHOTS);
        let removed = 0;
        let failed = 0;
        for (const file of discovered.files) {
            try {
                fs.unlinkSync(file.path);
                removed += 1;
            } catch {
                failed += 1;
            }
        }

        if (removed > 0 || failed > 0) {
            log(
                `[screenshot-artifacts] ${reason} screenshot cleanup removed ${removed} file(s) from ${sourceFolder}${failed > 0 ? ` (failed=${failed})` : ''}.`
            );
        }
    };

    const cleanupRegisteredSourceFiles = (record: ArtifactQueueRecord): void => {
        if (!Array.isArray(record.sourceFiles) || record.sourceFiles.length === 0) {
            return;
        }

        let removed = 0;
        let skipped = 0;
        let failed = 0;
        const recordCreatedMs = Date.parse(record.createdAtUtc);

        for (const sourceFile of record.sourceFiles) {
            try {
                if (!fs.existsSync(sourceFile.path)) {
                    skipped += 1;
                    continue;
                }

                const stat = fs.statSync(sourceFile.path);
                if (
                    !stat.isFile() ||
                    stat.size !== sourceFile.sizeBytes ||
                    (Number.isFinite(recordCreatedMs) && stat.mtimeMs > recordCreatedMs + 1_000)
                ) {
                    skipped += 1;
                    continue;
                }

                const checksumSha256 = createHash('sha256')
                    .update(fs.readFileSync(sourceFile.path))
                    .digest('hex');
                if (checksumSha256 !== sourceFile.checksumSha256) {
                    skipped += 1;
                    continue;
                }

                fs.unlinkSync(sourceFile.path);
                removed += 1;
            } catch {
                failed += 1;
            }
        }

        if (removed > 0 || skipped > 0 || failed > 0) {
            log(
                `[screenshot-artifacts] Registered artifact source cleanup removed ${removed} file(s) from ${sourceFolder}${skipped > 0 ? ` (skipped=${skipped})` : ''}${failed > 0 ? ` (failed=${failed})` : ''}.`
            );
        }
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
                'application/zip'
            ],
            awsRegion ?? record.request.region
        );
        const { stderr } = await execFileAsync(awsCliPath, args, { windowsHide: true });
        if (stderr && stderr.trim().length > 0)
            log(`[screenshot-artifacts] AWS CLI upload stderr: ${truncateText(stderr.trim(), 500)}`);
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
                `[screenshot-artifacts] HeadObject failed for ${record.objectKey}: ${truncateText(message, 500)}`
            );
        }
        updateRecord(record);
        log(`[screenshot-artifacts] Uploaded ${record.localPath} to ${destination}.`);
    };

    const registerRecord = async (record: ArtifactQueueRecord): Promise<void> => {
        await options.registerArtifact(record.request);
        try {
            fs.unlinkSync(path.join(queuePath, `${record.id}.json`));
        } catch {
            // best effort
        }
        try {
            if (fs.existsSync(record.localPath)) fs.unlinkSync(record.localPath);
        } catch {
            // best effort
        }
        cleanupRegisteredSourceFiles(record);
        const skippedByMaxFiles = Number.parseInt(record.request.metadata.skippedByMaxFiles ?? '0', 10);
        const skippedByMaxBytes = Number.parseInt(record.request.metadata.skippedByMaxBytes ?? '0', 10);
        const hasSkippedSourceFiles = skippedByMaxFiles > 0 || skippedByMaxBytes > 0;
        if (!activeSession && !hasSkippedSourceFiles) {
            cleanScreenshotSourceFolder('Post-registration');
        }
        log(`[screenshot-artifacts] Registered artifact ${record.objectKey}.`);
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
            if (processed >= MAX_DRAIN_RECORDS) break;
            const record = readQueueRecord(filePath);
            if (!record) continue;
            try {
                if (record.status === 'pending_upload') await uploadRecord(record);
                if (record.status === 'pending_registration') await registerRecord(record);
                processed += 1;
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                record.attempts += 1;
                record.lastError = truncateText(message, 1000);
                updateRecord(record);
                log(
                    `[screenshot-artifacts] Queue record ${record.id} failed (attempt=${record.attempts}): ${truncateText(message, 500)}`
                );
            }
        }
    };

    const drainQueue = async (): Promise<void> => {
        if (drainPromise) return drainPromise;
        drainPromise = drainQueueCore().finally(() => {
            drainPromise = null;
        });
        return drainPromise;
    };

    const mergeActiveContext = (context: Partial<SessionScreenshotArtifactCaptureContext>): void => {
        if (!activeSession) return;
        activeSession.context = {
            ...activeSession.context,
            ...context,
            metadata: { ...(activeSession.context.metadata ?? {}), ...(context.metadata ?? {}) }
        };
        writeActiveSessionSnapshot(activeSessionStatePath, activeSession);
    };

    const startSession = (context: Partial<SessionScreenshotArtifactCaptureContext>): void => {
        if (activeSession) {
            mergeActiveContext(context);
            return;
        }
        const startedAtUtc =
            normalizeOptionalText(context.timeRangeStartUtc) ??
            normalizeOptionalText(context.metadata?.sessionStartUtc) ??
            new Date().toISOString();
        const baselineCapturedAtUtc = new Date().toISOString();
        const baseline = snapshotBaseline(sourceFolder);
        activeSession = {
            startedAtUtc,
            baselineCapturedAtUtc,
            baseline,
            baselineFileCount: baseline.size,
            baselineTruncated: baseline.size >= MAX_DISCOVERED_SCREENSHOTS,
            context
        };
        writeActiveSessionSnapshot(activeSessionStatePath, activeSession);
        log(
            `[screenshot-artifacts] Session baseline captured at ${baselineCapturedAtUtc} (files=${baseline.size}${baseline.size >= MAX_DISCOVERED_SCREENSHOTS ? ', truncated=true' : ''}).`
        );
    };

    const attachSessionContext = (context: Partial<SessionScreenshotArtifactCaptureContext>): void => {
        if (!activeSession) {
            startSession(context);
            return;
        }
        mergeActiveContext(context);
    };

    const cleanStartupScreenshots = (startupOptions?: { preserveActiveSession?: boolean }): void => {
        const recoveredSession = activeSession ?? readActiveSessionSnapshot(activeSessionStatePath);
        if (startupOptions?.preserveActiveSession || recoveredSession) {
            log(
                '[screenshot-artifacts] Startup screenshot cleanup skipped because an active session may need recovery.'
            );
            return;
        }

        cleanScreenshotSourceFolder('Startup');
    };

    const completeSessionAndUpload = async (
        context: SessionScreenshotArtifactCaptureContext
    ): Promise<SessionScreenshotArtifactCompletionResult> => {
        const recoveredSession = activeSession ?? readActiveSessionSnapshot(activeSessionStatePath);
        const session: ActiveScreenshotSession = recoveredSession ?? {
            startedAtUtc:
                normalizeOptionalText(context.timeRangeStartUtc) ??
                normalizeOptionalText(context.metadata?.sessionStartUtc) ??
                new Date().toISOString(),
            baselineCapturedAtUtc: new Date().toISOString(),
            baseline: new Map<string, SourceFileSnapshot>(),
            baselineFileCount: 0,
            baselineTruncated: false,
            context: {}
        };
        activeSession = null;
        const mergedContext = {
            ...session.context,
            ...context,
            metadata: { ...(session.context.metadata ?? {}), ...(context.metadata ?? {}) }
        } as SessionScreenshotArtifactCaptureContext;
        const sessionRequestId = normalizeGuidText(mergedContext.sessionRequestId);

        await sleep(settleDelayMs);
        const artifactId = randomUUID();
        const createdAtUtc = new Date().toISOString();
        const expiresAtUtc = new Date(
            Date.parse(createdAtUtc) + retentionDays * 24 * 60 * 60 * 1000
        ).toISOString();
        const stagingPath = path.join(stagingRootPath, artifactId);
        const localPath = path.join(bundlePath, `${artifactId}.screenshots.zip`);
        const usedArchivePaths = new Set<string>();
        let stagingCreated = false;

        try {
            const lane = normalizeOptionalText(mergedContext.lane) ?? configuredLane;
            const runtimeVersion =
                normalizeOptionalText(mergedContext.runtimeVersion) ?? configuredRuntimeVersion;
            const timeRangeStartUtc =
                normalizeOptionalText(mergedContext.timeRangeStartUtc) ?? session.startedAtUtc;
            const timeRangeEndUtc = normalizeOptionalText(mergedContext.timeRangeEndUtc) ?? createdAtUtc;
            const discovered = listScreenshotFiles(sourceFolder, MAX_DISCOVERED_SCREENSHOTS);
            const changedFiles = discovered.files.filter((file) => hasChangedSinceBaseline(file, session));
            const selectedFiles: SourceFileSnapshot[] = [];
            let selectedSourceBytes = 0;
            let skippedByMaxBytes = 0;
            let skippedByMaxFiles = 0;
            for (const file of changedFiles) {
                if (selectedFiles.length >= maxFiles) {
                    skippedByMaxFiles += 1;
                    continue;
                }
                if (selectedSourceBytes + file.sizeBytes > maxBundleBytes) {
                    skippedByMaxBytes += 1;
                    continue;
                }
                selectedFiles.push(file);
                selectedSourceBytes += file.sizeBytes;
            }
            if (selectedFiles.length === 0) {
                clearActiveSessionSnapshot(activeSessionStatePath);
                if (changedFiles.length === 0) {
                    cleanScreenshotSourceFolder('Post-session empty');
                }
                log(
                    `[screenshot-artifacts] No screenshots found for ${
                        sessionRequestId
                            ? `session request ${sessionRequestId}`
                            : 'session without explicit request id'
                    } (${mergedContext.trigger}).`
                );
                return {
                    status: 'no_screenshots',
                    sessionRequestId,
                    screenshotCount: 0,
                    changedFileCount: changedFiles.length,
                    discoveredFileCount: discovered.files.length,
                    sourceFolder,
                    trigger: mergedContext.trigger,
                    timeRangeStartUtc,
                    timeRangeEndUtc
                };
            }
            fs.mkdirSync(stagingPath, { recursive: true });
            stagingCreated = true;
            const selectedScreenshots: SelectedScreenshot[] = [];
            for (const file of selectedFiles) {
                const archive = allocateArchivePath(sourceFolder, file.path, usedArchivePaths);
                const stagedPath = path.join(stagingPath, archive.archivePath);
                fs.mkdirSync(path.dirname(stagedPath), { recursive: true });
                fs.copyFileSync(file.path, stagedPath);
                const content = fs.readFileSync(stagedPath);
                selectedScreenshots.push({
                    ...file,
                    sizeBytes: content.length,
                    relativePath: archive.relativePath,
                    archivePath: archive.archivePath,
                    checksumSha256: createHash('sha256').update(content).digest('hex')
                });
            }

            const manifest = {
                schemaVersion: 1,
                artifactType: 'screenshot_bundle',
                bundleFormat: 'zip',
                createdAtUtc,
                expiresAtUtc,
                source: 'pixelstreaming-instance-agent',
                context: {
                    trigger: mergedContext.trigger,
                    instanceId: mergedContext.instanceId,
                    region: mergedContext.region,
                    sessionRequestId,
                    userSessionId: normalizeGuidText(mergedContext.userSessionId),
                    sessionId: normalizeOptionalText(mergedContext.sessionId),
                    runtimeStatus: normalizeOptionalText(mergedContext.runtimeStatus),
                    runtimeReason: normalizeOptionalText(mergedContext.runtimeReason),
                    runtimeVersion,
                    lane,
                    sessionStartUtc: session.startedAtUtc,
                    baselineCapturedAtUtc: session.baselineCapturedAtUtc,
                    timeRangeStartUtc,
                    timeRangeEndUtc
                },
                summary: {
                    sourceFolder,
                    discoveredFileCount: discovered.files.length,
                    discoveredTruncated: discovered.truncated,
                    changedFileCount: changedFiles.length,
                    screenshotCount: selectedScreenshots.length,
                    selectedSourceBytes,
                    skippedByMaxFiles,
                    skippedByMaxBytes,
                    maxFiles,
                    maxBundleBytes,
                    settleDelayMs,
                    baselineFileCount: session.baselineFileCount,
                    baselineTruncated: session.baselineTruncated,
                    retentionDays
                },
                screenshots: selectedScreenshots.map((file) => ({
                    archivePath: file.archivePath,
                    relativePath: file.relativePath,
                    sizeBytes: file.sizeBytes,
                    modifiedAtUtc: file.modifiedAtUtc,
                    checksumSha256: file.checksumSha256
                }))
            };
            writeJsonAtomic(path.join(stagingPath, 'manifest.json'), manifest);
            await createZipFromStaging(powershellPath, stagingPath, localPath);
            const archive = fs.readFileSync(localPath);
            const objectKey = buildObjectKey(objectPrefix, lane, mergedContext, createdAtUtc, artifactId);
            const request: SessionScreenshotArtifactRegistrationRequest = {
                instanceId: mergedContext.instanceId,
                region: mergedContext.region,
                sessionRequestId,
                userSessionId: normalizeGuidText(mergedContext.userSessionId),
                sessionId: normalizeOptionalText(mergedContext.sessionId),
                artifactType: 'screenshot_bundle',
                bucketName,
                objectKey,
                sizeBytes: archive.length,
                checksumSha256: createHash('sha256').update(archive).digest('hex'),
                timeRangeStartUtc,
                timeRangeEndUtc,
                metadata: normalizeMetadata({
                    trigger: mergedContext.trigger,
                    instanceId: mergedContext.instanceId,
                    lane,
                    runtimeStatus: mergedContext.runtimeStatus,
                    runtimeReason: mergedContext.runtimeReason,
                    runtimeVersion,
                    screenshotCount: selectedScreenshots.length,
                    sourceFolder,
                    expiresAtUtc,
                    retentionDays,
                    bundleFormat: 'zip',
                    manifestPath: 'manifest.json',
                    maxFiles,
                    maxBundleBytes,
                    skippedByMaxFiles,
                    skippedByMaxBytes,
                    baselineCapturedAtUtc: session.baselineCapturedAtUtc,
                    sessionStartUtc: session.startedAtUtc,
                    ...mergedContext.metadata
                })
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
                sourceFiles: selectedScreenshots.map((file) => ({
                    path: file.path,
                    sizeBytes: file.sizeBytes,
                    modifiedMs: file.modifiedMs,
                    modifiedAtUtc: file.modifiedAtUtc,
                    checksumSha256: file.checksumSha256
                })),
                request
            };
            updateRecord(record);
            clearActiveSessionSnapshot(activeSessionStatePath);
            log(
                `[screenshot-artifacts] Captured screenshot bundle ${localPath} (${archive.length} bytes, screenshots=${selectedScreenshots.length}, skippedByMaxFiles=${skippedByMaxFiles}, skippedByMaxBytes=${skippedByMaxBytes}).`
            );
            await drainQueue();
            return {
                status: 'captured',
                sessionRequestId,
                artifactId,
                objectKey,
                screenshotCount: selectedScreenshots.length,
                changedFileCount: changedFiles.length,
                discoveredFileCount: discovered.files.length,
                sourceFolder,
                trigger: mergedContext.trigger,
                timeRangeStartUtc,
                timeRangeEndUtc
            };
        } finally {
            if (stagingCreated) removeDirectoryBestEffort(stagingPath);
        }
    };
    return {
        startSession,
        attachSessionContext,
        completeSessionAndUpload,
        drainQueue,
        cleanStartupScreenshots
    };
}
