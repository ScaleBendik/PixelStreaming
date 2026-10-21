// Copyright Epic Games, Inc. All Rights Reserved.
import express, { type ErrorRequestHandler, type RequestHandler } from 'express';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const failureCodes = new Set([
    'file_open_failed',
    'recorder_start_failed',
    'recorder_failed',
    'start_timeout',
    'format_mismatch',
    'write_backpressure',
    'write_failed',
    'stop_timeout',
    'stop_failed',
    'write_timeout',
    'empty_recording',
    'file_close_failed'
]);
const fields = new Set([
    'schemaVersion',
    'recordingId',
    'eventType',
    'occurredAtUtc',
    'codec',
    'container',
    'bytesWritten',
    'durationMs',
    'failureCode'
]);

export function validRecordingEvent(value: unknown): value is Record<string, unknown> {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    const r = value as Record<string, unknown>;
    return (
        Object.keys(r).every((key) => fields.has(key)) &&
        r.schemaVersion === 1 &&
        typeof r.recordingId === 'string' &&
        uuid.test(r.recordingId) &&
        typeof r.eventType === 'string' &&
        ['recording_started', 'recording_saved', 'recording_failed'].includes(r.eventType) &&
        typeof r.occurredAtUtc === 'string' &&
        /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(r.occurredAtUtc) &&
        Number.isFinite(Date.parse(r.occurredAtUtc)) &&
        new Date(r.occurredAtUtc).toISOString() === r.occurredAtUtc &&
        typeof r.codec === 'string' &&
        ['AV1', 'VP9', 'H264'].includes(r.codec) &&
        r.container === (r.codec === 'H264' ? 'matroska' : 'webm') &&
        typeof r.bytesWritten === 'number' &&
        Number.isSafeInteger(r.bytesWritten) &&
        r.bytesWritten >= 0 &&
        r.bytesWritten <= 2 ** 40 &&
        typeof r.durationMs === 'number' &&
        Number.isSafeInteger(r.durationMs) &&
        r.durationMs >= 0 &&
        r.durationMs <= 86_400_000 &&
        (r.eventType === 'recording_failed'
            ? typeof r.failureCode === 'string' && failureCodes.has(r.failureCode)
            : r.failureCode === undefined) &&
        (r.eventType !== 'recording_saved' || r.bytesWritten > 0)
    );
}

/** Only the API can authenticate this recording-only capability and acknowledge durable ingestion. */
export function createRecordingEventsProxy(apiBaseUrl: string, send: typeof fetch = fetch): RequestHandler {
    let endpoint: string | undefined;
    try {
        const base = new URL(apiBaseUrl);
        if (base.protocol === 'https:' && !base.username && !base.password) {
            endpoint = new URL('/session/player-recordings', base).toString();
        }
    } catch {
        /* Optional integration; local recording remains available. */
    }
    return async (request, response) => {
        response.setHeader('Cache-Control', 'no-store');
        if (request.method !== 'POST') {
            response.setHeader('Allow', 'POST');
            response.sendStatus(405);
            return;
        }
        const capability = request.get('X-SW-Recording');
        const sessionRequestId = request.get('X-SW-Session-Request');
        if (
            !sessionRequestId ||
            !uuid.test(sessionRequestId) ||
            !capability ||
            !/^[A-Za-z0-9_.-]{1,8192}$/.test(capability)
        ) {
            response.sendStatus(401);
            return;
        }
        if (!validRecordingEvent(request.body)) {
            response.sendStatus(400);
            return;
        }
        if (!endpoint) {
            response.sendStatus(503);
            return;
        }
        const body = request.body;
        try {
            const upstream = await send(endpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-SW-Recording': capability,
                    'X-SW-Session-Request': sessionRequestId
                },
                body: JSON.stringify(body),
                redirect: 'error',
                signal: AbortSignal.timeout(4_000)
            });
            if (!upstream.ok) {
                response.sendStatus(
                    [400, 401, 403, 404, 409, 410, 413, 415, 422, 429, 501, 503].includes(upstream.status)
                        ? upstream.status
                        : 502
                );
                return;
            }
            const ack = (await upstream.json()) as Record<string, unknown> | null;
            if (
                !ack ||
                ack.accepted !== true ||
                ack.sessionRequestId !== sessionRequestId ||
                ack.recordingId !== body.recordingId ||
                ack.eventType !== body.eventType
            ) {
                response.sendStatus(502);
                return;
            }
            response.json({
                accepted: true,
                sessionRequestId,
                recordingId: body.recordingId,
                eventType: body.eventType
            });
        } catch {
            // Never log the capability, request payload, headers or upstream body.
            response.sendStatus(503);
        }
    };
}

export function createRecordingEventsRouter(apiBaseUrl: string, send: typeof fetch = fetch): express.Router {
    const router = express.Router();
    router.use((_request, response, next) => {
        response.setHeader('Cache-Control', 'no-store');
        next();
    });
    router.all(
        '/',
        express.json({ limit: '8kb', strict: true, inflate: false }),
        createRecordingEventsProxy(apiBaseUrl, send)
    );
    const invalidBody: ErrorRequestHandler = (error: { status?: number }, _request, response, _next) => {
        response.sendStatus(error.status === 413 ? 413 : error.status === 415 ? 415 : 400);
    };
    router.use(invalidBody);
    return router;
}
