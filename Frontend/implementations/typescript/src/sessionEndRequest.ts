/** No API login is present in the player. This bearer capability can only end its exact session. */
export async function requestSessionEnd(capability: string, sessionRequestId: string): Promise<boolean> {
    const request = async (method: 'POST' | 'GET') => {
        const controller = new AbortController();
        const timer = window.setTimeout(() => controller.abort(), 22_000);
        try {
            const response = await fetch('/api/session-end', {
                method, headers: { 'X-SW-Session-End': capability, 'X-SW-Session-Request': sessionRequestId },
                credentials: 'omit', cache: 'no-store', redirect: 'error', signal: controller.signal
            });
            if (!response.ok) return false;
            const result = await response.json() as { accepted?: unknown; sessionRequestId?: unknown };
            return result.accepted === true && result.sessionRequestId === sessionRequestId;
        } finally { window.clearTimeout(timer); }
    };
    try { if (await request('POST')) return true; } catch { /* Read-only reconciliation below. */ }
    // Never automatically repeat a destructive request after a lost response.
    try { return await request('GET'); } catch { return false; }
}
