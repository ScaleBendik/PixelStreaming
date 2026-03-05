// Copyright Epic Games, Inc. All Rights Reserved.
import crypto from 'crypto';
import type http from 'http';
import type * as wslib from 'ws';
import { Logger } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

export type ConnectTicketAuthMode = 'off' | 'soft' | 'enforce';

export interface ConnectTicketAuthSettings {
    mode: ConnectTicketAuthMode;
    issuer: string;
    audience: string;
    signingKey: string;
    instanceId: string;
    routeHostSuffix: string;
    clockSkewSeconds: number;
}

type ValidationResult = {
    isValid: boolean;
    reason?: string;
};

const isDnsLabelChar = (charCode: number): boolean =>
    (charCode >= 97 && charCode <= 122) || (charCode >= 48 && charCode <= 57);

function normalizeHost(value: string): string {
    const trimmed = value.trim().toLowerCase().replace(/\.$/, '');
    const withoutPort = trimmed.split(':')[0].trim();
    return withoutPort;
}

function normalizeRouteKey(routeKey: string): string {
    const input = routeKey.trim().toLowerCase();
    if (!input) {
        return '';
    }

    let normalized = '';
    let previousWasDash = false;
    for (let i = 0; i < input.length; i++) {
        const code = input.charCodeAt(i);
        if (isDnsLabelChar(code)) {
            normalized += input[i];
            previousWasDash = false;
            continue;
        }

        if (!previousWasDash) {
            normalized += '-';
            previousWasDash = true;
        }
    }

    normalized = normalized.replace(/^-+/, '').replace(/-+$/, '');
    if (normalized.length > 63) {
        return '';
    }

    return normalized;
}

function decodeBase64Url(value: string): Buffer {
    const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
    const remainder = base64.length % 4;
    if (remainder === 1) {
        throw new Error('Invalid base64url value.');
    }

    const padding = remainder === 0 ? '' : remainder === 2 ? '==' : '=';

    return Buffer.from(`${base64}${padding}`, 'base64');
}

function timingSafeBufferEqual(a: Buffer, b: Buffer): boolean {
    if (a.length !== b.length) {
        return false;
    }

    return crypto.timingSafeEqual(a, b);
}

function parseHostFromRequest(req: http.IncomingMessage): string {
    const forwardedHostRaw = req.headers['x-forwarded-host'];
    const forwardedHost = Array.isArray(forwardedHostRaw) ? forwardedHostRaw[0] : forwardedHostRaw;
    if (typeof forwardedHost === 'string' && forwardedHost.trim()) {
        return normalizeHost(forwardedHost.split(',')[0]);
    }

    const hostRaw = req.headers.host;
    if (typeof hostRaw === 'string' && hostRaw.trim()) {
        return normalizeHost(hostRaw);
    }

    return '';
}

function parseTicketFromRequest(req: http.IncomingMessage, host: string): string {
    const requestUrl = req.url || '/';
    const baseHost = host || 'localhost';
    const parsed = new URL(requestUrl, `https://${baseHost}`);
    return parsed.searchParams.get('ct')?.trim() || '';
}

function validateAudience(payloadAud: unknown, expectedAudience: string): boolean {
    if (typeof payloadAud === 'string') {
        return payloadAud === expectedAudience;
    }

    if (Array.isArray(payloadAud)) {
        return payloadAud.some((entry) => typeof entry === 'string' && entry === expectedAudience);
    }

    return false;
}

function validateToken(token: string, host: string, settings: ConnectTicketAuthSettings): ValidationResult {
    const segments = token.split('.');
    if (segments.length !== 3) {
        return { isValid: false, reason: 'Connect ticket JWT format is invalid.' };
    }

    const [headerSegment, payloadSegment, signatureSegment] = segments;
    let header: Record<string, unknown>;
    let payload: Record<string, unknown>;
    let providedSignature: Buffer;
    try {
        header = JSON.parse(decodeBase64Url(headerSegment).toString('utf8')) as Record<string, unknown>;
        payload = JSON.parse(decodeBase64Url(payloadSegment).toString('utf8')) as Record<string, unknown>;
        providedSignature = decodeBase64Url(signatureSegment);
    } catch {
        return { isValid: false, reason: 'Connect ticket JWT could not be decoded.' };
    }

    if (header.alg !== 'HS256') {
        return { isValid: false, reason: 'Connect ticket JWT alg must be HS256.' };
    }

    const signingInput = `${headerSegment}.${payloadSegment}`;
    const expectedSignature = crypto.createHmac('sha256', settings.signingKey).update(signingInput).digest();
    if (!timingSafeBufferEqual(providedSignature, expectedSignature)) {
        return { isValid: false, reason: 'Connect ticket JWT signature is invalid.' };
    }

    const nowEpoch = Math.floor(Date.now() / 1000);
    const skew = Math.max(0, settings.clockSkewSeconds);
    const issuer = typeof payload.iss === 'string' ? payload.iss : '';
    if (issuer !== settings.issuer) {
        return { isValid: false, reason: 'Connect ticket issuer is invalid.' };
    }

    if (!validateAudience(payload.aud, settings.audience)) {
        return { isValid: false, reason: 'Connect ticket audience is invalid.' };
    }

    const exp = typeof payload.exp === 'number' ? payload.exp : Number.NaN;
    if (!Number.isFinite(exp)) {
        return { isValid: false, reason: 'Connect ticket is missing exp claim.' };
    }

    if (nowEpoch > exp + skew) {
        return { isValid: false, reason: 'Connect ticket has expired.' };
    }

    const nbf = typeof payload.nbf === 'number' ? payload.nbf : null;
    if (nbf !== null && nowEpoch + skew < nbf) {
        return { isValid: false, reason: 'Connect ticket is not active yet.' };
    }

    const instanceId = typeof payload.instanceId === 'string' ? payload.instanceId.trim() : '';
    if (!instanceId || instanceId !== settings.instanceId) {
        return { isValid: false, reason: 'Connect ticket instanceId does not match this server.' };
    }

    const routeKeyClaim = typeof payload.routeKey === 'string' ? normalizeRouteKey(payload.routeKey) : '';
    if (!routeKeyClaim) {
        return { isValid: false, reason: 'Connect ticket routeKey is missing or invalid.' };
    }

    const expectedHost = `${routeKeyClaim}.${settings.routeHostSuffix}`;
    if (host !== expectedHost) {
        return {
            isValid: false,
            reason: `Connect ticket host mismatch. Expected '${expectedHost}', got '${host || 'unknown'}'.`
        };
    }

    return { isValid: true };
}

