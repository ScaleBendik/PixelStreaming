/**
 * Real Chrome/Edge regression for inline recording controls and Unreal keyboard
 * routing. Uses production settings, styles and KeyboardController with a fake
 * recorder; media/file preservation is covered by browser-av1-recording.mjs.
 * Run with pinned Node from repo root. Set PLAYWRIGHT_MODULE_PATH if necessary;
 * RECORDING_BROWSER=chrome|edge optionally limits the browsers. No server starts.
 */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ts = require('typescript');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH || 'playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const output = path.join(root, '.review-tmp/recording-settings');
await mkdir(output, { recursive: true });
const compile = async file => ts.transpileModule(await readFile(path.join(root, file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, esModuleInterop: true }
}).outputText;
const files = {
    control: 'Frontend/implementations/typescript/src/recordingControl.ts',
    mp4: 'Frontend/implementations/typescript/src/recordingMp4Control.ts',
    smoothing: 'Frontend/implementations/typescript/src/cameraSmoothing.ts',
    settings: 'Frontend/ui-library/src/UI/SettingsPanel.ts',
    sections: 'Frontend/ui-library/src/Config/ConfigUI.ts',
    uiConfiguration: 'Frontend/ui-library/src/UI/UIConfigurationTypes.ts',
    keyboard: 'Frontend/library/src/Inputs/KeyboardController.ts',
    keys: 'Frontend/library/src/Inputs/SpecialKeyCodes.ts',
    codes: 'Frontend/library/src/Inputs/KeyCodes.ts'
};
const sources = Object.fromEntries(await Promise.all(Object.entries(files).map(async ([name, file]) => [name, await compile(file)])));
const styleExports = {};
new Function('exports', 'require', await compile('Frontend/ui-library/src/Styles/PixelStreamingApplicationStyles.ts'))(styleExports, require);
const style = new styleExports.PixelStreamingApplicationStyle();
const css = require('jss').default.createStyleSheet({ '@global': style.defaultStyles }).toString();
const browsers = {
    chrome: process.env.CHROME_EXECUTABLE || 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    edge: process.env.EDGE_EXECUTABLE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
};
assert.ok(!process.env.RECORDING_BROWSER || browsers[process.env.RECORDING_BROWSER], 'Unsupported RECORDING_BROWSER');

