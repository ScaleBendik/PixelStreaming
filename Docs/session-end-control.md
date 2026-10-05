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
