// Copyright Epic Games, Inc. All Rights Reserved.

const REDACTED_LOG_VALUE = '[REDACTED]';

const SENSITIVE_LOG_KEYS = new Set([
    'accesstoken',
    'authorization',
    'credential',
    'password',
    'proxyauthorization',
    'refreshtoken',
    'secret',
    'token',
    'username'
]);

function normalizeLogKey(key: string): string {
    return key.replace(/[^a-z0-9]/gi, '').toLowerCase();
}

function redactSensitiveLogValueInternal(value: unknown, seen: WeakMap<object, unknown>): unknown {
    if (value === null || typeof value !== 'object') {
        return value;
    }

    const existing = seen.get(value);
    if (existing !== undefined) {
        return existing;
    }

    if (Array.isArray(value)) {
        const redacted: unknown[] = [];
        seen.set(value, redacted);
        for (const item of value) {
            redacted.push(redactSensitiveLogValueInternal(item, seen));
        }
        return redacted;
    }

    // Protocol messages may be generated class instances rather than plain object literals.
    // Their enumerable fields are exactly what the logger serializes, so clone and inspect those
    // fields as well; otherwise a nested generated `config` message can bypass credential
    // redaction even though the surrounding log envelope is a plain object.
    const redacted: Record<string, unknown> = {};
    seen.set(value, redacted);
    for (const [key, item] of Object.entries(value)) {
        redacted[key] = SENSITIVE_LOG_KEYS.has(normalizeLogKey(key))
            ? REDACTED_LOG_VALUE
            : redactSensitiveLogValueInternal(item, seen);
    }
    return redacted;
}

/**
 * Makes a non-mutating, logging-only copy with credential-like values removed.
 */
export function redactSensitiveLogValue(value: unknown): unknown {
    return redactSensitiveLogValueInternal(value, new WeakMap<object, unknown>());
}
