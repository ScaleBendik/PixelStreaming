import { BlobSource, Conversion, Input, MATROSKA, WEBM, Mp4OutputFormat, Output, Quality, StreamTarget, StreamTargetChunk, VideoSample, VideoSampleSink, VideoSampleSource } from 'mediabunny';

export interface Mp4Destination {
    createWritable(): Promise<{
        seek(position: number): Promise<void>;
        write(data: Blob): Promise<void>;
        close(): Promise<void>;
        abort(): Promise<void>;
    }>;
}

/** Local files only: no URL sources, uploads, CDN modules or whole-file buffers. */
export async function convertRecordingToMp4(
    source: File, destination: Mp4Destination, signal: AbortSignal,
    progress: (fraction: number, bytes: number) => void
): Promise<{ bytes: number; videoCopied: boolean }> {
    const input = new Input({ source: new BlobSource(source), formats: [MATROSKA, WEBM] });
    let conversion: Conversion | undefined;
    let disk: Awaited<ReturnType<Mp4Destination['createWritable']>> | undefined;
    let bytes = 0;
    let committed = false;
    let output: Output | undefined;
    const check = () => { if (signal.aborted) throw new DOMException('Export cancelled', 'AbortError'); };
    const bounded = async <T>(operation: Promise<T>): Promise<T> => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
            return await Promise.race([operation, new Promise<never>((_, reject) => {
                timer = setTimeout(() => reject(new Error('Local file operation timed out')), 30_000);
            })]);
        } finally { clearTimeout(timer); }
    };
    const cancel = () => { void conversion?.cancel().catch(() => {}); void output?.cancel().catch(() => {}); };
    signal.addEventListener('abort', cancel);
    try {
        check();
        const videos = await input.getVideoTracks();
        const audio = await input.getAudioTracks();
        if (videos.length !== 1 || audio.length > 1) throw new Error('Unsupported recording tracks');
        const codec = await videos[0].getCodec();
        if (!codec || !['avc', 'av1', 'vp9'].includes(codec)) throw new Error('Unsupported recording codec');
        check();
        const target = new StreamTarget(new WritableStream<StreamTargetChunk>({
            async write(chunk) {
                check();
                if (!disk) throw new Error('Export destination is not open');
                await bounded(disk.seek(chunk.position)); check();
                await bounded(disk.write(new Blob([chunk.data.slice().buffer]))); check();
                bytes = Math.max(bytes, chunk.position + chunk.data.length);
            },
            async close() {
                check();
                if (!disk || !bytes) throw new Error('Empty MP4 export');
                await bounded(disk.close());
                committed = true;
            },
            async abort() { if (disk && !committed) await bounded(disk.abort()).catch(() => {}); }
        }), { chunked: true, chunkSize: 1024 * 1024 });
        output = new Output({ target, format: new Mp4OutputFormat({ fastStart: false }) });
        const transcode = codec !== 'avc';
        const videoSource = transcode ? new VideoSampleSource({ codec: 'avc', bitrate: new Quality('high') }) : undefined;
        if (videoSource) output.addVideoTrack(videoSource);
        // Chromium's cluster boundaries can expose zero-duration decoded frames.
        // Conversion drops these before its process hook. Pump video ourselves,
        // using the following timestamp to preserve every frame and VFR timing.
        if (!transcode || audio.length) conversion = await Conversion.init({
            input, output,
            composable: true,
            // Do not set quality/size/rate on AVC: those options force a transcode.
            video: transcode ? { discard: true } : { codec: 'avc' },
            audio: { codec: 'aac', quality: new Quality({ bitrate: 192_000 }) },
            showWarnings: false
        });
        check();
        // A valid conversion may still discard an unsupported audio track. Never
        // call a silent/truncated export successful when the source contained it.
        if (conversion && (!conversion.isValid || conversion.utilizedTracks.length !== (transcode ? 0 : videos.length) + audio.length)) {
            throw new Error('This browser cannot convert all recording tracks to H.264/AAC');
        }
        const opening = destination.createWritable();
        try { disk = await bounded(opening); }
        catch (error) { void opening.then(writer => writer.abort()).catch(() => {}); throw error; }
        check();
        if (conversion && !transcode) conversion.onProgress = fraction => progress(Math.min(0.99, Math.max(0, fraction)), bytes);
        const duration = await input.computeDuration();
        await output.start();
        const pumpVideo = async () => {
            if (!videoSource) return;
            let pending: VideoSample | undefined;
            let lastDuration = 1 / 30;
            const write = async (end: number) => {
                if (!pending) return;
                check();
                const span = end - pending.timestamp;
                pending.setDuration(span > 0 ? span : lastDuration);
                lastDuration = pending.duration;
                await videoSource.add(pending);
                progress(Math.min(0.99, Math.max(0, end / duration)), bytes);
                pending.close(); pending = undefined;
            };
            try {
                for await (const sample of new VideoSampleSink(videos[0]).samples()) {
                    try { await write(sample.timestamp); } catch (error) { sample.close(); throw error; }
                    pending = sample;
                }
                if (pending) await write(pending.timestamp + (pending.duration || lastDuration));
                videoSource.close();
            } finally { pending?.close(); }
        };
        await Promise.all([conversion?.execute(), pumpVideo()]);
        check();
        await output.finalize();
        if (!committed) throw new Error('MP4 output did not finish saving');
        return { bytes, videoCopied: codec === 'avc' };
    } catch (error) {
        await conversion?.cancel().catch(() => {});
        await output?.cancel().catch(() => {});
        if (disk && !committed) await bounded(disk.abort()).catch(() => {});
        throw error;
    } finally {
        signal.removeEventListener('abort', cancel);
        input.dispose();
    }
}
