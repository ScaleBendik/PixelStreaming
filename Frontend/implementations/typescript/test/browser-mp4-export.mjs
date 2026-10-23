/** Local Chrome/Edge MP4 worker proof. Uses the saved fixtures from
 * browser-av1-recording.mjs, OPFS file handles, and the production export worker.
 * No hosted services or media uploads. All servers/browsers are closed on exit.
 */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const evidence = path.join(root, '.review-tmp/mp4-proof');
await mkdir(evidence, { recursive: true });
const entry = path.join(evidence, 'entry.ts');
await writeFile(entry, `export { Mp4ExportController } from '../../Frontend/implementations/typescript/src/mp4Export';
export { installMp4RecordingExport } from '../../Frontend/implementations/typescript/src/recordingMp4Control';
export { convertRecordingToMp4 } from '../../Frontend/implementations/typescript/src/mp4Conversion';
export { Input, BlobSource, MP4, MATROSKA, WEBM, EncodedPacketSink, AudioSampleSink, VideoSampleSink } from 'mediabunny';`);
const webpack = require('webpack');
const compiler = webpack({ mode: 'development', entry, devtool: false,
    output: { path: path.join(evidence, 'dist'), filename: 'entry.js', chunkFilename: '[name].[contenthash].js', library: { name: 'mp4Proof', type: 'umd' }, globalObject: 'this' , clean: true },
    resolve: { extensions: ['.ts', '.js'] },
    module: { rules: [{ test: /\.ts$/, exclude: /node_modules/, loader: require.resolve('ts-loader'), options: {
        configFile: path.join(root, 'Frontend/implementations/typescript/tsconfig.esm.json')
    } }] }
});
try {
    await new Promise((resolve, reject) => compiler.run((error, stats) => error || stats.hasErrors()
        ? reject(error || Error(stats.toString({ all: false, errors: true }))) : resolve()));
} finally { await new Promise(resolve => compiler.close(resolve)); }
const server = createServer(async (req, res) => {
    try {
        const url = new URL(req.url, 'http://localhost');
        if (url.pathname === '/') { res.end('<html><body><script src="/entry.js"></script></body></html>'); return; }
        const filename = path.basename(url.pathname);
        const file = filename.endsWith('.js') ? path.join(evidence, 'dist', filename) : path.join(root, '.review-tmp/recording-proof', filename);
        res.setHeader('Content-Type', filename.endsWith('.js') ? 'text/javascript' : 'application/octet-stream');
        res.end(await readFile(file));
    } catch { res.statusCode = 404; res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH || 'playwright');
const summaries = [];
try {
    for (const [browserName, executablePath] of Object.entries({
        chrome: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
        edge: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
    })) {
        if (process.env.RECORDING_BROWSER && process.env.RECORDING_BROWSER !== browserName) continue;
        const browser = await chromium.launch({ executablePath, headless: true, args: ['--autoplay-policy=no-user-gesture-required'] });
        try {
            const page = await browser.newPage();
            const external = [], errors = [];
            page.on('request', request => { if (!request.url().startsWith(base) && !request.url().startsWith('blob:')) external.push(request.url()); });
            page.on('pageerror', error => errors.push(error.message));
            await page.goto(base);
            for (const codec of ['H264', 'AV1', 'VP9']) {
                const result = await page.evaluate(async ({ codec, browserName }) => {
                    const { Mp4ExportController, Input, BlobSource, MP4, MATROSKA, WEBM, EncodedPacketSink, AudioSampleSink, VideoSampleSink } = window.mp4Proof;
                    const directory = await navigator.storage.getDirectory();
                    const name = `${browserName}-${codec}.${codec === 'H264' ? 'mkv' : 'webm'}`;
                    const source = await directory.getFileHandle(name, { create: true });
                    const writer = await source.createWritable(); await writer.write(await (await fetch('/' + name)).blob()); await writer.close();
                    const original = await source.getFile();
                    const states = [];
                    const exporter = new Mp4ExportController(() => states.push(exporter.snapshot));
                    const start = performance.now();
                    await exporter.start(source, directory);
                    if (exporter.snapshot.phase !== 'saved') {
                        const debugInput = new Input({ source: new BlobSource(original), formats: [MATROSKA, WEBM] });
                        const debugTrack = await debugInput.getPrimaryVideoTrack();
                        const config = await debugTrack.getDecoderConfig();
                        const canDecode = await debugTrack.canDecode();
                        debugInput.dispose();
                        try { await window.mp4Proof.convertRecordingToMp4(original, await directory.getFileHandle('diagnostic.mp4', {create:true}), new AbortController().signal, () => {}); }
                        catch (e) { throw Error(JSON.stringify({ message: e.message, stack:e.stack, config, canDecode })); }
                        throw Error(JSON.stringify(exporter.snapshot));
                    }
                    const file = await exporter.savedFile.getFile();
                    const input = new Input({ source: new BlobSource(file), formats: [MP4] });
                    const video = await input.getPrimaryVideoTrack(), audio = await input.getPrimaryAudioTrack();
                    const hash = async data => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', data))).map(x => x.toString(16).padStart(2, '0')).join('');
                    const packets = async track => {
                        const result = [];
                        const avc = await track.getCodec() === 'avc';
                        const description = (await track.getDecoderConfig())?.description;
                        for await (const packet of new EncodedPacketSink(track).packets()) {
                            if (!avc) { result.push(await hash(packet.data)); continue; }
                            const b = packet.data, nals = [];
                            if (description) {
                                const width = (new Uint8Array(description)[4] & 3) + 1;
                                for (let p = 0; p < b.length;) {
                                    let n = 0; for (let i = 0; i < width; i++) n = n * 256 + b[p++];
                                    nals.push(b.subarray(p, p + n)); p += n;
                                }
                            } else {
                                const starts = [];
                                for (let p = 0; p < b.length - 2; p++) {
                                    if (b[p] === 0 && b[p + 1] === 0 && (b[p + 2] === 1 || b[p + 2] === 0 && b[p + 3] === 1)) {
                                        const width = b[p + 2] === 1 ? 3 : 4; starts.push([p, p + width]); p += width - 1;
                                    }
                                }
                                for (let i = 0; i < starts.length; i++) nals.push(b.subarray(starts[i][1], starts[i + 1]?.[0] ?? b.length));
                            }
                            result.push(await Promise.all(nals.map(hash)));
                        }
                        return result;
                    };
                    const videoPackets = await packets(video);
                    let identicalVideo = null;
                    const sourceInput = new Input({source:new BlobSource(original), formats:[MATROSKA,WEBM]});
                    const timestamps = [];
                    for await(const sample of new VideoSampleSink(await sourceInput.getPrimaryVideoTrack()).samples()) {timestamps.push([sample.timestamp, sample.duration]); sample.close();}
                    const sourcePackets = (await packets(await sourceInput.getPrimaryVideoTrack())).length;
                    sourceInput.dispose();
                    if (codec === 'H264') {
                        const originalInput = new Input({ source: new BlobSource(original), formats: [MATROSKA, WEBM] });
                        identicalVideo = JSON.stringify(videoPackets) === JSON.stringify(await packets(await originalInput.getPrimaryVideoTrack()));
                        originalInput.dispose();
                    }
                    let audioSamples = 0;
                    for await (const sample of new AudioSampleSink(audio).samples()) { audioSamples++; sample.close(); }
                    const player = document.createElement('video'); player.muted = true; player.src = URL.createObjectURL(file); document.body.append(player);
                    await new Promise((resolve, reject) => { player.onloadedmetadata = resolve; player.onerror = reject; });
                    const duration = player.duration;
                    await new Promise((resolve, reject) => { player.onseeked = resolve; player.onerror = reject; player.currentTime = 2; });
                    const currentTime = player.currentTime;
                    await player.play(); await new Promise(resolve => setTimeout(resolve, 200));
                    const decodedFrames = player.getVideoPlaybackQuality().totalVideoFrames;
                    player.pause(); URL.revokeObjectURL(player.src); player.remove();
                    const result = { codec, browserName, bytes: file.size, videoCodec: await video.getCodec(), audioCodec: await audio.getCodec(),
                        duration, currentTime, decodedFrames, audioSamples, videoPackets: videoPackets.length, identicalVideo,
                        sourceDecodedFrames:timestamps.length, sourcePackets, sourceFrameBounds:[timestamps[0],timestamps.at(-1)], originalUnchanged: await hash(await original.arrayBuffer()) === await hash(await (await source.getFile()).arrayBuffer()),
                        progress: states.filter(s => s.phase === 'converting').map(s => s.percent), elapsedMs: performance.now() - start };
                    input.dispose(); exporter.dispose(); return result;
                }, { codec, browserName });
                assert.equal(result.videoCodec, 'avc'); assert.equal(result.audioCodec, 'aac');
                assert.ok(result.duration > 3 && result.duration < 6); assert.equal(result.currentTime, 2);
                assert.ok(result.decodedFrames > 0); assert.ok(result.audioSamples > 0); assert.ok(result.videoPackets > 10);
                assert.equal(result.videoPackets, result.sourceDecodedFrames, "Every decoded source frame is preserved"); assert.equal(result.originalUnchanged, true); if (codec === 'H264') assert.equal(result.identicalVideo, true);
                assert.ok(result.progress.length > 1); summaries.push(result); console.log(JSON.stringify(result));
            }
            const ui = await page.evaluate(async ({ browserName }) => {
                const directory = await navigator.storage.getDirectory();
                const original = await (await directory.getFileHandle(`${browserName}-AV1.webm`)).getFile();
                window.showDirectoryPicker = async () => directory;
                let subscriber, opened = 0;
                const recorder = { snapshot: {phase:'idle'}, savedFile:null, hasUnsavedData:false,
                    subscribe(callback) {subscriber=callback; return () => {};}, resetLocation() {} };
                const parent = document.createElement('div'); document.body.append(parent);
                const control = window.mp4Proof.installMp4RecordingExport({recorder,parent,
                    openSettings:()=>opened++, onChange:()=>{}, focusStream:()=>{}});
                const enabledByDefault = parent.querySelector('input').checked;
                let filePickerCalls = 0;
                window.showSaveFilePicker = async opts => { filePickerCalls++; return directory.getFileHandle(opts.suggestedName,{create:true}); };
                const selected = await control.pickFile({suggestedName:'ui-test.webm'});
                const writer = await selected.createWritable(); await writer.write(original); await writer.close();
                recorder.savedFile=selected; recorder.snapshot.phase='saved'; subscriber();
                const stayedIdle = !control.busy && opened === 0;
                parent.querySelector('#recordingMp4Previous').click();
                await control.wait();
                const manualSaved = parent.querySelector('#recordingMp4Status').textContent;
                window.showSaveFilePicker = async () => {throw new DOMException('Cancelled','AbortError');};
                parent.querySelector('#recordingMp4Previous').click(); await control.wait();
                const cancelledPickerKeptSaved = parent.querySelector('#recordingMp4Status').textContent === manualSaved;
                parent.querySelector('input').click();
                const automatic = await control.pickFile({suggestedName:'automatic-test.webm'});
                const autoWriter = await automatic.createWritable(); await autoWriter.write(original); await autoWriter.close();
                recorder.savedFile=automatic; recorder.snapshot.phase='saved'; subscriber();
                const autoStarted=control.busy;
                const progressVisible=parent.querySelector('progress').style.display !== 'none';
                parent.querySelector('#recordingMp4Cancel').click();
                await control.wait();
                const cancelled=parent.querySelector('#recordingMp4Status').textContent;
                parent.querySelector('#recordingMp4Retry').click();
                await control.wait();
                // The helper reads the saved file to create a local Open video link.
                for(let i=0;i<100 && !parent.querySelector('#recordingMp4Open').href;i++) await new Promise(r=>setTimeout(r,10));
                const result={enabledByDefault, stayedIdle, manualSaved, filePickerCalls, cancelledPickerKeptSaved, autoStarted, progressVisible, cancelled, opened,
                    ready:parent.querySelector('#recordingMp4Status').textContent,
                    openVideo:parent.querySelector('#recordingMp4Open').href.startsWith('blob:'),
                    progress:parent.querySelector('progress').value,
                    originalBytes:(await selected.getFile()).size};
                control.dispose(); parent.remove();
                // Invalid input must fail without opening/replacing the destination.
                let openedWriter=false, rejected=false;
                try { await window.mp4Proof.convertRecordingToMp4(new File(['bad'],'bad.webm'),
                    {createWritable(){openedWriter=true;throw Error('must not open');}},new AbortController().signal,()=>{}); }
                catch {rejected=true;}
                const failures = [];
                for (const mode of ['write-failure', 'cancel']) {
                    let closed=false, aborted=false, failed=false;
                    const abort = new AbortController();
                    try { await window.mp4Proof.convertRecordingToMp4(original, {async createWritable() {return {
                        async seek(){}, async write(){if(mode==='write-failure') throw Error('Disk full');},
                        async close(){closed=true;}, async abort(){aborted=true;}
                    };}}, abort.signal, () => {if(mode==='cancel') abort.abort();}); }
                    catch {failed=true;}
                    failures.push({mode,closed,aborted,failed});
                }
                return {...result,rejected,openedWriter,failures};
            }, {browserName});
            assert.equal(ui.enabledByDefault,false); assert.equal(ui.stayedIdle,true); assert.match(ui.manualSaved,/Your video is now ready/);
            assert.equal(ui.filePickerCalls,2); assert.equal(ui.cancelledPickerKeptSaved,true);
            assert.equal(ui.autoStarted,true); assert.equal(ui.progressVisible,true);
            assert.match(ui.cancelled,/cancelled/); assert.equal(ui.opened,3); assert.match(ui.ready,/Your video is now ready/);
            assert.equal(ui.openVideo,true); assert.equal(ui.progress,100); assert.ok(ui.originalBytes>0);
            assert.equal(ui.rejected,true); assert.equal(ui.openedWriter,false);
            for(const failure of ui.failures) { assert.equal(failure.failed,true); assert.equal(failure.closed,false); assert.equal(failure.aborted,true); }
            console.log(JSON.stringify({browserName,ui}));
            const imported = await page.evaluate(async ({browserName}) => {
                const directory = await navigator.storage.getDirectory();
                const source = await directory.getFileHandle(`${browserName}-H264.mkv`);
                const before = await (await source.getFile()).arrayBuffer();
                const parent = document.createElement('div'); document.body.append(parent);
                let subscriber, opened = 0, saveCalls = 0, pickerOptions;
                const recorder = { snapshot:{phase:'idle'}, savedFile:null, hasUnsavedData:false,
                    subscribe(callback){subscriber=callback;return()=>{};},resetLocation(){} };
                const control = window.mp4Proof.installMp4RecordingExport({recorder,parent,
                    openSettings:()=>opened++,onChange:()=>{},focusStream:()=>{}});
                const click = id => parent.querySelector('#'+id).click();
                const text = id => parent.querySelector('#'+id).textContent;
                const previousDisabled = parent.querySelector('#recordingMp4Previous').disabled;
                let release;
                window.showOpenFilePicker = opts => {pickerOptions=opts;return new Promise(resolve=>{release=resolve;});};
                window.showSaveFilePicker = async opts => {saveCalls++;return directory.getFileHandle(opts.suggestedName,{create:true});};
                click('recordingMp4Browse');
                const busyWhilePicking = control.busy && parent.querySelector('#recordingMp4Browse').disabled;
                release([source]); await control.wait();
                const selected = text('recordingMp4Input');
                const noPrematureSave = saveCalls === 0 && opened === 0;
                click('recordingMp4Selected'); await control.wait();
                const saved = text('recordingMp4Status'), location = text('recordingMp4Location');
                window.showOpenFilePicker = async () => {throw new DOMException('Cancelled','AbortError');};
                click('recordingMp4Browse'); await control.wait();
                const cancelPreserved = text('recordingMp4Input') === selected && text('recordingMp4Status') === saved;
                window.showOpenFilePicker = async () => {throw new DOMException('Denied','NotAllowedError');};
                click('recordingMp4Browse'); await control.wait();
                const denied = text('recordingMp4Status');
                window.showOpenFilePicker = async () => [{name:'wrong.mp4',getFile:()=>{throw Error('must not read');}}];
                click('recordingMp4Browse'); await control.wait();
                const rejectedExtension = text('recordingMp4Status');
                window.showSaveFilePicker = async () => source;
                click('recordingMp4Selected'); await control.wait();
                const sameFileRejected = text('recordingMp4Status');
                const after = await (await source.getFile()).arrayBuffer();
                const originalUnchanged = new Uint8Array(before).every((v,i)=>v===new Uint8Array(after)[i]) && before.byteLength===after.byteLength;
                // Existing recording activity disables imports, including startup/countdown.
                recorder.snapshot.phase='recording'; subscriber();
                const disabledDuringRecording = parent.querySelector('#recordingMp4Browse').disabled && parent.querySelector('#recordingMp4Selected').disabled;
                recorder.snapshot.phase='idle'; subscriber(); control.setPreparing(true);
                const disabledDuringCountdown = parent.querySelector('#recordingMp4Browse').disabled;
                control.setPreparing(false);
                // Disposing while the picker is open must not start conversion afterwards.
                window.showOpenFilePicker = () => new Promise(resolve=>{release=resolve;});
                click('recordingMp4Browse'); const pending = control.wait(); control.dispose(); release([source]); await pending;
                parent.remove();
                return {previousDisabled,busyWhilePicking,selected,noPrematureSave,saved,location,cancelPreserved,denied,rejectedExtension,
                    sameFileRejected,originalUnchanged,disabledDuringRecording,disabledDuringCountdown,saveCalls,opened,pickerOptions};
            }, {browserName});
            assert.equal(imported.previousDisabled,true); assert.equal(imported.busyWhilePicking,true);
            assert.equal(imported.noPrematureSave,true); assert.equal(imported.cancelPreserved,true);
            assert.match(imported.saved,/MP4 saved/); assert.match(imported.location,/Original recording: .*H264.mkv.*MP4 saved: .*H264.mp4/);
            assert.match(imported.denied,/Could not open/); assert.match(imported.rejectedExtension,/Choose a WebM/);
            assert.match(imported.sameFileRejected,/Could not export MP4/); assert.equal(imported.originalUnchanged,true);
            assert.equal(imported.disabledDuringRecording,true); assert.equal(imported.disabledDuringCountdown,true);
            assert.equal(imported.saveCalls,1); assert.equal(imported.opened,2); assert.equal(imported.pickerOptions.multiple,false);
            console.log(JSON.stringify({browserName,imported}));
            assert.deepEqual(errors, []); assert.deepEqual(external, []);
        } finally { await browser.close(); }
    }
    await writeFile(path.join(evidence, 'summary.json'), JSON.stringify({ node: process.version, summaries }, null, 2));
} finally { await new Promise(resolve => server.close(resolve)); console.log('Browser contexts and local server closed.'); }
