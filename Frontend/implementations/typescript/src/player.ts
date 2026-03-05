// Copyright Epic Games, Inc. All Rights Reserved.

export * from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.7';
export * from '@epicgames-ps/lib-pixelstreamingfrontend-ui-ue5.7';
import {
    Config,
    PixelStreaming,
    Logger,
    LogLevel,
    Flags,
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

const CONNECT_TICKET_PARAM = 'ct';
const RECONNECT_URL_PARAM = 'sm_reconnect_url';
const RECONNECT_REGION_PARAM = 'sm_region';
const RECONNECT_INSTANCE_ID_PARAM = 'sm_instance_id';
const SESSION_MANAGER_RECONNECT_REGION_PARAM = 'reconnectRegion';
const SESSION_MANAGER_RECONNECT_INSTANCE_ID_PARAM = 'reconnectInstanceId';

type ReconnectContext = {
    sessionManagerUrl: string;
    region: string;
    instanceId: string;
};

const getConnectTicketStorageKey = (): string =>
    `sw-connect-ticket:${window.location.host}${window.location.pathname}`;

const getReconnectContextStorageKey = (): string =>
    `sw-reconnect-context:${window.location.host}${window.location.pathname}`;

const readSessionStorage = (key: string): string | null => {
    try {
        return window.sessionStorage.getItem(key);
    } catch {
        return null;
    }
};

const writeSessionStorage = (key: string, value: string) => {
    try {
        window.sessionStorage.setItem(key, value);
    } catch {
        // Ignore storage failures.
    }
};

const removeSessionStorage = (key: string) => {
    try {
        window.sessionStorage.removeItem(key);
    } catch {
        // Ignore storage failures.
    }
};

const parseReconnectContext = (
    sessionManagerUrl: string | null,
    region: string | null,
    instanceId: string | null
): ReconnectContext | null => {
    const normalizedSessionManagerUrl = sessionManagerUrl?.trim() ?? '';
    const normalizedRegion = region?.trim() ?? '';
    const normalizedInstanceId = instanceId?.trim() ?? '';

    if (!normalizedSessionManagerUrl || !normalizedRegion || !normalizedInstanceId) {
        return null;
    }

    try {
        new URL(normalizedSessionManagerUrl);
    } catch {
        return null;
    }

    return {
        sessionManagerUrl: normalizedSessionManagerUrl,
        region: normalizedRegion,
        instanceId: normalizedInstanceId
    };
};

const loadReconnectContextFromStorage = (key: string): ReconnectContext | null => {
    const raw = readSessionStorage(key);
    if (!raw) {
        return null;
    }

    try {
        const parsed = JSON.parse(raw) as Partial<ReconnectContext>;
        return parseReconnectContext(
            typeof parsed.sessionManagerUrl === 'string' ? parsed.sessionManagerUrl : null,
            typeof parsed.region === 'string' ? parsed.region : null,
            typeof parsed.instanceId === 'string' ? parsed.instanceId : null
        );
    } catch {
        return null;
    }
};

const buildSessionManagerReconnectUrl = (context: ReconnectContext): string | null => {
    try {
        const reconnectUrl = new URL(context.sessionManagerUrl);
        reconnectUrl.searchParams.set(
            SESSION_MANAGER_RECONNECT_REGION_PARAM,
            context.region
        );
        reconnectUrl.searchParams.set(
            SESSION_MANAGER_RECONNECT_INSTANCE_ID_PARAM,
            context.instanceId
        );
        return reconnectUrl.toString();
    } catch {
        return null;
    }
};

const isConnectTicketDisconnectReason = (reason: string): boolean => {
    const normalized = reason.trim().toLowerCase();
    if (!normalized) {
        return false;
    }

    return (
        normalized.includes('connect ticket') ||
        normalized.includes('ct is required') ||
        normalized.includes('ticket') ||
        normalized.includes('token') ||
        normalized.includes('unauthorized') ||
        normalized.includes('forbidden') ||
        normalized.includes('401') ||
        normalized.includes('expired')
    );
};

document.body.onload = function() {
    Logger.InitLogging(LogLevel.Warning, true);

    const pageUrl = new URL(window.location.href);
    const connectTicketStorageKey = getConnectTicketStorageKey();
    const reconnectContextStorageKey = getReconnectContextStorageKey();
    const connectTicketFromQuery =
        pageUrl.searchParams.get(CONNECT_TICKET_PARAM)?.trim() ?? '';
    const reconnectContextFromQuery = parseReconnectContext(
        pageUrl.searchParams.get(RECONNECT_URL_PARAM),
        pageUrl.searchParams.get(RECONNECT_REGION_PARAM),
        pageUrl.searchParams.get(RECONNECT_INSTANCE_ID_PARAM)
    );

    const hasReconnectQueryParams =
        pageUrl.searchParams.has(RECONNECT_URL_PARAM) ||
        pageUrl.searchParams.has(RECONNECT_REGION_PARAM) ||
        pageUrl.searchParams.has(RECONNECT_INSTANCE_ID_PARAM);
    const hasConnectTicketQueryParam = pageUrl.searchParams.has(CONNECT_TICKET_PARAM);

    if (connectTicketFromQuery) {
        writeSessionStorage(connectTicketStorageKey, connectTicketFromQuery);
    }
    if (reconnectContextFromQuery) {
        writeSessionStorage(
            reconnectContextStorageKey,
            JSON.stringify(reconnectContextFromQuery)
        );
    }

    const connectTicket =
        connectTicketFromQuery || readSessionStorage(connectTicketStorageKey)?.trim() || '';
    const reconnectContext =
        reconnectContextFromQuery ??
        loadReconnectContextFromStorage(reconnectContextStorageKey);

    if (hasConnectTicketQueryParam || hasReconnectQueryParams) {
        pageUrl.searchParams.delete(CONNECT_TICKET_PARAM);
        pageUrl.searchParams.delete(RECONNECT_URL_PARAM);
        pageUrl.searchParams.delete(RECONNECT_REGION_PARAM);
        pageUrl.searchParams.delete(RECONNECT_INSTANCE_ID_PARAM);
        window.history.replaceState(null, '', pageUrl.toString());
    }

    const redirectToSessionManagerForReconnect = (reason: string): boolean => {
        if (!reconnectContext) {
            return false;
        }

        const reconnectUrl = buildSessionManagerReconnectUrl(reconnectContext);
        if (!reconnectUrl) {
            return false;
        }

        Logger.Warning(
            `Redirecting to session manager to refresh connect ticket (${reason}).`
        );
        removeSessionStorage(connectTicketStorageKey);
        window.location.replace(reconnectUrl);
        return true;
    };

    if (!connectTicket) {
        if (redirectToSessionManagerForReconnect('missing ct token')) {
            return;
        }
        Logger.Warning(
            'Connect ticket (ct) missing and no reconnect context found. Continuing without ticket.'
        );
    }

    // Create a config object.
    // Explicitly keep hovering mouse as the default for this project.
    const config = new Config({
        useUrlParams: true,
        initialSettings: {
            [Flags.HoveringMouseMode]: true
        }
    });

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

    stream.addEventListener('webRtcDisconnected', (event) => {
        const eventData = (event as { data?: { eventString?: string } }).data;
        const reason = eventData?.eventString ?? '';
        if (!isConnectTicketDisconnectReason(reason)) {
            return;
        }

        redirectToSessionManagerForReconnect(reason);
    });

    const application = new Application({
        stream,
        onColorModeChanged: (isLightMode) => PixelStreamingApplicationStyles.setColorMode(isLightMode)
    });
    document.body.appendChild(application.rootElement);

    window.pixelStreaming = stream;
}
