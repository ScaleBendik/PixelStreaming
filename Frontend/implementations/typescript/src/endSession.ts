type EndContext = {
    region: string;
    instanceId: string;
    sessionRequestId: string;
};

// This decoding controls presentation only. Authorization stays in the manager/API.
export function isManagedEndContext(ticket: string, requestId: string): boolean {
    try {
        const encoded = ticket.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
        const claims = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, '='))) as {
            sessionRequestId?: unknown; shadowSessionRequestId?: unknown;
        };
        return !!requestId && claims.sessionRequestId === requestId && !claims.shadowSessionRequestId;
    } catch { return false; }
}

export function buildEndSessionUrl(managerOrigin: string, context: EndContext): string {
    const url = new URL('/servers/', managerOrigin);
    url.searchParams.set('endRegion', context.region);
    url.searchParams.set('endInstanceId', context.instanceId);
    url.searchParams.set('endSessionRequestId', context.sessionRequestId);
    return url.toString();
}

export function installEndSession(options: {
    controls: HTMLElement;
    modalParent: HTMLElement;
    managerOrigin: string;
    context: EndContext;
    setModalInput: (open: boolean) => void;
    onEnded: () => void;
    onPending?: (pending: boolean) => void;
}) {
    const { context } = options;
    let port: MessagePort | null = null;
    let checkingManager = false;
    let pending = false;
    let ended = false;
    let uncertain = false;
    let timeout: number | undefined;
    const button = document.createElement('button');
    button.type = 'button';
    button.id = 'endSessionBtn';
    button.className = 'UiTool';
    button.title = 'End session';
    button.setAttribute('aria-label', 'End session');
    button.style.cssText = 'margin-top:14px;color:#f0b4b4';
    button.innerHTML = '<svg viewBox="0 0 32 32" width="100%" height="100%" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M16 4v12M9 7a12 12 0 1 0 14 0"/></g></svg>';
    options.controls.appendChild(button);

    const dialog = document.createElement('dialog');
    dialog.id = 'endSessionDialog';
    dialog.setAttribute('aria-labelledby', 'stream-end-session-title');
    dialog.style.cssText = 'width:min(440px,calc(100vw - 48px));box-sizing:border-box;padding:28px;border:1px solid #59616b;' +
        'border-radius:14px;background:#20262e;color:#fff;font:16px/1.5 system-ui;text-transform:none;box-shadow:0 20px 80px #0009';
    const style = document.createElement('style');
    style.textContent = '#endSessionDialog::backdrop{background:#0009}#endSessionDialog button,#endSessionDialog a{font:inherit;border-radius:7px;padding:10px 16px;cursor:pointer}' +
        '#endSessionDialog button:focus-visible,#endSessionDialog a:focus-visible,#endSessionBtn:focus-visible{outline:3px solid #8bd0ff;outline-offset:3px}' +
        '#endSessionDialog button:disabled{opacity:.6;cursor:wait}';
    const title = document.createElement('h2');
    title.id = 'stream-end-session-title';
    title.textContent = 'End this session?';
    title.style.cssText = 'margin:0 0 12px;font-size:23px;color:inherit;text-transform:none';
    const message = document.createElement('p');
    message.textContent = 'This ends your ScaleWorld session. To continue later, you’ll need to start a new session.';
    const status = document.createElement('p');
    status.setAttribute('role', 'status');
    const fallback = document.createElement('a');
    fallback.href = buildEndSessionUrl(options.managerOrigin, context);
    fallback.textContent = 'Open session manager to end session';
    fallback.style.cssText = 'display:none;color:#9bd8ff';
    // Navigate this tab: works without popup permission or the original manager tab.
    const actions = document.createElement('div');
    actions.style.cssText = 'display:flex;justify-content:flex-end;gap:12px;margin-top:24px';
    const cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.textContent = 'Keep streaming';
    cancel.style.cssText = 'background:transparent;border:1px solid #8793a0;color:white';
    const confirm = document.createElement('button');
    confirm.type = 'button';
    confirm.textContent = 'End session';
    confirm.style.cssText = 'background:#b9363e;border:1px solid #b9363e;color:white';
    actions.append(cancel, confirm);
    dialog.append(title, message, status, fallback, actions);
    options.modalParent.append(style, dialog);
    const showFallback = (text: string) => {
        pending = false;
        options.onPending?.(false);
        window.clearTimeout(timeout);
        status.textContent = text;
        fallback.style.display = 'block';
        confirm.disabled = true;
        cancel.disabled = false;
    };
    const markEnded = () => {
        if (ended) return;
        ended = true;
        pending = false;
        window.clearTimeout(timeout);
        options.onEnded();
        options.setModalInput(true);
        title.textContent = 'Session ended';
        message.textContent = 'You can close this tab.';
        status.textContent = '';
        fallback.style.display = 'none';
        actions.style.display = 'none';
        button.disabled = true;
        if (!dialog.open) dialog.showModal();
        window.close();
    };
    const receive = (event: MessageEvent) => {
        const data = event.data;
        if (ended || pending || event.origin !== options.managerOrigin || !event.source ||
            data?.type !== 'sw-session-end-channel' || data.version !== 1 ||
            data.region !== context.region || data.instanceId !== context.instanceId ||
            data.sessionRequestId !== context.sessionRequestId || event.ports.length !== 1) return;
        port?.close();
        port = event.ports[0];
        port.onmessage = (reply: MessageEvent) => {
            if (reply.data?.type === 'ping') {
                port?.postMessage({ type: 'pong' });
                if (dialog.open && !pending && !ended && !uncertain) {
                    confirm.disabled = false;
                    fallback.style.display = 'none';
                    status.textContent = '';
                }
            } else if (reply.data?.type === 'available' && pending && checkingManager) {
                checkingManager = false;
                window.clearTimeout(timeout);
                options.onPending?.(true);
                status.textContent = 'Ending session…';
                // Longer than preflight + mutation + reconciliation in the manager.
                timeout = window.setTimeout(() => showFallback('The session end could not be confirmed. Check the session manager before trying again.'), 40_000);
                port?.postMessage({ type: 'end', sessionRequestId: context.sessionRequestId });
            } else if (reply.data?.type === 'end-result' && pending && !checkingManager) {
                if (reply.data.accepted === true) markEnded();
                else {
                    uncertain = true;
                    showFallback('The session end could not be confirmed. Check the session manager.');
                }
            }
        };
        port.postMessage({ type: 'ready' });
    };
    window.addEventListener('message', receive);
    button.addEventListener('click', () => {
        document.exitPointerLock?.();
        options.setModalInput(true);
        status.textContent = '';
        fallback.style.display = 'none';
        confirm.disabled = false;
        dialog.showModal();
        cancel.focus();
        if (!port) {
            showFallback('The original session manager is unavailable. Open it to confirm ending this session.');
        }
    });
    cancel.addEventListener('click', () => { if (!pending && !ended) dialog.close(); });
    dialog.addEventListener('cancel', (event) => { if (pending || ended) event.preventDefault(); });
    dialog.addEventListener('close', () => { if (!ended) options.setModalInput(false); });
    confirm.addEventListener('click', () => {
        if (pending || ended) return;
        if (!port) {
            showFallback('Open the session manager to confirm ending this session.');
            return;
        }
        pending = true;
        uncertain = true;
        checkingManager = true;
        confirm.disabled = true;
        cancel.disabled = true;
        status.textContent = 'Contacting session manager…';
        // Message delivery wakes a responsive background tab even if its timers were throttled.
        // No destructive request is sent until this live round trip completes.
        timeout = window.setTimeout(() => showFallback('The original session manager is unavailable. Open it to confirm ending this session.'), 4_000);
        port.postMessage({ type: 'probe' });
    });
    return {
        markEnded,
        dispose: () => {
            window.removeEventListener('message', receive);
            window.clearTimeout(timeout);
            port?.close();
            options.setModalInput(false);
            dialog.remove();
            style.remove();
            button.remove();
        }
    };
}
