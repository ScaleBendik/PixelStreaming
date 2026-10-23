# Browser local recording

The TypeScript player provides **Settings → Recording → Choose location → Record → Stop**.
The user chooses a local file through the browser's Save picker. Recording writes
chunks to that file and shows **Saved** only after the writer closes successfully.
There is no upload, second network download, additional viewer, or Unreal plugin.
All recording controls, filename, format and progress appear inline in the Recording
category, directly below Pixel Streaming. Only Pixel Streaming starts expanded;
Recording and the remaining categories start collapsed. A passive status badge
beside Settings remains visible when it is closed.
Start delay accepts integer seconds from 0 to 60 and defaults to 3 for each player
page. Record closes Settings during the centered, non-interactive countdown;
0 starts immediately. The small square Stop recording button between Settings
and the timer cancels preparation/countdown or finalizes the active clip. Disconnect,
peer/track/codec replacement, navigation and disposal cancel a pending start.
Audio playback is resumed within the original click gesture before the delay.
Successful Record activation closes Settings and returns keyboard focus to the stream.
Immediate startup failures keep Settings open; delayed failures remain available
in Settings and the status badge. Settings can be reopened during
recording to check progress or Stop. Pointer actions also return focus to the stream;
keyboard users can still tab through the controls when choosing a location or stopping.

The optional **Smooth camera movement** checkbox in this category synchronizes
with the existing Unreal camera setting. Its [Blueprint integration guide](camera-smoothing.md)
defines Get/Set/State messages, initialization and failure behavior. Missing or
failed Unreal support disables only that checkbox. The setting affects camera
movement throughout the session; Record and Stop do not change it automatically.

Optional [recording usage analytics](recording-analytics.md) reports capture start,
successful file close, or failure using metadata only. The player/relay are implemented;
API token issuance/persistence and Manager analytics display remain follow-ups.
Without a recording-only capability no reports are sent. Analytics failures never
block local saving, streaming or navigation; media and local paths are not uploaded.

## Scope and formats

Recording is available across Standard and Premium sessions. It follows the
actual incoming codec, not the instance GPU or requested service class:

| Incoming video | Saved container | Extension |
| --- | --- | --- |
| AV1 | WebM | `.webm` |
| VP9 | WebM | `.webm` |
| H264 | Matroska | `.mkv` |

Desktop Chrome and Edge 141+ are the intended browser scope. The player also
requires a secure context, MediaRecorder and the File System Access Save picker.
Unsupported browsers and unobserved/unsupported media get an explanation rather
than an alternate screen capture or transcoding implementation. Browser enterprise
policies can still deny file access. The native picker grants access to a file;
the page does not receive an arbitrary writable absolute path.

The video is the received Unreal stream, including its network/adaptive quality
constraints. Browser toolbar overlays, other tabs and the user's microphone are
not recorded. Received game audio is included when available. Chromium's audio
recorder encodes that audio; the video passthrough claim does not apply to audio.
Record resumes a paused playback element containing the received audio while
preserving its mute and volume settings. Chromium must pull that audio for
recording to produce chunks; a failed playback start stays visible in Settings.

## Automatic local MP4 export

“convert to MP4 after recording” is off by default. Normal recording uses the
single-file Save picker. After saving, “Convert previous recording to MP4” converts
the most recent successful recording from this page, with a separate MP4 Save
picker. Cancelling that picker leaves the recording intact; selecting the source
file itself is rejected. “Choose saved recording…” also opens a single WebM/MKV
file from an earlier visit, without requiring a current-session recording or folder
write access. “Convert selected recording to MP4” then opens the output Save picker
from a separate user gesture. Cancelling either picker preserves existing results;
invalid or unsupported media fails safely without modifying the source. This is
intended for this recorder's H.264, AV1 and VP9 files, not a general media converter.

Opting into automatic conversion makes Choose location request a folder, so the
browser can save both files without another prompt after Stop. The UI explains this
permission requirement. Use a dedicated folder; browsers may restrict Desktop or
drive-root folder access even where single-file saving is permitted. Changing the
checkbox clears the selected location. Automatic clips use unique names and do not
silently overwrite existing MP4s; manual output uses the native Save confirmation.

