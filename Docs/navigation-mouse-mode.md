# Unreal navigation and browser mouse mode

The TypeScript reference player consumes these exact, case-sensitive Pixel Streaming
Send Response strings through `installNavigationMode` in
`Frontend/implementations/typescript/src/navigationMode.ts`:

| Response | HoveringMouseMode | Behavior |
| --- | --- | --- |
| `Navigation.Free` | false | Select locked mouse; click the stream to capture the pointer. |
| `Navigation.Menu` | true | Select hovering mouse and release the stream's pointer lock. |

Send the response after the corresponding Unreal navigation/menu transition succeeds.
These are plain strings, not JSON. Unrelated responses continue to other listeners.
Duplicate messages do not recreate the mouse controller when the setting already matches.
The normal Config API updates the settings-panel label and mouse controller; this
integration never enables input devices or grants input ownership. Suspended inputs,
including the End session dialog, remain suspended. Touch/gamepad flags are unchanged.
This is best-effort UX: settings access, listener registration and cleanup errors are
contained. A failed update does not escape into shared response dispatch or player
bootstrap. No retries, reconnects or session operations are triggered by failure.
An exception inside the existing settings/controller code may leave the scheme
unchanged or partially applied; this helper does not promise transactional rollback.

## Browser behavior

Changing the scheme is separate from acquiring browser pointer lock. The existing
locked controller requests it on a stream click. Users may need another click after
selecting free navigation in Unreal. Escape releases capture; another stream click
can recapture. The listener does not force capture, retry after Escape, or simulate
a browser gesture. Unsupported browsers retain their existing controller behavior.
See [Pointer Lock requirements](https://developer.mozilla.org/en-US/docs/Web/API/Element/requestPointerLock).
There is no new capture overlay. The existing manual control-scheme toggle remains
available; the next recognized Unreal notification selects the requested scheme again.

## Initial settings and reconnect

A late Unreal `InitialSettings.ConfigOptions.DefaultToHover` cannot overwrite an
explicit navigation response already received on the same connection: the listener
reapplies that connection's last mode after initial settings. Disconnect clears this
remembered authority without changing input registration. On reconnect, ordinary
configuration/engine defaults apply until a new navigation response arrives.

For reliable refresh/reconnect synchronization, Unreal must resend its **current**
navigation state when the new viewer's data channel is ready. Transition-only
Blueprints cannot guarantee this: the browser cannot infer a missed transition.
The private Unreal project is outside this implementation; this replay and moving
notifications after successful transitions require operator Blueprint changes.
Responses may reach multiple viewers; they are presentation hints, never viewer
authorization. Existing input/admission policy remains responsible for ownership.

## Compatibility and verification

This is an additive application response consumer, not a library/protocol version
change. Old Unreal builds that emit neither string keep existing behavior. Old
frontends ignore these strings. No API, signalling, package version or minimum
runtime change is required. Ship the frontend in the normal runtime artifact; roll
back that artifact to remove this integration. No hosted activation is implied.

Run `npm test --workspace @epicgames-ps/reference-pixelstreamingfrontend-ue5.8`
and build that workspace after building Common, frontend library and UI library.
Tests cover exact matching, both directions, duplicate messages, input suspension,
initial-settings ordering, reconnect authority, manual overrides and disposal.

Browser/Unreal acceptance must cover both transitions, Escape/recapture, held keys
and mouse buttons during transitions, End session dialog suspension, spectator
input restrictions, and refresh/reconnect while Unreal is in free navigation.
Unit tests and bundle compilation do not establish pointer-lock or Blueprint behavior.
