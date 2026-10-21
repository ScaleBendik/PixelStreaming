# Camera smoothing in Recording settings

The TypeScript player has a **Smooth camera movement** checkbox at the top of
**Settings → Recording**. It controls the existing Unreal camera behavior through
optional Pixel Streaming UI messages. Unreal owns the actual value; the browser
does not assume that the camera starts with smoothing off or restore a remembered
browser preference. No engine modification or additional plugin is required.

This is a session camera setting. **Record and Stop do not change it automatically.**
It also affects movement when no recording is running. The Unreal widget and the
browser checkbox must use the same setter and state described below.

## State and failure behavior

- On data-channel readiness, including reconnect, the browser requests the current
  value. The checkbox is disabled and indeterminate until a matching reply arrives.
- A change sends an explicit boolean once. While awaiting confirmation, the checkbox
  remains disabled and shows the last confirmed value. It never assumes success.
- Set acknowledgement has a 3-second timeout. A timeout, thrown send or rejected
  send triggers a fresh state query, not another Set. A reply containing the old
  value restores that value and reports that the change was not applied.
- Get sends at most three times, 2 seconds apart. After 6 seconds without a valid
  reply, the control says it is unavailable and offers **Retry**. Missing Blueprint
  support therefore leaves recording and stream input usable.
- Widget broadcasts update the checkbox after initial synchronization. They do not
  acknowledge a pending browser command. Disconnect clears known state; obsolete
  request replies, invalid JSON, wrong types and non-boolean values are ignored.
- The smoothing controller does not stop tracks, alter recording or reconnect the
  stream. Its initialization, response rendering, transport and cleanup failures
  are isolated from those features. A failed command can still have reached Unreal;
  querying actual state resolves that uncertainty without applying it twice.

## Message contract

Browser → Unreal uses `stream.emitUIInteraction(...)`, delivered to the Pixel
Streaming 2 Input component's **On Input Event** as its JSON `Descriptor` string.
These are application UI messages, not console commands or Wilbur runtime commands.
Names and field casing must match exactly.

```json
{"type":"CameraSmoothing.Get","requestId":"browser-generated-id"}
{"type":"CameraSmoothing.Set","requestId":"browser-generated-id","enabled":true}
```

Unreal → browser uses the existing Pixel Streaming **Response** message. Answer
both Get and Set with the **actual** current value and echo the request ID exactly:

```json
{"type":"CameraSmoothing.State","requestId":"browser-generated-id","enabled":true}
```

When the widget or another Unreal path changes the value, broadcast it without a
`requestId` field:

```json
{"type":"CameraSmoothing.State","enabled":false}
```

`enabled` must be a JSON boolean, **not** the string `"true"` or `"false"`. Request
IDs are opaque strings; do not generate a replacement in Unreal. Get retries reuse
the same ID. Replies with IDs belonging to another viewer are ignored. Pixel
Streaming 2's response nodes broadcast to players, so the shared setter must also
send the state-only broadcast to keep other synchronized viewers current.

## Unreal Blueprint walkthrough (UE 5.8.2)

The node/API behavior below was checked against UE 5.8.2's PixelStreaming2 source,
including `PixelStreaming2InputComponent`, `PixelStreaming2Blueprints` and the
engine JSON boolean conversion. The application Blueprint itself is not modified
or validated by the frontend tests.

### 1. Share the existing camera setting

Keep your current smoothing boolean in its authoritative camera/controller actor,
or expose a getter from that actor. Do not make a second independent browser flag
or rely on a widget that exists only while its menu is open.

Create or reuse a function such as **SetCameraSmoothing(Enabled: Boolean)** that
sets the requested value explicitly and applies your existing camera logic.
Use it from both the current widget and the incoming browser request. Do not use
a FlipFlop or a blind toggle: repeated requests must not invert the state.

After a successful change, update the existing widget from the actual value and
send the state-only broadcast from step 3. If the change cannot be applied, keep
the previous actual value. Avoid wiring programmatic widget refreshes back into
the user-change handler; a guard boolean can prevent such feedback if needed.

### 2. Receive the two browser messages

On an actor that is present while streaming, add or reuse a **Pixel Streaming 2
Input** component. Bind **On Input Event** once, independently of opening the
widget. If you already handle UI messages, extend that handler and retain its
existing branches.

From the event's `Descriptor`:

1. Use **Get Json String Value** for field `type`. Check `Success`, then route the
   two exact strings `CameraSmoothing.Get` and `CameraSmoothing.Set`.