function validateSettings(settings: ConnectTicketAuthSettings): void {
    if (settings.mode === 'off') {
        return;
    }

    if (!settings.issuer) {
        throw new Error('auth_issuer is required when auth_mode is soft or enforce.');
    }

    if (!settings.audience) {
        throw new Error('auth_audience is required when auth_mode is soft or enforce.');
    }

    if (!settings.signingKey || settings.signingKey.length < 32) {
        throw new Error('auth_signing_key must be at least 32 characters when auth_mode is soft or enforce.');
    }

    if (!settings.instanceId) {
        throw new Error('auth_instance_id is required when auth_mode is soft or enforce.');
    }

    if (!settings.routeHostSuffix) {
        throw new Error('auth_route_host_suffix is required when auth_mode is soft or enforce.');
    }

    if (settings.routeHostSuffix.includes('*')) {
        throw new Error('auth_route_host_suffix must not contain wildcards.');
    }

    if (UriCheckHostName(settings.routeHostSuffix) === false) {
        throw new Error('auth_route_host_suffix must be a valid DNS host suffix.');
    }
}

function UriCheckHostName(value: string): boolean {
    if (!value) {
        return false;
    }

    const labels = value.split('.');
    if (labels.length < 2) {
        return false;
    }

    return labels.every((label) => {
        if (!label || label.length > 63) {
            return false;
        }

        if (label.startsWith('-') || label.endsWith('-')) {
            return false;
        }

        return /^[a-z0-9-]+$/i.test(label);
    });
}

export function normalizeAuthSettings(settings: ConnectTicketAuthSettings): ConnectTicketAuthSettings {
    const normalized: ConnectTicketAuthSettings = {
        mode: settings.mode,
        issuer: settings.issuer.trim(),
        audience: settings.audience.trim(),
        signingKey: settings.signingKey,
        instanceId: settings.instanceId.trim(),
        routeHostSuffix: normalizeHost(settings.routeHostSuffix),
        clockSkewSeconds: Number.isFinite(settings.clockSkewSeconds) ? settings.clockSkewSeconds : 5
    };

    validateSettings(normalized);
    return normalized;
}

export function createPlayerVerifyClient(
    authSettings: ConnectTicketAuthSettings
): NonNullable<wslib.ServerOptions['verifyClient']> | undefined {
    const settings = normalizeAuthSettings(authSettings);
    if (settings.mode === 'off') {
        Logger.info('Connect ticket auth mode is OFF.');
        return undefined;
    }

    Logger.info(
        `Connect ticket auth mode is ${settings.mode.toUpperCase()} for instance '${settings.instanceId}' and suffix '${settings.routeHostSuffix}'.`
    );

    return ((
        info: { req: http.IncomingMessage },
        done: (result: boolean, code?: number, message?: string) => void
    ) => {
        const host = parseHostFromRequest(info.req);
        const token = parseTicketFromRequest(info.req, host);
        if (!token) {
            const reason = 'Connect ticket (ct) is required.';
            if (settings.mode === 'enforce') {
                Logger.warn(reason);
                done(false, 401, reason);
                return;
            }

            Logger.warn(`[soft] ${reason}`);
            done(true);
            return;
        }

        const validation = validateToken(token, host, settings);
        if (validation.isValid) {
            done(true);
            return;
        }

        if (settings.mode === 'enforce') {
            Logger.warn(validation.reason || 'Connect ticket validation failed.');
            done(false, 401, validation.reason || 'Connect ticket validation failed.');
            return;
        }

        Logger.warn(`[soft] ${validation.reason || 'Connect ticket validation failed.'}`);
        done(true);
    }) as NonNullable<wslib.ServerOptions['verifyClient']>;
}
