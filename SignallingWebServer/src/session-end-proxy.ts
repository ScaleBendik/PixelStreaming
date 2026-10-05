// Copyright Epic Games, Inc. All Rights Reserved.
import type { RequestHandler } from 'express';

/** Fixed upstream and purpose-specific credential only; never forwards an agent/API login. */
export function createSessionEndProxy(apiBaseUrl: string, send: typeof fetch = fetch): RequestHandler {
    let endpoint: string | undefined;
    try {
        const base = new URL(apiBaseUrl);
        if (base.protocol === 'https:' && !base.username && !base.password) {
            endpoint = new URL('/session/player-end', base).toString();
        }
    } catch {
        /* Missing configuration leaves only the manager fallback. */
    }
    return async (request, response) => {
        response.setHeader('Cache-Control', 'no-store');
        const credential = request.get('X-SW-Session-End');
        const expectedRequest = request.get('X-SW-Session-Request');
        if (
            !expectedRequest ||
            !/^[0-9a-f-]{36}$/i.test(expectedRequest) ||
            !credential ||
            credential.length > 8192 ||
            !/^[A-Za-z0-9_.-]+$/.test(credential)
        ) {
            response.sendStatus(401);
            return;
        }
        if (!endpoint) {
            response.sendStatus(503);
            return;
        }
        try {
            const upstream = await send(endpoint, {
                method: request.method === 'GET' ? 'GET' : 'POST',
                headers: { 'X-SW-Session-End': credential, 'X-SW-Session-Request': expectedRequest },
                redirect: 'error',
                signal: AbortSignal.timeout(20_000)
            });
            if (!upstream.ok) {
                response.sendStatus([401, 403, 409, 503].includes(upstream.status) ? upstream.status : 502);
                return;
            }
            const result = (await upstream.json()) as { accepted?: unknown; sessionRequestId?: unknown };
            if (
                typeof result.accepted !== 'boolean' ||
                typeof result.sessionRequestId !== 'string' ||
                !/^[0-9a-f-]{36}$/i.test(result.sessionRequestId)
            ) {
                response.sendStatus(502);
                return;
            }
            response.json({ accepted: result.accepted, sessionRequestId: result.sessionRequestId });
        } catch {
            // Never log the credential, upstream body or request headers.
            response.sendStatus(503);
        }
    };
}
