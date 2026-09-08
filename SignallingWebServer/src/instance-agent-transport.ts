// Copyright Epic Games, Inc. All Rights Reserved.

export const AGENT_REQUEST_TIMEOUT_MS = 15_000;

/** The deadline covers response headers and body consumption, including error bodies. */
export function fetchWithDeadline(
    input: string,
    init: RequestInit = {},
    timeoutMs = AGENT_REQUEST_TIMEOUT_MS
): Promise<Response> {
    const deadline = AbortSignal.timeout(timeoutMs);
    return fetch(input, {
        ...init,
        signal: init.signal ? AbortSignal.any([init.signal, deadline]) : deadline
    });
}