2. Extract `requestId` with **Get Json String Value**. Require success and a
   nonempty value; preserve it for the reply.
3. For **Get**, read the actual smoothing boolean and call the reply helper in
   step 3. Do not change the camera.
4. For **Set**, extract `enabled` with **Get Json String Value**. In UE 5.8.2,
   native JSON booleans convert to the lowercase strings `true` and `false`.
   Check `Success` and compare against those two exact strings. Convert `true`
   to true and `false` to false; ignore anything else. A nonempty string test is
   incorrect because `false` is also nonempty.
5. Call the shared setter with the desired boolean. Then read the **actual** value
   and send a reply with the original request ID, even if no change was needed or
   the request could not be applied. Do not acknowledge by blindly echoing the
   requested value. If the setter is asynchronous, reply when it has finished.

Do not answer until the camera's actual initial state is available. The bounded
browser queries and Retry handle late initialization. A one-time BeginPlay
broadcast is insufficient because a viewer can join or reconnect later.

### 3. Build and send the response

An all-Blueprint helper can preserve the native JSON boolean without adding a
JSON utility plugin:

1. Add **Select String**, with the actual smoothing boolean as its selection.
   Set its true value to `{"type":"CameraSmoothing.State","enabled":true}` and
   its false value to `{"type":"CameraSmoothing.State","enabled":false}`.
2. For a Get/Set reply, pass the selected string to **Add Json String Value**:
   `Field Name = requestId`, `String Value = the incoming requestId`.
   Check `Success` and send `New Descriptor`. This safely escapes the ID and
   retains the existing boolean.
3. Send that descriptor through **Send Response** in category **Pixel Streaming
   2**. This targets the default streamer. If your application uses a named
   non-default streamer, use **Streamer Send Response** with its ID instead.
4. For a state-only broadcast, send the selected base string directly. Omit the
   `requestId` field entirely; an empty string is not a broadcast.

The component's **Send Pixel Streaming 2 Response** is also available, but it
broadcasts across all streamers and players. Use the intended streamer when
camera state is not shared across streamers. Neither API unicasts a reply to the
requesting player, which is why reply correlation is required.

Do not use **Add Json String Value** for `enabled`: it would produce a string
which this frontend intentionally rejects. Restrict the input handler to these
two named messages and retain any existing application permission checks.

### 4. Connect the current widget

Replace the widget's old toggle path with the same explicit setter. Initialize
its checked state from the authoritative getter when it opens. The shared setter
publishes actual state whenever it changes, including changes made outside either
menu. If the camera/pawn is replaced, publish the replacement's actual state once
initialized. This keeps both interfaces consistent without polling continuously.

## Compatibility and validation

`Frontend/implementations/typescript/src/cameraSmoothing.ts` owns synchronization
and the checkbox; `playerRecording.ts` installs it independently of the recorder.
This additive application protocol changes no signalling format, API version or
runtime minimum. Frontend and Blueprint can ship in either order: old Unreal
leaves the new checkbox unavailable, and old frontends ignore the new response
type. Rolling back either side removes browser control without affecting local
recording. Keep existing UI message handlers compatible with unknown message types.

Run the TypeScript player tests/build and
`Frontend/implementations/typescript/test/browser-recording-settings.mjs` as
described in [the recording guide](browser-local-recording.md). The browser harness
uses the production control and a fake Unreal transport, including initialization,
widget broadcasts, keyboard activation, reconnect, transport exceptions, Retry and
recording while smoothing is unavailable. It cannot prove the real camera effect.

Before accepting the integration on the exact Unreal/runtime/browser builds:

- Start with smoothing both on and off; refresh and reconnect. The browser must
  show Unreal's current value without changing it on initialization.
- Change it from each menu and confirm the other menu and camera behavior match.
  Repeat with both menus closed/reopened and after a camera/pawn replacement.
- Ignore a Set, then reply to Get with the old state. Confirm the checkbox returns
  to that state with a message, and Record/Stop and camera input still work.
- Test with the Blueprint handler absent or not yet ready. The checkbox should
  become unavailable; Retry should recover after the handler becomes ready.
- If multiple viewers are allowed, confirm a command's correlated reply affects
  only the requesting controller while state broadcasts update the others.

The remaining application Blueprint work and hosted acceptance are tracked in the
canonical Browser Local Stream Recording backlog entry. No Unreal packaging or
runtime publication is implied by frontend validation.
