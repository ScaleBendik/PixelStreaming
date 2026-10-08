import { Flags, type PixelStreaming } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8';

/** Blueprint notifications select a scheme; they never grant input or request pointer lock. */
export function installNavigationMode(stream: PixelStreaming): { dispose: () => void } {
    let hovering: boolean | undefined;
    let disposed = false;
    // Optional UX: failures must not escape ResponseController's shared dispatch loop
    // or prevent the player's explicit connect/bootstrap and other cleanup handlers.
    const bestEffort = (action: () => void) => {
        try { action(); return true; } catch { return false; }
    };
    const apply = () => {
        if (disposed || hovering === undefined) return;
        bestEffort(() => {
            if (stream.config.isFlagEnabled(Flags.HoveringMouseMode) !== hovering) {
                stream.config.setFlagEnabled(Flags.HoveringMouseMode, hovering);
            }
        });
    };
    const onResponse = (response: string) => {
        if (disposed) return;
        if (response === 'Navigation.Free') hovering = false;
        else if (response === 'Navigation.Menu') hovering = true;
        else return;
        apply();
    };
    // InitialSettings can arrive after a response and write DefaultToHover.
    // Only the current connection's explicit navigation state may override it.
    const onDisconnected = () => { hovering = undefined; };
    const dispose = () => {
        disposed = true;
        hovering = undefined;
        bestEffort(() => stream.removeResponseEventListener('scaleWorldNavigationMode'));
        bestEffort(() => stream.removeEventListener('initialSettings', apply));
        bestEffort(() => stream.removeEventListener('webRtcDisconnected', onDisconnected));
    };
    if (!bestEffort(() => {
        stream.addResponseEventListener('scaleWorldNavigationMode', onResponse);
        stream.addEventListener('initialSettings', apply);
        stream.addEventListener('webRtcDisconnected', onDisconnected);
    })) dispose();
    return { dispose };
}
