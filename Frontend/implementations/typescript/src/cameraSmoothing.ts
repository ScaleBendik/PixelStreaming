import type { PixelStreaming } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8';

export type CameraSmoothingState = {
    phase: 'disconnected' | 'syncing' | 'ready' | 'setting' | 'unavailable';
    enabled: boolean | null;
    message: string;
};

/** Optional application messages. Never change recording, reconnect, or input ownership. */
export function createCameraSmoothingSync(stream: PixelStreaming, onChange: (state: CameraSmoothingState) => void) {
    const listenerName = 'scaleWorldCameraSmoothing';
    const nonce = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
    let sequence = 0;
    let disposed = false;
    let connected = false;
    let synchronized = false;
    let timer: number | undefined;
    let reconcileDesired: boolean | undefined;
    let state: CameraSmoothingState = { phase: 'disconnected', enabled: null, message: 'Connect to change camera smoothing.' };
    let pending: { id: string; kind: 'get' | 'set'; attempts: number; desired?: boolean } | null = null;
    const safe = (action: () => void) => { try { action(); } catch { /* Optional UI must not interrupt shared event dispatch. */ } };
    const publish = (next: CameraSmoothingState) => {
        state = next;
        safe(() => onChange({ ...state }));
    };
    const isOpen = () => {
        try { return stream.webRtcController.isDataChannelOpen(); } catch { return false; }
    };
    const send = (message: object) => {
        try { return stream.emitUIInteraction(message) === true; } catch { return false; }
    };
    const clear = () => { window.clearTimeout(timer); timer = undefined; pending = null; };
    const reset = () => {
        if (disposed) return;
        clear();
        connected = false;
        synchronized = false;
        reconcileDesired = undefined;
        publish({ phase: 'disconnected', enabled: null, message: 'Connect to change camera smoothing.' });
    };
    const unavailable = () => {
        clear();
        synchronized = false;
        publish({ phase: 'unavailable', enabled: null, message: 'Camera smoothing unavailable. Recording still works.' });
    };
    const transmitQuery = () => {
        const request = pending;
        if (disposed || request?.kind !== 'get') return;
        if (!isOpen()) { reset(); return; }
        request.attempts++;
        // Arm before send: a synchronous response must also be able to clear this timer.
        timer = window.setTimeout(() => {
            if (disposed || pending !== request) return;
            if (request.attempts < 3) transmitQuery(); else unavailable();
        }, 2000);
        send({ type: 'CameraSmoothing.Get', requestId: request.id });
    };
    const query = (desired?: boolean) => {
        if (disposed) return;
        if (!isOpen()) { reset(); return; }
        clear();
        connected = true;
        synchronized = false;
        reconcileDesired = desired;
        pending = { id: `${nonce}-${++sequence}`, kind: 'get', attempts: 0 };
        publish({ phase: 'syncing', enabled: null, message: desired === undefined
            ? 'Checking camera smoothing…' : 'Change not confirmed. Checking current setting…' });
        transmitQuery();
    };
    const onOpen = () => { if (!disposed && !connected && isOpen()) query(); };
    const onResponse = (response: string) => {
        if (disposed || !connected || !isOpen() || typeof response !== 'string' || response.length > 4096) return;
        let message: { type?: unknown; enabled?: unknown; requestId?: unknown };
        try { message = JSON.parse(response); } catch { return; }
        if (!message || message.type !== 'CameraSmoothing.State' || typeof message.enabled !== 'boolean') return;
        if (message.requestId !== undefined) {
            if (!pending || message.requestId !== pending.id) return;
            const desired = pending.kind === 'set' ? pending.desired : reconcileDesired;
            clear();
            synchronized = true;
            reconcileDesired = undefined;
            publish({ phase: 'ready', enabled: message.enabled,
                message: desired !== undefined && desired !== message.enabled ? 'The change was not applied.' : '' });
        } else if (synchronized) {
            // Widget broadcasts update the actual value, but cannot acknowledge a browser request.
            publish({ ...state, enabled: message.enabled, message: state.phase === 'ready' ? '' : state.message });
        }
    };
    const setEnabled = (enabled: boolean) => {
        if (disposed || state.phase !== 'ready' || typeof enabled !== 'boolean' || enabled === state.enabled) return;
        if (!isOpen()) { reset(); return; }
        const request = { id: `${nonce}-${++sequence}`, kind: 'set' as const, attempts: 1, desired: enabled };
        pending = request;
        publish({ phase: 'setting', enabled: state.enabled, message: 'Applying camera smoothing…' });
        timer = window.setTimeout(() => { if (!disposed && pending === request) query(enabled); }, 3000);
        // Set is sent once. On uncertainty, query the actual value instead of retrying a mutation.
        if (!send({ type: 'CameraSmoothing.Set', requestId: request.id, enabled }) && pending === request) query(enabled);
    };
    const events = [
        ['dataChannelOpen', onOpen], ['dataChannelClose', reset], ['webRtcConnecting', reset],
        ['webRtcDisconnected', reset], ['webRtcFailed', reset]
    ] as const;
    const dispose = () => {
        if (disposed) return;
        disposed = true;
        clear();
        safe(() => stream.removeResponseEventListener(listenerName));
        for (const [name, listener] of events) safe(() => stream.removeEventListener(name, listener));
    };
    try {
        stream.addResponseEventListener(listenerName, onResponse);
        for (const [name, listener] of events) stream.addEventListener(name, listener);
        publish(state);
        onOpen();
    } catch {
        dispose();
        publish({ phase: 'unavailable', enabled: null, message: 'Camera smoothing unavailable. Recording still works.' });
    }
    return {
        get snapshot() { return { ...state }; },
        setEnabled,
        retry: () => { if (!pending) query(); },
        dispose
    };
}

