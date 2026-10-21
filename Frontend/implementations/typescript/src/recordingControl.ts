import { getRecordingFormat, getRecordingSupport, LocalRecordingController, RecordingSnapshot, RecordingSource } from './localRecording';

export type RecordingControlOptions = {
    controls: HTMLElement;
    modalParent: HTMLElement;
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
    let reopeningDialog = false;
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

    const button = document.createElement('button');
    button.type = 'button';
    button.id = 'recordingBtn';
    button.className = 'UiTool';
    button.title = 'Record video';
    button.setAttribute('aria-label', 'Record video');
    button.setAttribute('aria-haspopup', 'dialog');
    button.style.cssText = 'position:relative;overflow:visible';
    button.innerHTML = '<svg viewBox="0 0 32 32" width="100%" height="100%" aria-hidden="true"><rect x="4" y="8" width="17" height="16" rx="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M21 13l7-4v14l-7-4z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12.5" cy="16" r="3.5" fill="currentColor"/></svg>';
    const badge = document.createElement('span');
    badge.id = 'recordingBadge';
    badge.setAttribute('aria-hidden', 'true');
    badge.style.cssText = 'display:none;position:absolute;left:calc(100% + 8px);top:50%;transform:translateY(-50%);width:max-content;pointer-events:none;padding:4px 8px;border-radius:5px;background:#20262e;color:#fff;font:12px/1.4 system-ui;text-transform:none;box-shadow:0 2px 8px #0008';
    button.appendChild(badge);
    options.controls.appendChild(button);

    const dialog = document.createElement('dialog');
    dialog.id = 'recordingDialog';
    dialog.setAttribute('aria-labelledby', 'stream-recording-title');
    dialog.style.cssText = 'width:min(490px,calc(100vw - 40px));max-height:calc(100vh - 40px);overflow:auto;box-sizing:border-box;padding:26px;border:1px solid #59616b;border-radius:14px;background:#20262e;color:#fff;font:16px/1.5 system-ui;text-transform:none;box-shadow:0 20px 80px #0009';
    const style = document.createElement('style');
    style.textContent = '#recordingDialog::backdrop{background:#0009}#recordingDialog button{font:inherit;border-radius:7px;padding:9px 14px;cursor:pointer;border:1px solid #8793a0;background:transparent;color:#fff}' +
        '#recordingDialog button:focus-visible,#recordingBtn:focus-visible{outline:3px solid #8bd0ff;outline-offset:3px}' +
        '#recordingDialog button:disabled{opacity:.5;cursor:not-allowed}';
    const title = document.createElement('h2');
    title.id = 'stream-recording-title';
    title.textContent = 'Record video';
    title.style.cssText = 'margin:0 0 12px;font-size:23px;color:inherit;text-transform:none';
    const description = document.createElement('p');
    description.textContent = 'Save this session’s video and available audio to a video file on your device. Choose a location, record, then stop to finish saving.';
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
    notice.textContent = 'Keep this tab open until Saved appears. Closing the tab or browser before saving can lose the recording.';
    notice.style.cssText = 'font-size:13px;color:#bbc4ce';
    const actions = document.createElement('div');
    actions.style.cssText = 'display:flex;flex-wrap:wrap;gap:10px;justify-content:flex-end;margin-top:22px';
    const action = (id: string, label: string) => {
        const element = document.createElement('button');
        element.type = 'button';
        element.id = id;
        element.textContent = label;
        return element;
    };
    const choose = action('recordingChoose', 'Choose location');
    const record = action('recordingStart', 'Record');
    record.style.cssText = 'background:#b9363e;border-color:#b9363e';
    const stop = action('recordingStop', 'Stop');
    const close = action('recordingClose', 'Close');
    actions.append(choose, record, stop, close);
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
    dialog.append(title, description, filename, format, details, status, notice, actions, leaveWarning);
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
        stop.disabled = !active || !!resolveLeave;
        close.disabled = snapshot.phase === 'choosing';
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
        status.style.color = localError || snapshot.phase === 'error' ? '#ffb8b8' : '#d8e0e8';
        const badgeText = preparing ? 'Starting…' : active ? `${snapshot.phase === 'starting' ? 'Starting' : '● REC'} ${frozenElapsed}` :
            snapshot.phase === 'saving' ? 'Saving…' : snapshot.phase === 'saved' ? 'Saved' : snapshot.phase === 'error' ? 'Not saved' : '';
        badge.textContent = badgeText;
        badge.style.display = badgeText ? 'block' : 'none';
        badge.style.color = active || snapshot.phase === 'error' ? '#ffb8b8' : '#fff';
        button.title = badgeText ? `Recording: ${badgeText}` : 'Record video';
        button.setAttribute('aria-label', button.title);
        syncUnload();
    };
    const cancelPreparation = () => {
        if (!preparing) return;
        preparation++;
        preparing = false;
        render();
    };
    const openDialog = (promote = false) => {
        if (disposed || (dialog.open && !promote)) return;
        // An end-session dialog may have opened above this one. Re-enter the
        // modal top layer so the save-failure decision remains accessible.
        if (dialog.open) {
            reopeningDialog = true;
            dialog.close();
        }
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
        finally { reopeningDialog = false; }
        render();
        if (resolveLeave) stay.focus();
        else if (!stop.disabled) stop.focus();
        else if (!choose.disabled) choose.focus();
        else close.focus();
    };
    const finishLeave = (approved: boolean) => {
        const resolve = resolveLeave;
        resolveLeave = null;
        leaveWarning.style.display = 'none';
        actions.style.display = 'flex';
        allowLeave = approved;
        syncUnload();
        resolve?.(approved);
    };
    const perform = async (operation: () => Promise<unknown>) => {
        localError = '';
        try { await operation(); }
        catch (error) { localError = error instanceof Error ? error.message : 'Recording failed. Please try again.'; }
        render();
    };
    button.addEventListener('click', (event) => { event.stopPropagation(); openDialog(); });
    choose.addEventListener('click', () => perform(() => recorder.chooseLocation()));
    record.addEventListener('click', () => perform(async () => {
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
            if (recorder.snapshot.phase === 'starting' || recorder.snapshot.phase === 'recording') dialog.close();
        } catch (error) {
            if (!disposed && attempt === preparation) throw error;
        } finally {
            if (attempt === preparation) preparing = false;
        }
    }));
    stop.addEventListener('click', () => perform(() => recorder.stop()));
    close.addEventListener('click', () => { if (!close.disabled) { cancelPreparation(); dialog.close(); } });
    stay.addEventListener('click', () => { finishLeave(false); dialog.close(); });
    leave.addEventListener('click', () => { finishLeave(true); dialog.close(); });
    dialog.addEventListener('cancel', (event) => {
        if (recorder.snapshot.phase === 'choosing') event.preventDefault();
        else {
            cancelPreparation();
            if (resolveLeave) finishLeave(false);
        }
    });
    dialog.addEventListener('close', () => {
        // Native close events are queued; ignore an older close if the dialog
        // has already reopened, and preserve the input lease while promoting.
        if (reopeningDialog || dialog.open) return;
        cancelPreparation();
        if (resolveLeave) finishLeave(false);
        if (inputCaptured) {
            inputCaptured = false;
            options.setModalInput(false);
        }
        button.focus();
    });
    // The input suspension also covers capture-phase Unreal listeners; stop
    // bubbling so dialog keystrokes and clicks cannot reach player shortcuts.
    for (const name of ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup', 'click', 'wheel']) {
        dialog.addEventListener(name, (event) => event.stopPropagation());
    }
    for (const name of ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup']) {
        button.addEventListener(name, (event) => event.stopPropagation());
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
                    actions.style.display = 'none';
                    openDialog(true);
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
            button.remove();
        }
    };
}
