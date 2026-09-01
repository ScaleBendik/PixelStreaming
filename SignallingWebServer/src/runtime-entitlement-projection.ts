// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';

export const RUNTIME_ENTITLEMENT_PROJECTION_SCHEMA_VERSION = 1;

export interface RuntimeEntitlementManifestApiResponse {
    sessionRequestId: string;
    manifestId: string;
    manifestHash: string;
    schemaVersion: number;
    audience: string;
    groups: string[];
    entitlements: string[];
    requestedServiceClass: string;
    grantedServiceClass: string;
    minimumComputeCapability: string;
    placementPolicy: string;
    decidedAtUtc: string;
    policyVersion: string;
}

export interface RuntimeEntitlementProjectionReport {
    status: 'unassigned' | 'projected' | 'failed';
    sessionRequestId?: string;
    manifestId?: string;
    manifestHash?: string;
    projectedAtUtc?: string;
    errorCode?: string;
}

export interface RuntimeEntitlementProjectionFile {
    projectionSchemaVersion: number;
    state: 'unassigned' | 'projected' | 'failed';
    updatedAtUtc: string;
    manifest: RuntimeEntitlementManifestApiResponse | null;
    errorCode?: string;
}

const normalizeRequiredText = (value: unknown, fieldName: string): string => {
    if (typeof value !== 'string' || value.trim().length === 0) {
        throw new Error(`Runtime entitlement manifest field '${fieldName}' is required.`);
    }
    return value.trim();
};

const normalizeUuid = (value: unknown, fieldName: string): string => {
    const normalized = normalizeRequiredText(value, fieldName).toLowerCase();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(normalized)) {
        throw new Error(`Runtime entitlement manifest field '${fieldName}' is not a valid UUID.`);
    }
    return normalized;
};

const normalizeStringArray = (value: unknown, fieldName: string): string[] => {
    if (!Array.isArray(value)) {
        throw new Error(`Runtime entitlement manifest field '${fieldName}' must be an array.`);
    }
    return [
        ...new Set(
            value.map((item) => normalizeRequiredText(item, fieldName)).filter((item) => item.length > 0)
        )
    ].sort((left, right) => left.localeCompare(right));
};

const normalizeIsoTimestamp = (value: unknown, fieldName: string): string => {
    const normalized = normalizeRequiredText(value, fieldName);
    const parsed = Date.parse(normalized);
    if (!Number.isFinite(parsed)) {
        throw new Error(`Runtime entitlement manifest field '${fieldName}' is not a valid timestamp.`);
    }
    return new Date(parsed).toISOString();
};

export function normalizeRuntimeEntitlementManifest(
    value: RuntimeEntitlementManifestApiResponse
): RuntimeEntitlementManifestApiResponse {
    if (!value || typeof value !== 'object') {
        throw new Error('Runtime entitlement manifest response must be an object.');
    }
    const hash = normalizeRequiredText(value.manifestHash, 'manifestHash').toUpperCase();
    if (!/^[0-9A-F]{64}$/u.test(hash)) {
        throw new Error('Runtime entitlement manifest hash must be a SHA-256 hexadecimal value.');
    }
    if (!Number.isInteger(value.schemaVersion) || value.schemaVersion <= 0) {
        throw new Error('Runtime entitlement manifest schemaVersion must be a positive integer.');
    }

    return {
        sessionRequestId: normalizeUuid(value.sessionRequestId, 'sessionRequestId'),
        manifestId: normalizeUuid(value.manifestId, 'manifestId'),
        manifestHash: hash,
        schemaVersion: value.schemaVersion,
        audience: normalizeRequiredText(value.audience, 'audience').toLowerCase(),
        groups: normalizeStringArray(value.groups, 'groups'),
        entitlements: normalizeStringArray(value.entitlements, 'entitlements'),
        requestedServiceClass: normalizeRequiredText(
            value.requestedServiceClass,
            'requestedServiceClass'
        ).toLowerCase(),
        grantedServiceClass: normalizeRequiredText(
            value.grantedServiceClass,
            'grantedServiceClass'
        ).toLowerCase(),
        minimumComputeCapability: normalizeRequiredText(
            value.minimumComputeCapability,
            'minimumComputeCapability'
        ).toLowerCase(),
        placementPolicy: normalizeRequiredText(value.placementPolicy, 'placementPolicy'),
        decidedAtUtc: normalizeIsoTimestamp(value.decidedAtUtc, 'decidedAtUtc'),
        policyVersion: normalizeRequiredText(value.policyVersion, 'policyVersion')
    };
}

