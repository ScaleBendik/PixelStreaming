// Copyright Epic Games, Inc. All Rights Reserved.
import { jsonc } from 'jsonc';

// A simple interface to describe the options from commander.js
export type IProgramOptions = Record<string, any>;

/**
 * Cirular reference safe version of JSON.stringify
 */
export function stringify(obj: any): string {
    return jsonc.stringify(obj);
}

/**
 * Circular reference save version of JSON.stringify with extra formatting.
 */
export function beautify(obj: any): string {
    return jsonc.stringify(obj, undefined, '\t');
}

const REDACTED_LOG_FIELDS = new Set([
    'auth_signing_key',
    'turn_secret',
    'instance_agent_bootstrap_shared_secret',
    'peer_options',
    'peer_options_player',
    'peer_options_streamer'
]);

/**
 * Makes a logging-only copy of CLI options without runtime authentication or ICE secrets.
 */
export function sanitizeOptionsForLogging(input: IProgramOptions): IProgramOptions {
    const sanitized: IProgramOptions = { ...input };
    for (const field of REDACTED_LOG_FIELDS) {
        const hasValue = Object.prototype.hasOwnProperty.call(input, field);
        if (
            hasValue &&
            sanitized[field] !== undefined &&
            sanitized[field] !== null &&
            sanitized[field] !== ''
        ) {
            sanitized[field] = '[redacted]';
        }
    }

    return sanitized;
}