After the original is finalized, Settings opens to show conversion progress, Cancel,
and retry on failure. Raw completion says “Original recording saved”; conversion
completion says “MP4 saved. Your video is now ready” and offers Open MP4. The source
and output filenames are displayed separately, with confirmation that the original
is kept unchanged. During conversion/failure the output is labelled a destination,
not a saved file. The reveal scrolls only Settings vertically; it must not use ancestor-scrolling
`scrollIntoView` during the horizontal panel transition. No delayed scroll remains
after closing Settings. Normal, compact and ultrawide layout regressions cover this.
The folder name is displayed; browsers cannot reliably open Windows Explorer or Finder.
Cancellation, missing encoder support and conversion failure preserve the original.
The tab must remain open until conversion finishes. Built-in navigation waits for
conversion; Cancel conversion permits leaving with the original retained.

The bundled Mediabunny worker uses native WebCodecs, local file handles and streamed
output; there are no media uploads, CDN scripts, extra software or server conversion.
H.264 video is remuxed without re-encoding. AV1/VP9 video is decoded and encoded to
H.264 at its original dimensions with high-quality encoding; this costs CPU/GPU time
and is lossy. Audio, when present, becomes AAC. The result is indexed H.264/AAC MP4,
not AV1/VP9 renamed to MP4. Variable frame timestamps are preserved. Missing video
durations at Matroska cluster boundaries are inferred from adjacent timestamps;
the final frame uses its declared duration or the previous interval. No frames are
intentionally dropped. Codec availability depends on browser/OS; failure leaves the
raw recording available. MP4 conversion is not a second recording analytics event.

`mp4Conversion.ts` owns media processing, `mp4Export.worker.ts` isolates it from the
player UI, `mp4Export.ts` owns cancellation/timeouts, and `recordingMp4Control.ts`
owns the settings workflow. Mediabunny is pinned; its ambient type dependencies are
nested beneath it in the lockfile to avoid changing unrelated workspace DOM types.
The build emits its license/source notice at `third-party/mediabunny.txt`.

## Implementation and invariants

- `seekableRecording.ts` wraps the disk writer with bounded streaming EBML parsing.
  It preserves encoded blocks and track descriptions, adds an Info/Duration field,
  reserves a SeekHead at the start, and collects video keyframe offsets. Stop appends
  Cues and patches SeekHead, duration and Segment length before committing the file.
  Duration uses media timestamps and the final frame's declared/inferred interval;
  it does not convert variable frame rate. Memory does not grow with video payload:
  parsing buffers are capped at 64 MiB, headers at 1 MiB and the index at 100,000
  keyframes. Unsupported/malformed data or failed finalization aborts the write and
  never reports Saved. Saved UI/analytics byte counts include the finalized metadata.
  These changes apply to new recordings only. They improve seeking in compatible
  players; they do not add WebM/MKV/AV1/VP9 support to Adobe or produce MP4.
- `Frontend/implementations/typescript/src/playerRecording.ts` adapts the current
  peer's original incoming tracks and generation-fenced decoded-codec stats.
  No separate tier grant is required for media already admitted by Wilbur.
- `localRecording.ts` owns the picker, recorder and file writer. It constructs
  `MediaRecorder` from the original RTC tracks with **no MIME or bitrate options**.
  Chromium's unspecified-type path uses `VideoTrackRecorderPassthrough` when the
  source provides encoded frames. Specifying even the matching codec in options
  disables this selection in the inspected Chromium implementation.
- A selected file is bound to its video codec/container. A codec change before
  starting requires a new file selection. Each subsequent clip also requires a
  new selection; the controller never silently overwrites the last clip.
- Actual nonempty output must match the selected codec and container. This is a
  format guard, not independent proof of video passthrough: MediaRecorder has no
  public “require passthrough” switch. Byte-preservation browser tests remain the
  acceptance evidence for supported builds.
- Chunks are written sequentially with a bounded 64 MiB pending-write queue.
  Startup and individual I/O operations have bounded waits. Errors stop recording,
  attempt to abort the incomplete write, and report failure without stopping the
  original playback tracks or claiming the file was saved.
- Stop waits for the final recorder data event, drains writes, finalizes metadata, then closes the
  writer. File System Access stages writes until close; a crash or forced tab
  closure can lose an unfinished recording.
- Track loss, peer replacement, disconnection and codec changes finalize the
  current clip. Reconnection never appends a new media generation to that clip.
  Opening or cancelling the End session confirmation alone keeps recording;
  an accepted session end or disconnection triggers finalization.