export function createUnassignedRuntimeEntitlementProjection(
    updatedAtUtc = new Date().toISOString()
): RuntimeEntitlementProjectionFile {
    return {
        projectionSchemaVersion: RUNTIME_ENTITLEMENT_PROJECTION_SCHEMA_VERSION,
        state: 'unassigned',
        updatedAtUtc: normalizeIsoTimestamp(updatedAtUtc, 'updatedAtUtc'),
        manifest: null
    };
}

export function createFailedRuntimeEntitlementProjection(
    errorCode: string,
    updatedAtUtc = new Date().toISOString()
): RuntimeEntitlementProjectionFile {
    const normalizedErrorCode = normalizeRequiredText(errorCode, 'errorCode')
        .replace(/[^a-zA-Z0-9_.-]/gu, '_')
        .slice(0, 128);
    return {
        projectionSchemaVersion: RUNTIME_ENTITLEMENT_PROJECTION_SCHEMA_VERSION,
        state: 'failed',
        updatedAtUtc: normalizeIsoTimestamp(updatedAtUtc, 'updatedAtUtc'),
        manifest: null,
        errorCode: normalizedErrorCode
    };
}

export function createProjectedRuntimeEntitlementProjection(
    manifest: RuntimeEntitlementManifestApiResponse,
    updatedAtUtc = new Date().toISOString()
): RuntimeEntitlementProjectionFile {
    return {
        projectionSchemaVersion: RUNTIME_ENTITLEMENT_PROJECTION_SCHEMA_VERSION,
        state: 'projected',
        updatedAtUtc: normalizeIsoTimestamp(updatedAtUtc, 'updatedAtUtc'),
        manifest: normalizeRuntimeEntitlementManifest(manifest)
    };
}

export function runtimeEntitlementProjectionReport(
    projection: RuntimeEntitlementProjectionFile
): RuntimeEntitlementProjectionReport {
    if (projection.state === 'projected' && projection.manifest) {
        return {
            status: 'projected',
            sessionRequestId: projection.manifest.sessionRequestId,
            manifestId: projection.manifest.manifestId,
            manifestHash: projection.manifest.manifestHash,
            projectedAtUtc: projection.updatedAtUtc
        };
    }
    if (projection.state === 'failed') {
        return {
            status: 'failed',
            errorCode: projection.errorCode ?? 'projection_failed'
        };
    }
    return { status: 'unassigned' };
}

export function hasSameRuntimeEntitlementProjection(
    left: RuntimeEntitlementProjectionFile,
    right: RuntimeEntitlementProjectionFile
): boolean {
    if (left.state !== right.state) return false;
    if (left.state === 'projected' && right.state === 'projected') {
        return (
            left.manifest?.sessionRequestId === right.manifest?.sessionRequestId &&
            left.manifest?.manifestId === right.manifest?.manifestId &&
            left.manifest?.manifestHash === right.manifest?.manifestHash
        );
    }
    return left.state !== 'failed' || left.errorCode === right.errorCode;
}

export function resolveRuntimeEntitlementManifestPath(configuredPath?: string): string {
    const normalized = configuredPath?.trim();
    if (normalized) return path.resolve(normalized);
    const programData =
        process.env.ProgramData?.trim() || process.env.PROGRAMDATA?.trim() || 'C:\\ProgramData';
    return path.join(programData, 'ScaleWorld', 'runtime-entitlement-manifest.json');
}

export function writeRuntimeEntitlementProjection(
    targetPath: string,
    projection: RuntimeEntitlementProjectionFile
): void {
    const resolvedPath = path.resolve(targetPath);
    const directory = path.dirname(resolvedPath);
    fs.mkdirSync(directory, { recursive: true });
    const temporaryPath = path.join(
        directory,
        `.${path.basename(resolvedPath)}.${process.pid}.${Date.now()}.tmp`
    );
    let fileDescriptor: number | null = null;
    try {
        fileDescriptor = fs.openSync(temporaryPath, 'wx', 0o600);
        fs.writeFileSync(fileDescriptor, `${JSON.stringify(projection, null, 2)}\n`, 'utf8');
        fs.fsyncSync(fileDescriptor);
        fs.closeSync(fileDescriptor);
        fileDescriptor = null;
        fs.renameSync(temporaryPath, resolvedPath);
    } catch (error) {
        if (fileDescriptor !== null) {
            fs.closeSync(fileDescriptor);
        }
        try {
            fs.unlinkSync(temporaryPath);
        } catch {
            // Best-effort cleanup only; the target was never replaced with a partial file.
        }
        throw error;
    }
}