for (const [name, executablePath] of Object.entries(browsers)) {
    if (process.env.RECORDING_BROWSER && process.env.RECORDING_BROWSER !== name) continue;
    const browser = await chromium.launch({ executablePath, headless: true });
    try {
        for (const [layout, viewport, light] of [
            ['desktop', { width: 1366, height: 900 }, false],
            ['compact', { width: 480, height: 700 }, false],
            ['light', { width: 1366, height: 900 }, true]
        ]) {
            const page = await browser.newPage({ viewport });
            const errors = [];
            page.on('pageerror', error => errors.push(error.message));
            await page.setContent(`<html><head><style>${css}
                html,body{height:100%;margin:0;font-family:system-ui}
                #videoElementParent{background:linear-gradient(140deg,#31505a,#14242f 65%)}
                </style></head><body><div id="playerUI"><div id="videoElementParent" tabindex="-1"></div>
                <div id="uiFeatures"><div id="controls"><button id="settingsBtn" aria-label="Settings">⚙</button></div></div>
                </div></body></html>`);
            await page.evaluate(({ sources, palette }) => {
                const load = (code, require = () => ({})) => {
                    const result = {};
                    new Function('exports', 'require', code)(result, require);
                    return result;
                };
                for (const [key, value] of Object.entries(palette)) document.documentElement.style.setProperty(key, value);
                const settings = new (load(sources.settings).SettingsPanel)();
                document.getElementById('uiFeatures').append(settings.rootElement);
                const { ConfigUI } = load(sources.sections, () => load(sources.uiConfiguration));
                const configUI = Object.create(ConfigUI.prototype);
                for (const title of ['Pixel Streaming', 'UI', 'Input', 'Encoder', 'WebRTC', 'Commands']) {
                    const body = configUI.buildSectionWithHeading(settings.settingsContentElement, title);
                    body.textContent = `${title} settings`;
                }
                const settingsSection = configUI.buildSectionWithHeading(settings.settingsContentElement,
                    'Recording', settings.settingsContentElement.children.item(1));
                document.getElementById('settingsBtn').onclick = () => settings.toggleVisibility();
                settings.settingsCloseButton.onclick = () => settings.hide();
                window.keysSent = [];
                const { KeyboardController } = load(sources.keyboard, name => {
                    if (name === './SpecialKeyCodes') return load(sources.keys);
                    if (name === './KeyCodes') return load(sources.codes);
                    return { Flags: { SuppressBrowserKeys: 'suppress' } };
                });
                const keyboard = new KeyboardController({ toStreamerHandlers: new Map([
                    ['KeyDown', values => window.keysSent.push(values[0])]
                ]) }, { isFlagEnabled: () => true }, { getActiveKeys: () => [] });
                keyboard.register();
                class Recorder {
                    snapshot = { phase: 'idle', filename: '', bytesWritten: 0, startedAt: null, message: '' };
                    listeners = new Set();
                    constructor() { window.recorder = this; }
                    get hasUnsavedData() { return ['starting', 'recording', 'saving'].includes(this.snapshot.phase); }
                    state(phase, extra = {}) {
                        this.snapshot = { ...this.snapshot, phase, message: '', ...extra };
                        this.listeners.forEach(listener => listener());
                    }
                    subscribe(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
                    async chooseLocation() {
                        this.state('choosing');
                        await Promise.resolve();
                        this.state('ready', { filename: 'ScaleWorld-demo-session-2026-10-21.webm' });
                    }
                    async start() { this.state('recording', { startedAt: Date.now() - 43000, bytesWritten: 28 * 1024 * 1024 }); }
                    async stop() {
                        if (this.snapshot.phase === 'error') return false;
                        if (!this.hasUnsavedData) return true;
                        this.state('saving');
                        return new Promise(resolve => { this.finish = success => { this.state(success ? 'saved' : 'error'); resolve(success); }; });
                    }
                    sourceChanged() {}
                    async dispose() {}
                }
                const { installRecordingControl } = load(sources.control, name => name === './recordingMp4Control' ? load(sources.mp4, () => ({ Mp4ExportController: class {
                    snapshot = { phase: 'idle', percent: 0, message: '', filename: '' }; busy = false;
                    reset() {} wait() { return Promise.resolve(); } dispose() {}
                } })) : ({
                    LocalRecordingController: Recorder, getRecordingSupport: () => ({ supported: true, reason: '' }),
                    getRecordingFormat: () => ({ codec: 'AV1', extension: '.webm' })
                }));
                const recordingSource = { connection: {}, videoTrack: { readyState: 'live' }, codec: 'AV1', eligible: true };
                window.ui = installRecordingControl({ settingsSection,
                    statusAnchor: document.getElementById('settingsBtn'),
                    modalParent: document.getElementById('videoElementParent'),
                    closeSettings: () => settings.hide(),
                    openSettings: () => settings.show(),
                    focusStream: () => document.getElementById('videoElementParent').focus({ preventScroll: true }),
                    getSource: () => recordingSource,
                    setModalInput: open => { if (open) keyboard.unregister(); else keyboard.register(); }
                });
                window.settings = settings;
                const cameraEvents = new Map();
                let cameraResponse;
                window.cameraConnected = true;
                window.cameraMessages = [];
                window.cameraSendMode = 'normal';
                window.cameraRespond = (enabled, requestId = window.cameraMessages.at(-1)?.requestId) =>
                    cameraResponse(JSON.stringify({ type: 'CameraSmoothing.State', enabled, requestId }));
                window.cameraBroadcast = enabled => cameraResponse(JSON.stringify({ type: 'CameraSmoothing.State', enabled }));
                window.cameraEvent = name => cameraEvents.get(name)?.();
                window.cameraControl = load(sources.smoothing).installCameraSmoothingControl({
                    parent: settingsSection,
                    focusStream: () => document.getElementById('videoElementParent').focus({ preventScroll: true }),
                    stream: {
                        webRtcController: { isDataChannelOpen: () => window.cameraConnected },
                        emitUIInteraction(message) {
                            window.cameraMessages.push(message);
                            if (window.cameraSendMode === 'throw') throw new Error('Simulated transport failure');
                            return true;
                        },
                        addResponseEventListener(_name, listener) { cameraResponse = listener; },
                        removeResponseEventListener() {},
                        addEventListener(name, listener) { cameraEvents.set(name, listener); },
                        removeEventListener(name) { cameraEvents.delete(name); }
                    }
                });
            }, { sources, palette: light ? style.defaultLightModePalette : style.defaultDarkModePalette });

            const shot = async state => page.screenshot({ path: path.join(output, `${name}-${layout}-${state}.png`) });
            await page.locator('#settingsBtn').click();
            assert.deepEqual(await page.locator('#settingsContent .settingsSectionLabel').allTextContents(),
                ['Pixel Streaming', 'Recording', 'UI', 'Input', 'Encoder', 'WebRTC', 'Commands']);
            for (const title of ['Pixel Streaming', 'Recording', 'UI', 'Input', 'Encoder', 'WebRTC', 'Commands']) {
                const header = page.getByRole('button', { name: title, exact: true });
                const body = header.locator('..').locator('.settingsSectionBody');
                const expanded = title === 'Pixel Streaming';
                assert.equal(await header.getAttribute('aria-expanded'), String(expanded), `${title} default state`);
                assert.equal(await body.isVisible(), expanded, `${title} content visibility`);
                await header.click();
                assert.equal(await body.isVisible(), !expanded, `${title} pointer toggle`);
                await header.press('Enter');
                assert.equal(await body.isVisible(), expanded, `${title} Enter toggle`);
                await header.press('Space');
                assert.equal(await body.isVisible(), !expanded, `${title} Space toggle`);
                await header.click();
            }
            // Closing Settings preserves the categories the user has opened.
            await page.getByRole('button', { name: 'UI', exact: true }).click();
            await page.locator('#settingsClose').click();
            await page.locator('#settingsBtn').click();
            assert.equal(await page.getByRole('button', { name: 'UI', exact: true }).getAttribute('aria-expanded'), 'true');
            await page.getByRole('button', { name: 'UI', exact: true }).click();
            await page.getByRole('button', { name: 'Recording', exact: true }).click();
            const smoothing = page.getByRole('checkbox', { name: 'Smooth camera movement' });
            assert.equal(await smoothing.isDisabled(), true, 'unknown state cannot send a default');
            assert.equal(await smoothing.evaluate(node => node.indeterminate), true);
            await page.evaluate(() => window.cameraRespond(true));
            assert.equal(await smoothing.isChecked(), true, 'initial state comes from Unreal');
            await shot('camera-ready');
            await smoothing.click();
            assert.equal(await page.evaluate(() => document.activeElement.id), 'videoElementParent', 'pointer changes return focus to the stream');
            await page.evaluate(() => { window.keysSent = []; });
            await page.keyboard.press('w');
            assert.deepEqual(await page.evaluate(() => window.keysSent), [87], 'Unreal keyboard input remains usable while awaiting acknowledgement');
            assert.equal(await smoothing.isDisabled(), true);
            assert.equal(await smoothing.isChecked(), true, 'pending Set retains the confirmed value');
            assert.equal(await page.evaluate(() => window.cameraMessages.at(-1).enabled), false);
            await page.evaluate(() => window.cameraRespond(false));
            assert.equal(await smoothing.isChecked(), false);
            await page.evaluate(() => window.cameraBroadcast(true));
            assert.equal(await smoothing.isChecked(), true, 'Unreal widget updates the checkbox');
            await smoothing.focus();
            await page.evaluate(() => { window.keysSent = []; });
            await page.keyboard.press('Space');
            assert.deepEqual(await page.evaluate(() => window.keysSent), [], 'checkbox activation must not move the Unreal camera');
            await page.evaluate(() => window.cameraRespond(false));
            assert.equal(await smoothing.isChecked(), false, 'checkbox supports keyboard activation');
            await page.evaluate(() => { window.cameraConnected = false; window.cameraEvent('webRtcDisconnected'); });
            assert.equal(await smoothing.isDisabled(), true);
            assert.equal(await smoothing.evaluate(node => node.indeterminate), true);
            await page.evaluate(() => { window.cameraConnected = true; window.cameraEvent('dataChannelOpen'); window.cameraRespond(true); });
            assert.equal(await smoothing.isChecked(), true);
            await page.evaluate(() => { window.cameraSendMode = 'throw'; });
            await smoothing.click();
            assert.equal(await smoothing.isDisabled(), true);
            if (layout === 'desktop') {
                await page.waitForFunction(() => document.getElementById('cameraSmoothingRetry').hidden === false, undefined, { timeout: 10000 });
                assert.match(await page.locator('#cameraSmoothingStatus').textContent(), /Recording still works/);
            }
            await page.locator('#recordingChoose').scrollIntoViewIfNeeded();
            assert.equal(await page.locator('#recordingBtn').count(), 0);
            assert.equal(await page.locator('dialog[open]').count(), 0);
            const dimensions = await page.locator('#recordingSettings').evaluate(node => ({
                width: node.scrollWidth, client: node.clientWidth, right: node.getBoundingClientRect().right,
                left: node.getBoundingClientRect().left
            }));
            assert.equal(dimensions.width, dimensions.client, 'No horizontal overflow');
            assert.ok(dimensions.left >= 0 && dimensions.right <= viewport.width, 'Controls inside viewport');
            await shot('ready');
            await page.locator('#recordingChoose').click();
            await page.locator('#recordingStart').click();
            await page.locator('#recordingCountdown').waitFor({ state: 'visible' });
            await shot('countdown');
            await page.waitForFunction(() => window.recorder.snapshot.phase === 'recording');
            await page.waitForFunction(() => document.activeElement.id === 'videoElementParent' &&
                !document.getElementById('settings-panel').classList.contains('panel-wrap-visible'));
            await page.keyboard.press('w');
            assert.equal(await page.evaluate(() => window.keysSent.at(-1)), 87, 'W reaches Unreal after Record');
            await page.keyboard.press('a');
            assert.equal(await page.evaluate(() => window.keysSent.at(-1)), 65, 'A reaches Unreal with settings closed');
            await shot('recording');
            await page.locator('#recordingQuickStop').click();
            await page.keyboard.press('s');
            assert.equal(await page.evaluate(() => window.keysSent.at(-1)), 83, 'S reaches Unreal after Stop');
            await shot('saving');
            await page.evaluate(() => window.recorder.finish(true));
            assert.equal(await page.locator('#recordingBadge').textContent(), 'Saved');
            await page.locator('#settingsBtn').click();
            if (layout === 'desktop') {
                await page.evaluate(() => { window.cameraSendMode = 'normal'; });
                await page.locator('#cameraSmoothingRetry').click();
                await page.evaluate(() => window.cameraRespond(false));
                assert.equal(await smoothing.isDisabled(), false, 'Retry recovers without reconnecting the stream');
            }

            // Native keyboard activation must remain accessible and must not
            // send the control's Enter key to Unreal or leave focus on Record.
            await page.locator('#recordingChoose').focus();
            await page.evaluate(() => { window.keysSent = []; });
            await page.keyboard.press('Enter');
            await page.keyboard.press('Tab');
            assert.equal(await page.evaluate(() => document.activeElement.id), 'recordingStart');
            await page.keyboard.press('Enter');
            await page.waitForFunction(() => document.activeElement.id === 'videoElementParent' &&
                !document.getElementById('settings-panel').classList.contains('panel-wrap-visible'));
            assert.deepEqual(await page.evaluate(() => window.keysSent), []);
            await page.keyboard.press('d');
            assert.equal(await page.evaluate(() => window.keysSent.at(-1)), 68);
            await page.waitForFunction(() => window.recorder.snapshot.phase === 'recording');

            await page.evaluate(() => {
                const ended = document.createElement('dialog');
                ended.innerHTML = '<button>Return to servers</button>';
                document.body.append(ended);
                ended.showModal();
                window.recorder.state('error', { message: 'Disk full.' });
                window.ui.beforeLeave().then(value => { window.leaveDecision = value; });
            });
            await page.locator('#recordingStay').click();
            await page.waitForFunction(() => window.leaveDecision === false);
            assert.equal(await page.locator('#recordingLeaveDialog').evaluate(node => node.open), false);
            assert.ok(await page.evaluate(() => document.activeElement.closest('dialog') !== null), 'Underlying session dialog regains focus');
            assert.deepEqual(errors, []);
            await page.evaluate(() => { window.cameraControl.dispose(); window.ui.dispose(); });
            await page.close();
            console.log(JSON.stringify({ browser: name, version: browser.version(), layout, cameraSmoothing: 'passed', settingsCategories: 'passed', keyboardRouting: 'passed', inlineControls: 'passed', failedSave: 'passed' }));
        }
    } finally { await browser.close(); }
}