- `recordingControl.ts` owns the inline Settings controls, status, elapsed time,
  size, unload warning and explicit choice to leave after a failed save. Recording
  continues while Settings is closed. Inline controls isolate their own events;
  they do not suspend stream input. Stop also cancels pending audio preparation.
  Only the failed-save navigation decision opens a separate modal, above any
  End session modal. Shared input leases prevent early input restoration, and
  native modal focus restoration preserves the underlying session-end controls.
- Built-in session-end redirects, player-initiated window closure, ticket-refresh redirects and the
  recovery panel's manager link await finalization. A failed save retains the
  page unless the user explicitly chooses to leave. Pagehide cleanup alone cannot
  guarantee completion. This does not delay authoritative server-side session end.

## Verification and remaining acceptance

After creating local fixtures with `test/browser-av1-recording.mjs`, run
`node Frontend/implementations/typescript/test/browser-mp4-export.mjs` from the repo
root. It exercises the real worker and native local file handles in Chrome/Edge for
H.264, AV1 and VP9: H.264/AAC output, frame preservation, H.264 NAL preservation,
seeking, audio decoding, original-file preservation and automatic export/cancel/retry.
This synthetic proof does not establish long/high-resolution clip performance,
Mac encoder support, weak-laptop performance or Adobe import. Validate these on the
deployed runtime before making broad compatibility claims.

Use the repository-pinned Node version in `NODE_VERSION`. Run the TypeScript
player workspace's `npm test` and production `npm run build` after building the
Common, frontend library and UI library dependencies. No signalling protocol,
API, runtime command or Unreal build change is required for this feature.

`test/browser-recording-settings.mjs` in the TypeScript player workspace checks
the actual settings/category styles and KeyboardController in Chrome and Edge,
with a fake recorder. Run from the repo root with the same Playwright/browser
environment variables as the media proof below:

```powershell
node Frontend/implementations/typescript/test/browser-recording-settings.mjs
```

It covers pointer and keyboard activation, Unreal key routing after Record/Stop,
collapsed Settings, failed-save navigation above an End session modal, and desktop,
narrow-window and light-theme layouts. Screenshots go to ignored
`.review-tmp/recording-settings/`. This does not exercise the native Save picker.

`Frontend/implementations/typescript/test/browser-av1-recording.mjs` is the
separate real-browser proof harness. From the repo root, run:

```powershell
node Frontend/implementations/typescript/test/browser-av1-recording.mjs
```

Use installed Playwright, or set `PLAYWRIGHT_MODULE_PATH` to an existing Playwright
package directory. `CHROME_EXECUTABLE` / `EDGE_EXECUTABLE` can select browser
executables. `RECORDING_BROWSER=chrome|edge` and `RECORDING_CODEC=AV1|VP9|H264`
filter the matrix; `RECORDING_MUTED=1` covers muted but playing received audio.
Evidence is written under the ignored `.review-tmp/recording-proof/` directory.

The harness uses synthetic local WebRTC media, received encoded-frame inspection,
the production controller and an OPFS file writer (the browser's real disk-backed
`FileSystemWritableFileStream`, without the native picker). Its saved-video comparison must
preserve encoded video content, start at a keyframe and leave playback tracks
live. The AV1/VP9/H264 matrix passes with Chrome 155.0.8059.85 and Edge
155.0.4283.62: every saved video packet matches the received bytes and order;
received Opus audio is included, and clips play and seek. Synthetic media
establishes the browser path, not an Unreal/GPU build or native-picker acceptance.

Raw browser chunks omit seek metadata; the recording writer now adds it before
file close. Test the intended external players and long recordings against the
finalized files. MP4 export separately addresses codec/container compatibility.

Before promoting an artifact to serving environments, accept the actual native picker, cancel/overwrite
prompts, write permissions/free-space failures, repeated clips, audio synchronization,
resolution changes, reconnect/ticket refresh, session-end navigation and sustained
recordings against the exact deployed Unreal/runtime/browser builds. Preserve
the existing Premium AV1 hosted acceptance gate; local browser tests do not close it.

## Browser implementation references

- [Chromium recorder selection](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/mediarecorder/media_recorder_handler.cc)
- [Chromium encoded-video copying](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/mediarecorder/video_track_recorder.cc)
- [File System Access API](https://developer.chrome.com/docs/capabilities/web-apis/file-system-access)

If a future browser no longer provides the verified MediaRecorder passthrough,
disable or revalidate support. An explicit receiver encoded-frame transform plus
a muxer is an alternative, not a silent transcoding fallback.
