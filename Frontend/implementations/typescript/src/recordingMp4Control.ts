import { LocalRecordingController, RecordingFileHandle, RecordingFilePickerOptions } from './localRecording';
import { Mp4ExportController, RecordingFolder } from './mp4Export';

export function installMp4RecordingExport(options: {
    recorder: LocalRecordingController;
    parent: HTMLElement;
    openSettings: () => void;
    onChange: () => void;
    focusStream: () => void;
}) {
    let disposed = false;
    let folder: RecordingFolder | null = null;
    let selected: RecordingFileHandle | null = null;
    let attempted: RecordingFileHandle | null = null;
    let videoUrl: string | null = null;
    let picking = false;
    let preparing = false;
    let manualTask: Promise<void> | null = null;
    let pickerError = '';
    let manualOutput = false;
    const root = document.createElement('div');
    root.id = 'recordingMp4';
    const label = document.createElement('label');
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox'; checkbox.checked = false; checkbox.id = 'recordingConvertMp4';
    label.htmlFor = checkbox.id;
    label.append(checkbox, document.createTextNode(' convert to MP4 after recording'));
    const warning = document.createElement('p');
    warning.textContent = 'this starts an automatic conversion to the more accessible MP4 format after recording. this process may take some time';
    warning.style.cssText = 'font-size:12px;opacity:.8';
    const folderNotice = document.createElement('p');
    folderNotice.textContent = 'Automatic conversion requires folder write access. Choose a dedicated folder. For single-file saving, leave this off and convert the previous recording afterwards.';
    folderNotice.style.cssText = 'font-size:12px;opacity:.8';
    const progress = document.createElement('progress');
    progress.id = 'recordingMp4Progress'; progress.max = 100; progress.value = 0;
    progress.setAttribute('aria-label', 'MP4 conversion progress');
    progress.style.cssText = 'width:100%;display:none';
    const status = document.createElement('p');
    status.id = 'recordingMp4Status'; status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
    const location = document.createElement('p');
    location.id = 'recordingMp4Location'; location.style.cssText = 'font-size:12px;overflow-wrap:anywhere';
    const actions = document.createElement('div');
    actions.style.cssText = 'display:flex;gap:8px;flex-wrap:wrap';
    const button = (id: string, text: string) => {
        const b = document.createElement('button'); b.type = 'button'; b.id = id; b.textContent = text; return b;
    };
    const cancel = button('recordingMp4Cancel', 'Cancel conversion');
    const retry = button('recordingMp4Retry', 'Retry MP4 conversion');
    const previous = button('recordingMp4Previous', 'Convert previous recording to MP4');
    const open = document.createElement('a');
    open.id = 'recordingMp4Open'; open.textContent = 'Open video'; open.target = '_blank'; open.rel = 'noopener';
    open.style.cssText = 'display:none;color:inherit;text-decoration:underline;padding:8px 0';
    actions.append(previous, cancel, retry, open);
    root.append(label, warning, folderNotice, progress, status, location, actions);
    options.parent.appendChild(root);
    const exporter = new Mp4ExportController(() => { render(); options.onChange(); });
    function render() {
        if (disposed) return;
        const snapshot = exporter.snapshot;
        checkbox.disabled = preparing || picking || exporter.busy || ['choosing', 'starting', 'recording', 'saving'].includes(options.recorder.snapshot.phase);
        previous.disabled = checkbox.disabled || !options.recorder.savedFile?.getFile;
        folderNotice.hidden = !checkbox.checked;
        progress.style.display = exporter.busy || snapshot.phase === 'saved' ? 'block' : 'none';
        progress.value = snapshot.percent;
        status.textContent = pickerError || snapshot.message;
        location.textContent = manualOutput ? `MP4: ${snapshot.filename}. The original recording remains at its original location.` :
            folder ? `Folder: ${folder.name}${snapshot.filename ? ` · ${snapshot.filename}` : ''}. The original recording is kept here too.` : '';
        cancel.style.display = exporter.busy ? '' : 'none';
        retry.style.display = !manualOutput && ['error', 'cancelled'].includes(snapshot.phase) && selected && folder ? '' : 'none';
        retry.disabled = options.recorder.hasUnsavedData;
        open.style.display = snapshot.phase === 'saved' && videoUrl ? '' : 'none';
    }
    const start = async (source = selected, target: Parameters<Mp4ExportController['start']>[1] | null = folder) => {
        if (!source || !target || exporter.busy || disposed) return;
        pickerError = '';
        manualOutput = !('getFileHandle' in target);
        if (videoUrl) { URL.revokeObjectURL(videoUrl); videoUrl = null; }
        options.openSettings();
        await exporter.start(source, target);
        if (disposed) return;
        const saved = exporter.savedFile;
        if (saved?.getFile) {
            try {
                const file = await saved.getFile();
                if (disposed) return;
                videoUrl = URL.createObjectURL(file); open.href = videoUrl;
            } catch { /* The saved file remains available in the chosen folder. */ }
        }
        render();
    };
    const resetExport = () => {
        pickerError = '';
        manualOutput = false;
        if (videoUrl) { URL.revokeObjectURL(videoUrl); videoUrl = null; }
        exporter.reset();
    };
    const unsubscribe = options.recorder.subscribe(() => {
        if (disposed) return;
        const saved = options.recorder.savedFile;
        if (checkbox.checked && folder && saved && saved === selected && saved !== attempted && options.recorder.snapshot.phase === 'saved') {
            attempted = saved;
            void start();
        }
        render();
    });
    checkbox.addEventListener('change', () => {
        if (checkbox.disabled) return;
        folder = null; selected = null;
        resetExport();
        options.recorder.resetLocation(); render();
    });
    cancel.addEventListener('click', () => exporter.cancel());
    retry.addEventListener('click', () => { void start(); });
    previous.addEventListener('click', () => {
        const source = options.recorder.savedFile;
        if (previous.disabled || !source?.getFile || disposed) return;
        picking = true; pickerError = ''; render(); options.onChange();
        // Invoke the native picker directly from this user gesture, before any await.
        manualTask = (async () => {
            try {
                const browser = window as unknown as { showSaveFilePicker(options: RecordingFilePickerOptions): Promise<RecordingFileHandle> };
                const destination = await browser.showSaveFilePicker({
                    suggestedName: source.name.replace(/\.(webm|mkv)$/i, '') + '.mp4',
                    excludeAcceptAllOption: true,
                    types: [{ description: 'MP4 video', accept: { 'video/mp4': ['.mp4'] } }]
                });
                if (!disposed) await start(source, destination);
            } catch (error) {
                if ((error as DOMException).name !== 'AbortError') pickerError = 'Could not choose an MP4 file. Your original recording is saved.';
            } finally {
                picking = false; manualTask = null;
                if (!disposed) { render(); options.onChange(); }
            }
        })();
    });
    for (const control of [checkbox, cancel, retry, previous]) control.addEventListener('click', event => {
        if ((event as MouseEvent).detail > 0) options.focusStream();
    });
    render();
    return {
        get busy() { return picking || exporter.busy; },
        get enabled() { return checkbox.checked; },
        setPreparing(value: boolean) { preparing = value; render(); },
        wait: () => manualTask ?? exporter.wait(),
        async pickFile(pickerOptions: RecordingFilePickerOptions): Promise<RecordingFileHandle> {
            const browser = window as unknown as {
                showDirectoryPicker(options: { mode: 'readwrite' }): Promise<RecordingFolder>;
                showSaveFilePicker(options: RecordingFilePickerOptions): Promise<RecordingFileHandle>;
            };
            if (!checkbox.checked) {
                const file = await browser.showSaveFilePicker(pickerOptions);
                folder = null; selected = file; resetExport(); return file;
            }
            const chosen = await browser.showDirectoryPicker({ mode: 'readwrite' });
            if (disposed) throw new DOMException('Cancelled', 'AbortError');
            // Automatic sibling files need folder permission. Unique names avoid
            // overwriting another clip without a separate confirmation dialog.
            const name = pickerOptions.suggestedName.replace(/(\.[^.]+)$/, `-${crypto.randomUUID().slice(0, 8)}$1`);
            const file = await chosen.getFileHandle(name, { create: true });
            if (disposed) throw new DOMException('Cancelled', 'AbortError');
            folder = chosen; selected = file; attempted = null;
            resetExport();
            return file;
        },
        dispose() {
            disposed = true; unsubscribe(); exporter.dispose();
            if (videoUrl) URL.revokeObjectURL(videoUrl);
            root.remove();
        }
    };
}
