# Browser local recording

The TypeScript player provides **Record video → Choose location → Record → Stop**.
The user chooses a local file through the browser's Save picker. Recording writes
chunks to that file and shows **Saved** only after the writer closes successfully.
There is no upload, second network download, additional viewer, or Unreal plugin.

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
recording to produce chunks; a failed playback start stays visible in the dialog.

## Implementation and invariants

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
- Stop waits for the final recorder data event, drains writes, then closes the
  writer. File System Access stages writes until close; a crash or forced tab
  closure can lose an unfinished recording.
- Track loss, peer replacement, disconnection and codec changes finalize the
  current clip. Reconnection never appends a new media generation to that clip.
- `recordingControl.ts` owns the optional toolbar/dialog, status, elapsed time,
  size, unload warning and explicit choice to leave after a failed save. Recording
  continues while its dialog is closed. Player input suspension uses shared modal
  leases so overlapping recording/session-end dialogs cannot restore input early.
- Built-in session-end redirects, player-initiated window closure, ticket-refresh redirects and the
  recovery panel's manager link await finalization. A failed save retains the
  page unless the user explicitly chooses to leave. Pagehide cleanup alone cannot
  guarantee completion. This does not delay authoritative server-side session end.

## Verification and remaining acceptance

Use the repository-pinned Node version in `NODE_VERSION`. Run the TypeScript
player workspace's `npm test` and production `npm run build` after building the
Common, frontend library and UI library dependencies. No signalling protocol,
API, runtime command or Unreal build change is required for this feature.

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

Chunked MediaRecorder output can omit duration/seek-index metadata at file open;
players may discover duration only after reading the media. Test the intended
external players and long recordings before promising immediately indexed seeking.
Container metadata changes can be implemented separately without video re-encoding.

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
