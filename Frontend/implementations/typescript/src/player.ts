// Copyright Epic Games, Inc. All Rights Reserved.

export * from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.7';
export * from '@epicgames-ps/lib-pixelstreamingfrontend-ui-ue5.7';
import {
    Config,
    PixelStreaming,
    Logger,
    LogLevel,
    TextParameters
} from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.7';
import { Application, PixelStreamingApplicationStyle } from '@epicgames-ps/lib-pixelstreamingfrontend-ui-ue5.7';
const PixelStreamingApplicationStyles =
    new PixelStreamingApplicationStyle();
PixelStreamingApplicationStyles.applyStyleSheet();

// expose the pixel streaming object for hooking into. tests etc.
declare global {
    interface Window { pixelStreaming: PixelStreaming; }
}

document.body.onload = function() {
    Logger.InitLogging(LogLevel.Warning, true);

	// Create a config object
	const config = new Config({ useUrlParams: true });
    const connectTicket = new URL(window.location.href).searchParams.get('ct')?.trim();

	// Create the main Pixel Streaming object for interfacing with the web-API of Pixel Streaming
	const stream = new PixelStreaming(config);
    if (connectTicket) {
        stream.setSignallingUrlBuilder(() => {
            const rawSignallingUrl = config.getTextSettingValue(TextParameters.SignallingServerUrl);
            let parsed: URL;
            try {
                parsed = new URL(rawSignallingUrl);
            } catch {
                parsed = new URL(rawSignallingUrl, window.location.href);
            }

            if (!parsed.searchParams.get('ct')) {
                parsed.searchParams.set('ct', connectTicket);
            }

            return parsed.toString();
        });
    }

	const application = new Application({
		stream,
		onColorModeChanged: (isLightMode) => PixelStreamingApplicationStyles.setColorMode(isLightMode)
	});
	document.body.appendChild(application.rootElement);

	window.pixelStreaming = stream;
}