export function installCameraSmoothingControl(options: {
    stream: PixelStreaming; parent: HTMLElement; focusStream: () => void;
}) {
    const root = document.createElement('div');
    root.id = 'cameraSmoothingSettings';
    root.style.cssText = 'width:280px;max-width:100%;box-sizing:border-box;padding:8px;font:14px/1.5 system-ui;text-transform:none';
    const label = document.createElement('label');
    label.style.cssText = 'display:flex;align-items:center;gap:10px;cursor:pointer';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.id = 'cameraSmoothingEnabled';
    checkbox.style.cssText = 'appearance:auto;position:static;opacity:1;width:18px;height:18px;flex:0 0 18px;margin:0;accent-color:#168eea';
    const text = document.createElement('span');
    text.textContent = 'Smooth camera movement';
    label.append(checkbox, text);
    const status = document.createElement('p');
    status.id = 'cameraSmoothingStatus';
    status.style.cssText = 'margin:6px 0;font-size:12px';
    status.setAttribute('role', 'status');
    checkbox.setAttribute('aria-describedby', status.id);
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.textContent = 'Retry';
    retry.id = 'cameraSmoothingRetry';
    retry.style.cssText = 'position:static;width:auto;height:auto;padding:4px 10px;font:inherit;color:inherit;background:transparent;border:1px solid #8793a0;border-radius:5px';
    root.append(label, status, retry);
    const sync = createCameraSmoothingSync(options.stream, state => {
        checkbox.checked = state.enabled === true;
        checkbox.indeterminate = state.enabled === null;
        checkbox.disabled = state.phase !== 'ready';
        status.textContent = state.message;
        retry.hidden = state.phase !== 'unavailable';
    });
    checkbox.addEventListener('change', () => sync.setEnabled(checkbox.checked));
    retry.addEventListener('click', () => sync.retry());
    for (const name of ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup', 'click', 'wheel']) {
        root.addEventListener(name, event => event.stopPropagation());
    }
    root.addEventListener('click', (event) => {
        if (event.detail > 0 && (root.contains(document.activeElement) || document.activeElement === document.body)) {
            try { options.focusStream(); } catch { /* Optional focus recovery. */ }
        }
    });
    try { options.parent.prepend(root); }
    catch (error) { sync.dispose(); throw error; }
    return { dispose: () => { sync.dispose(); root.remove(); } };
}
