# Streaming End session control

The TypeScript reference player owns the toolbar button and native confirmation
in Frontend/implementations/typescript/src/endSession.ts. player.ts supplies the
managed owner context, environment-specific manager origin, input isolation and
reconnect controls. No Unreal package change is required.

With the direct feature enabled, confirmation sends a purpose-specific capability
through Wilbur to the existing API stop operation. The player returns to the manager only after
acceptance or the existing runtime session-ended notification. Failure retains
the tab with a manager confirmation link. Shadow viewers do not receive the
destructive control. The older manager MessageChannel is optional compatibility
behavior when no direct credential exists. Decoding ticket claims is display-only.

The protocol, timeouts, deployment order and hosted acceptance gates are owned by
[the API contract](../../scaleworld-server-manager-api/docs/player-session-end.md).
The [web integration contract](../../scaleworld-server-manager-web/docs/pixelstreaming-session-end-control.md)
describes manager handoff and compatibility.

Run npm test and npm run build in Frontend/implementations/typescript. Browser
acceptance must include fullscreen, input restoration, manager absence and timer
throttling. Shipping source or building locally does not deploy the runtime.

## Player startup safety

Application.createButtons must assign its Controls instance to Application.controls
before the player installs toolbar extensions. A declaration alone does not
initialize that property. The initial End session release read the unassigned
property and threw before stream.connect(), leaving a black player until recovery
guidance appeared. Optional End session initialization is now isolated so its
failure logs a warning and still reaches the normal auto/manual connection path.

Regression coverage executes the real toolbar creation in the UI library and the
full player onload bootstrap with healthy, missing-toolbar and throwing-extension
cases. Build both UI-library module formats before bundling the player; runtime
artifacts must include the rebuilt UI library. Hosted acceptance must establish
a presented frame, the visible End session control and working confirmation.
A manager connect acknowledgement alone does not establish usable media.

## Direct end and compatibility

With a current owner end capability, the player confirms and calls the same-origin
/api/session-end relay. Wilbur forwards only the narrow credential and expected
request ID to the fixed API endpoint. The manager tab and MessageChannel are not
needed. The API automatically issues an opaque token and stores only its hash in SQL.

The [owning API/runtime contract](../../scaleworld-server-manager-api/docs/player-session-end.md)
defines authorization, expiry, rollout and hosted acceptance. No additional secret or enable flag is required. Use the updated API and direct-end
runtime, then a fresh Connect. Missing or
expired credentials retain the optional old bridge / authenticated manager handoff.
Do not weaken the manager COOP header. Accepted direct stops persist an API feedback
reminder; the manager offers feedback on return. Stop/recycle and artifact ownership
remain in the API. The owner button shows 'Click here to end your session' for seven
seconds after the first connection, hiding immediately when its dialog opens.

The relay accepts only explicit GET (status) and POST (end). Express also routes
HEAD through GET handlers, so reject HEAD with 405 before forwarding; never map
an unknown method to POST. An HTTP regression test covers the real routing.

After confirmed end, navigate this tab to the configured manager /servers/ page. Do not call window.close or depend on opener focus: browser tab selection is unreliable. This return carries no end intent and cannot trigger a second stop. The manager displays pending feedback inline beneath its session status.
