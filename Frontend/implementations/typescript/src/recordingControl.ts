import { getRecordingFormat, getRecordingSupport, LocalRecordingController, RecordingSnapshot, RecordingSource } from './localRecording';

export type RecordingControlOptions = {
    settingsSection: HTMLElement;
    statusAnchor?: HTMLElement;
    modalParent: HTMLElement;
    focusStream: () => void;
    getSource: () => RecordingSource | null;
    setModalInput: (open: boolean) => void;
    beforeRecord?: () => void | Promise<void>;
};

function elapsedTime(startedAt: number | null): string {
    const seconds = startedAt === null ? 0 : Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
}

function fileSize(bytes: number): string {
    return bytes < 1024 * 1024 ? `${Math.round(bytes / 1024)} KB` : `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function installRecordingControl(options: RecordingControlOptions) {
    const recorder = new LocalRecordingController({ getSource: options.getSource });
    let disposed = false;
    let inputCaptured = false;
    let unloadAttached = false;
    let allowLeave = false;
    let localError = '';
    let leaveRequest: Promise<boolean> | null = null;
    let resolveLeave: ((leave: boolean) => void) | null = null;
    let lastPhase: RecordingSnapshot['phase'] = recorder.snapshot.phase;
    let frozenElapsed = '00:00';
    let displayedFormat = '';
    let preparing = false;
    let preparation = 0;

    const panel = document.createElement('div');
    panel.id = 'recordingSettings';
    panel.style.cssText = 'width:280px;max-width:100%;box-sizing:border-box;padding:4px 8px 12px;font:14px/1.5 system-ui;text-transform:none;overflow-wrap:anywhere';
    options.settingsSection.appendChild(panel);
    const badge = document.createElement('span');
    badge.id = 'recordingBadge';
    badge.setAttribute('aria-hidden', 'true');
    badge.style.cssText = 'display:none;position:absolute;left:calc(100% + 8px);top:50%;transform:translateY(-50%);width:max-content;pointer-events:none;padding:4px 8px;border-radius:5px;background:#20262e;color:#fff;font:12px/1.4 system-ui;text-transform:none;box-shadow:0 2px 8px #0008';
    options.statusAnchor?.appendChild(badge);

    // Normal recording controls live inline. Only a failed save during navigation
    // needs a modal, so its decision remains reachable above End session's dialog.
    const dialog = document.createElement('dialog');
    dialog.id = 'recordingLeaveDialog';
    dialog.setAttribute('aria-labelledby', 'stream-recording-title');
    dialog.style.cssText = 'width:min(490px,calc(100vw - 40px));max-height:calc(100vh - 40px);overflow:auto;box-sizing:border-box;padding:26px;border:1px solid #59616b;border-radius:14px;background:#20262e;color:#fff;font:16px/1.5 system-ui;text-transform:none;box-shadow:0 20px 80px #0009';
    const style = document.createElement('style');
    style.textContent = '#recordingLeaveDialog::backdrop{background:#0009}' +
        '#recordingSettings button,#recordingLeaveDialog button{font:inherit;position:static;width:auto;height:auto;line-height:1.4;text-align:center;border-radius:7px;padding:8px 12px;cursor:pointer;border:1px solid #8793a0;background:transparent;color:inherit}' +
        '#recordingSettings button:hover,#recordingLeaveDialog button:hover{background:#59616b;color:#fff;border:1px solid #8793a0;padding:8px 12px}' +
        '#recordingSettings button:focus-visible,#recordingLeaveDialog button:focus-visible{outline:3px solid #8bd0ff;outline-offset:3px}' +
        '#recordingSettings button:disabled,#recordingLeaveDialog button:disabled{opacity:.5;cursor:not-allowed}' +
        '#recordingSettings p{margin:10px 0}';
    const title = document.createElement('h2');
    title.id = 'stream-recording-title';
    title.textContent = 'Recording not saved';
    title.style.cssText = 'margin:0 0 12px;font-size:23px;color:inherit;text-transform:none';
    const description = document.createElement('p');
    description.textContent = 'Save this session’s video and available audio to a file on your device.';
    const filename = document.createElement('p');
    filename.id = 'recordingFilename';
    filename.style.cssText = 'overflow-wrap:anywhere;font-weight:600';
    const format = document.createElement('p');
    format.id = 'recordingFormat';
    const details = document.createElement('p');
    details.id = 'recordingDetails';
    details.style.cssText = 'font-variant-numeric:tabular-nums';
    const status = document.createElement('p');
    status.id = 'recordingStatus';
    status.setAttribute('role', 'status');
    status.setAttribute('aria-live', 'polite');
    const notice = document.createElement('p');
    notice.textContent = 'Keep this tab open until Saved appears to avoid losing the recording.';
    notice.style.cssText = 'font-size:12px;opacity:.8';
    const actions = document.createElement('div');
    actions.style.cssText = 'display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:16px';
    const action = (id: string, label: string) => {
        const element = document.createElement('button');
        element.type = 'button';
        element.id = id;
        element.textContent = label;
        return element;
    };
    const choose = action('recordingChoose', 'Choose location');
    choose.style.gridColumn = '1 / -1';
    const record = action('recordingStart', 'Record');
    record.style.cssText = 'background:#b9363e;border-color:#b9363e;color:#fff';
    const stop = action('recordingStop', 'Stop');
    actions.append(choose, record, stop);
    const leaveWarning = document.createElement('div');
    leaveWarning.id = 'recordingLeaveWarning';
    leaveWarning.style.display = 'none';
    const leaveMessage = document.createElement('p');
    leaveMessage.textContent = 'The recording could not be saved. Leave this page without a completed recording?';
    const leaveActions = document.createElement('div');
    leaveActions.style.cssText = 'display:flex;flex-wrap:wrap;gap:10px;justify-content:flex-end';
    const stay = action('recordingStay', 'Stay on this page');
    const leave = action('recordingLeave', 'Leave without recording');
    leave.style.cssText = 'background:#b9363e;border-color:#b9363e';
    leaveActions.append(stay, leave);
    leaveWarning.append(leaveMessage, leaveActions);
    panel.append(description, filename, format, details, status, notice, actions);
    dialog.append(title, leaveWarning);
    options.modalParent.append(style, dialog);

    const beforeUnload = (event: BeforeUnloadEvent) => {
        if (!allowLeave && recorder.hasUnsavedData) {
            event.preventDefault();
            event.returnValue = '';
        }
    };
    const syncUnload = () => {
        const needed = !allowLeave && recorder.hasUnsavedData;
        if (needed === unloadAttached) return;
        if (needed) window.addEventListener('beforeunload', beforeUnload);
        else window.removeEventListener('beforeunload', beforeUnload);
        unloadAttached = needed;
    };
    const unavailableReason = () => {
        const support = getRecordingSupport();
        if (!support.supported) return support.reason;
        const source = options.getSource();
        if (!source) return 'Connect to a session to record.';
        if (!source.eligible) return 'The video stream is not ready for recording.';
        if (!getRecordingFormat(source.codec)) return 'Recording requires an AV1, VP9 or H.264 video stream.';
        if (source.videoTrack.readyState !== 'live') return 'Waiting for the video stream.';
        return '';
    };
    const render = () => {
        if (disposed) return;
        const snapshot = recorder.snapshot;
        const active = snapshot.phase === 'starting' || snapshot.phase === 'recording';
        const busy = preparing || active || snapshot.phase === 'saving' || snapshot.phase === 'choosing';
        if (active) frozenElapsed = elapsedTime(snapshot.startedAt);
        else if (snapshot.phase === 'idle' || snapshot.phase === 'ready') frozenElapsed = '00:00';
        if (active && lastPhase !== snapshot.phase) allowLeave = false;
        lastPhase = snapshot.phase;
        if (['idle', 'ready', 'choosing'].includes(snapshot.phase) || !snapshot.filename) {
            const currentFormat = getRecordingFormat(options.getSource()?.codec || '');
            displayedFormat = currentFormat ? `${currentFormat.codec === 'H264' ? 'H.264' : currentFormat.codec} · ${currentFormat.extension === '.webm' ? 'WebM' : 'MKV'} (${currentFormat.extension})` : '';
        }
        format.textContent = displayedFormat ? `Format: ${displayedFormat}` : '';
        const reason = unavailableReason();
        choose.disabled = busy || !!reason || !!resolveLeave;
        record.disabled = preparing || snapshot.phase !== 'ready' || !!reason || !!resolveLeave;
        stop.disabled = (!preparing && !active) || !!resolveLeave;
        filename.textContent = snapshot.filename || 'No location selected';
        details.textContent = `${frozenElapsed} · ${fileSize(snapshot.bytesWritten)} written`;
        const messages: Record<RecordingSnapshot['phase'], string> = {
            idle: 'Choose where to save your recording.', choosing: 'Choose a filename in the Save dialog.',
            ready: 'Ready to record.', starting: 'Starting recording…', recording: 'Recording…',
            saving: 'Saving… Keep this tab open.', saved: 'Saved. Choose a new location to record another clip.', error: 'The recording could not be saved.'
        };
        const stateMessage = localError || (preparing ? 'Preparing recording…' : snapshot.message || messages[snapshot.phase]);
        const showReason = !busy && snapshot.phase !== 'error' && snapshot.phase !== 'saved';
        status.textContent = showReason && reason ? reason : stateMessage;
        status.style.cssText = localError || snapshot.phase === 'error'
            ? 'color:#ffb8b8;background:#4a1c22;border-radius:4px;padding:6px' : '';
        const badgeText = preparing ? 'Starting…' : active ? `${snapshot.phase === 'starting' ? 'Starting' : '● REC'} ${frozenElapsed}` :
            snapshot.phase === 'saving' ? 'Saving…' : snapshot.phase === 'saved' ? 'Saved' : snapshot.phase === 'error' ? 'Not saved' : '';
        badge.textContent = badgeText;
        badge.style.display = badgeText ? 'block' : 'none';
        badge.style.color = active || snapshot.phase === 'error' ? '#ffb8b8' : '#fff';
        syncUnload();
    };
    const cancelPreparation = () => {
        if (!preparing) return;
        preparation++;
        preparing = false;
        render();
    };
    const openDialog = () => {
        if (disposed || dialog.open) return;
        document.exitPointerLock?.();
        if (!inputCaptured) {
            options.setModalInput(true);
            inputCaptured = true;
        }
        try { dialog.showModal(); }
        catch (error) {
            inputCaptured = false;
            options.setModalInput(false);
            throw error;
        }
        render();
        stay.focus();
    };
    const finishLeave = (approved: boolean) => {
        const resolve = resolveLeave;
        resolveLeave = null;
        leaveWarning.style.display = 'none';
        allowLeave = approved;
        syncUnload();
        render();
        resolve?.(approved);
    };
    const perform = async (operation: () => Promise<unknown>) => {
        localError = '';
        try { await operation(); }
        catch (error) { localError = error instanceof Error ? error.message : 'Recording failed. Please try again.'; }
        render();
    };
    // Pointer actions should never strand keyboard focus on a control that
    // suppresses Unreal's document-level keyboard handlers. Keyboard activation
    // retains normal tab navigation while choosing a file or stopping a clip.
    const releasePointerFocus = (event: MouseEvent) => {
        if (event.detail > 0 && (panel.contains(document.activeElement) || document.activeElement === document.body)) {
            options.focusStream();
        }
    };
    choose.addEventListener('click', (event) => {
        const pending = perform(() => recorder.chooseLocation());
        releasePointerFocus(event);
        return pending;
    });
    record.addEventListener('click', (event) => {
        const pending = perform(async () => {
            if (preparing) return;
            const attempt = ++preparation;
            preparing = true;
            render();
            try {
                // Invoke immediately within the Record gesture so the adapter can
                // resume a paused audio sink without changing the user's mute choice.
                await options.beforeRecord?.();
                if (disposed || attempt !== preparation) return;
                preparing = false;
                await recorder.start();
                if (!disposed && attempt === preparation &&
                    (recorder.snapshot.phase === 'starting' || recorder.snapshot.phase === 'recording') &&
                    (panel.contains(document.activeElement) || document.activeElement === document.body)) {
                    options.focusStream();
                }
            } catch (error) {
                if (!disposed && attempt === preparation) throw error;
            } finally {
                if (attempt === preparation) preparing = false;
            }
        });
        releasePointerFocus(event);
        return pending;
    });
    stop.addEventListener('click', (event) => {
        const pending = preparing ? (cancelPreparation(), Promise.resolve()) : perform(() => recorder.stop());
        releasePointerFocus(event);
        return pending;
    });
    stay.addEventListener('click', () => { finishLeave(false); dialog.close(); });
    leave.addEventListener('click', () => { finishLeave(true); dialog.close(); });
    dialog.addEventListener('cancel', () => {
        if (resolveLeave) finishLeave(false);
    });
    dialog.addEventListener('close', () => {
        // Native close events are queued; a new request may already be open.
        if (dialog.open) return;
        if (resolveLeave) finishLeave(false);
        if (inputCaptured) {
            inputCaptured = false;
            options.setModalInput(false);
        }
        // Let the browser restore the previous focus, including an underlying
        // End session dialog. Never focus a recording toolbar control here.
    });
    // Inline controls isolate their own events, without disabling stream input.
    // The exceptional leave dialog also suspends capture-phase Unreal listeners.
    for (const name of ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup', 'click', 'wheel']) {
        dialog.addEventListener(name, (event) => event.stopPropagation());
        panel.addEventListener(name, (event) => event.stopPropagation());
    }
    const pageHide = () => {
        if (recorder.hasUnsavedData) void recorder.stop('The page was closed.').catch((): void => {});
    };
    window.addEventListener('pagehide', pageHide);
    const unsubscribe = recorder.subscribe(render);
    const timer = window.setInterval(render, 1000);
    render();

    return {
        refresh: () => { if (!disposed) { recorder.sourceChanged(); render(); } },
        beforeLeave: (): Promise<boolean> => {
            cancelPreparation();
            if (disposed) return Promise.resolve(false);
            if (allowLeave) return Promise.resolve(true);
            if (leaveRequest) return leaveRequest;
            leaveRequest = (async () => {
                let saved = false;
                try { saved = await recorder.stop('Finishing recording before leaving.'); }
                catch { /* Keep the page available until the user decides. */ }
                if (disposed) return false;
                if (saved) return true;
                return new Promise<boolean>((resolve) => {
                    resolveLeave = resolve;
                    leaveWarning.style.display = 'block';
                    openDialog();
                    render();
                    stay.focus();
                });
            })().finally(() => { leaveRequest = null; });
            return leaveRequest;
        },
        dispose: () => {
            if (disposed) return;
            disposed = true;
            cancelPreparation();
            finishLeave(false);
            unsubscribe();
            window.clearInterval(timer);
            window.removeEventListener('pagehide', pageHide);
            window.removeEventListener('beforeunload', beforeUnload);
            if (inputCaptured) { inputCaptured = false; options.setModalInput(false); }
            void recorder.dispose().catch((): void => {});
            dialog.remove();
            style.remove();
            panel.remove();
            badge.remove();
        }
    };
}
