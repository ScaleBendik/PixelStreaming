import { Logger } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';
import { Config, Flags, NumericParameters } from '../Config/Config';
import { mockRTCRtpReceiver, unmockRTCRtpReceiver } from '../__test__/mockRTCRtpReceiver';
import { VideoPlayer } from './VideoPlayer';

/**
 * Tests for the ViewportResScale numeric parameter added to VideoPlayer.
 *
 * The callback onMatchViewportResolutionCallback is invoked with the scaled
 * viewport dimensions when MatchViewportResolution is enabled. We validate:
 *   - default scale (1.0) leaves dimensions unchanged
 *   - explicit scale multiplies both dimensions
 *   - non-integer products are rounded to integers
 *   - dimensions > 4096 emit a warning via Logger
 *   - a Config missing the setting falls back to 1.0 instead of throwing
 */
describe('VideoPlayer.updateVideoStreamSize — ViewportResScale', () => {
    let parent: HTMLDivElement;
    let config: Config;
    let player: VideoPlayer;
    let callback: jest.Mock;

    const setViewportSize = (w: number, h: number) => {
        Object.defineProperty(parent, 'clientWidth', { configurable: true, value: w });
        Object.defineProperty(parent, 'clientHeight', { configurable: true, value: h });
    };

    beforeEach(() => {
        mockRTCRtpReceiver();
        parent = document.createElement('div');
        document.body.appendChild(parent);

        config = new Config({ initialSettings: { [Flags.MatchViewportResolution]: true } });

        player = new VideoPlayer(parent, config);
        callback = jest.fn();
        player.onMatchViewportResolutionCallback = callback;

        // Bypass the 300ms throttle in updateVideoStreamSize.
        (player as unknown as { lastTimeResized: number }).lastTimeResized = 0;
    });

    afterEach(() => {
        player.destroy();
        parent.remove();
        unmockRTCRtpReceiver();
        jest.restoreAllMocks();
    });

    it('passes viewport dimensions through unchanged when scale is 1.0 (default)', () => {
        setViewportSize(375, 667);
        player.updateVideoStreamSize();
        expect(callback).toHaveBeenCalledWith(375, 667);
    });

    it('caps configured and initial viewport scales at one', () => {
        config.setNumericSetting(NumericParameters.ViewportResScale, 3);
        expect(config.getNumericSettingValue(NumericParameters.ViewportResScale)).toBe(1);
        const initial = new Config({ initialSettings: { [NumericParameters.ViewportResScale]: 2 } });
        expect(initial.getNumericSettingValue(NumericParameters.ViewportResScale)).toBe(1);
    });

    it('multiplies both dimensions by the configured scale', () => {
        config.setNumericSetting(NumericParameters.ViewportResScale, 0.5);
        setViewportSize(375, 667);

        // lastTimeResized was updated on construction, reset again.
        (player as unknown as { lastTimeResized: number }).lastTimeResized = 0;
        player.updateVideoStreamSize();

        expect(callback).toHaveBeenCalledWith(188, 334);
    });

    it('rounds non-integer products to integers', () => {
        config.setNumericSetting(NumericParameters.ViewportResScale, 0.75);
        setViewportSize(375, 667);

        (player as unknown as { lastTimeResized: number }).lastTimeResized = 0;
        player.updateVideoStreamSize();

        // Fractional scales round both dimensions.
        expect(callback).toHaveBeenCalledWith(281, 500);
        const [w, h] = callback.mock.calls[0] as [number, number];
        expect(Number.isInteger(w)).toBe(true);
        expect(Number.isInteger(h)).toBe(true);
    });

    it('logs a warning when scaled width or height exceeds 4096', () => {
        const warnSpy = jest.spyOn(Logger, 'Warning').mockImplementation(() => {});

        config.setNumericSetting(NumericParameters.ViewportResScale, 3.0);
        setViewportSize(6000, 3000); // Scale is capped at 1, but a wide viewport still warns.

        (player as unknown as { lastTimeResized: number }).lastTimeResized = 0;
        player.updateVideoStreamSize();

        expect(warnSpy).toHaveBeenCalledTimes(1);
        expect(warnSpy.mock.calls[0][0]).toContain('4096');
        expect(warnSpy.mock.calls[0][0]).toContain('6000');
        expect(callback).toHaveBeenCalledWith(6000, 3000);
    });

    it('does not warn when scaled dimensions stay within the encoder limit', () => {
        const warnSpy = jest.spyOn(Logger, 'Warning').mockImplementation(() => {});

        config.setNumericSetting(NumericParameters.ViewportResScale, 0.5);
        setViewportSize(1920, 1080); // 3840 x 2160, under 4096

        (player as unknown as { lastTimeResized: number }).lastTimeResized = 0;
        player.updateVideoStreamSize();

        expect(warnSpy).not.toHaveBeenCalled();
    });

    it('falls back to scale 1.0 when the setting is not registered on the Config', () => {
        const strippedConfig = new Config({ initialSettings: { [Flags.MatchViewportResolution]: true } });
        // Remove the registration to simulate a custom Config subclass that omits it.
        const params = (strippedConfig as unknown as { numericParameters: Map<string, unknown> })
            .numericParameters;
        params.delete(NumericParameters.ViewportResScale);

        const strippedParent = document.createElement('div');
        document.body.appendChild(strippedParent);
        const strippedPlayer = new VideoPlayer(strippedParent, strippedConfig);
        const strippedCallback = jest.fn();
        strippedPlayer.onMatchViewportResolutionCallback = strippedCallback;

        Object.defineProperty(strippedParent, 'clientWidth', { configurable: true, value: 500 });
        Object.defineProperty(strippedParent, 'clientHeight', { configurable: true, value: 400 });

        (strippedPlayer as unknown as { lastTimeResized: number }).lastTimeResized = 0;
        expect(() => strippedPlayer.updateVideoStreamSize()).not.toThrow();
        expect(strippedCallback).toHaveBeenCalledWith(500, 400);

        strippedPlayer.destroy();
        strippedParent.remove();
    });

    it('does not invoke the callback when MatchViewportResolution is disabled', () => {
        config.setFlagEnabled(Flags.MatchViewportResolution, false);
        setViewportSize(375, 667);

        (player as unknown as { lastTimeResized: number }).lastTimeResized = 0;
        player.updateVideoStreamSize();

        expect(callback).not.toHaveBeenCalled();
    });
});

describe('VideoPlayer disposal', () => {
    it('detaches window listeners and cancels deferred resize work', () => {
        mockRTCRtpReceiver();
        jest.useFakeTimers();
        const parent = document.createElement('div');
        document.body.appendChild(parent);
        const config = new Config({ initialSettings: { [Flags.MatchViewportResolution]: true } });
        const player = new VideoPlayer(parent, config);
        const resize = jest.spyOn(player, 'resizePlayerStyle');
        const updateSize = jest.spyOn(player, 'updateVideoStreamSize');
        try {
            window.dispatchEvent(new Event('orientationchange'));
            player.updateVideoStreamSize();
            player.destroy();
            resize.mockClear();
            updateSize.mockClear();

            window.dispatchEvent(new Event('resize'));
            window.dispatchEvent(new Event('orientationchange'));
            jest.runAllTimers();

            expect(resize).not.toHaveBeenCalled();
            expect(updateSize).not.toHaveBeenCalled();
        } finally {
            player.destroy();
            parent.remove();
            unmockRTCRtpReceiver();
            jest.useRealTimers();
            jest.restoreAllMocks();
        }
    });
});
