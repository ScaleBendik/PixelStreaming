# Streaming End session control

The TypeScript reference player owns the toolbar button and native confirmation
in Frontend/implementations/typescript/src/endSession.ts. player.ts supplies the
managed owner context, environment-specific manager origin, input isolation and
reconnect controls. No Unreal package or Wilbur shutdown endpoint is changed.

The authenticated manager initiates an exact-origin, request-bound MessageChannel.
Confirmation probes the live channel before sending an end request. The player
closes only after acceptance or the existing runtime session-ended notification;
failure retains the tab with a manager confirmation link. Shadow viewers do not
receive the destructive control. Decoding ticket claims is display-only.

The protocol, timeouts, fallback URL, deployment order and hosted acceptance gates
are owned by [the web integration contract](../../scaleworld-server-manager-web/docs/pixelstreaming-session-end-control.md).

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

## Browser isolation and manager lifetime

The deployed Dev manager sends Cross-Origin-Opener-Policy: same-origin while the
player is on a different origin. This separates browsing context groups and
severs the retained popup reference, so the MessageChannel bridge is unavailable
even when both tabs are open. Do not weaken COOP to enable this feature. The
bridge is an optional optimization only where browser policy permits it. It also
depends on the launching SessionAccessPage remaining mounted; switching admin
views, reloading or closing the manager can invalidate it. Server Ops launches
do not currently install this bridge.

Without a usable bridge, the player presents an enabled Continue in session
manager action. Clicking it navigates the stream tab to the exact-session intent
URL; it does not stop the session or close the tab. The authenticated manager
requires confirmation and validates ownership and request identity before stopping.
This handoff replaces the stream page, so cancellation there requires re-entering
the stream. A direct in-player end under strict COOP remains separate server-
mediated design work; keeping another manager tab open is not sufficient.

Acceptance must test the actual hosted COOP headers, manager view navigation,
manager reload and Server Ops entry, as well as healthy-channel operation.
