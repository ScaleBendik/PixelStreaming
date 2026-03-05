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
const EXPIRED_CONNECTION_GUIDANCE =
    'Connection expired. Go to scaleworld.scaleaq.com and click connect again to continue your session';
const RECONNECT_BOOTSTRAP_QUERY_PARAMS = new Set<string>([
    CONNECT_TICKET_PARAM,
    RECONNECT_URL_PARAM,
    RECONNECT_REGION_PARAM,
    RECONNECT_INSTANCE_ID_PARAM
]);

type ReconnectContext = {
    sessionManagerUrl: string;
    region: string;
    instanceId: string;
};

const getConnectTicketStorageKey = (): string =>
    `sw-connect-ticket:${window.location.host}${window.location.pathname}`;

const getReconnectContextStorageKey = (): string =>
    `sw-reconnect-context:${window.location.host}${window.location.pathname}`;

const getPlayerQueryStateStorageKey = (): string =>
    `sw-player-query-state:${window.location.host}${window.location.pathname}`;

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

const toRestorablePlayerQueryString = (params: URLSearchParams): string => {
    const restorable = new URLSearchParams();
    params.forEach((value, key) => {
        if (RECONNECT_BOOTSTRAP_QUERY_PARAMS.has(key)) {
            return;
        }

        restorable.append(key, value);
    });

    return restorable.toString();
};

const applyQueryString = (params: URLSearchParams, queryString: string): void => {
    const source = new URLSearchParams(queryString);
    source.forEach((value, key) => {
        params.append(key, value);
    });
};

const persistPlayerQueryState = (storageKey: string): void => {
    const currentUrl = new URL(window.location.href);
    const queryString = toRestorablePlayerQueryString(currentUrl.searchParams);
    if (queryString) {
        writeSessionStorage(storageKey, queryString);
        return;
    }

    removeSessionStorage(storageKey);
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

const parseConnectTicketExpiryMs = (ticket: string): number | null => {
    const trimmedTicket = ticket.trim();
    if (!trimmedTicket) {
        return null;
    }

    const segments = trimmedTicket.split('.');
    if (segments.length < 2) {
        return null;
    }

    try {
        const base64 = segments[1].replace(/-/g, '+').replace(/_/g, '/');
        const payloadJson = atob(base64);
        const payload = JSON.parse(payloadJson) as { exp?: unknown };
        if (typeof payload.exp !== 'number') {
            return null;
        }

        return payload.exp * 1000;
    } catch {
        return null;
    }
};

const showExpiredConnectionGuidance = () => {
    // Run after overlay updates so this text wins over generic "Disconnected".
    window.setTimeout(() => {
        const disconnectOverlayText = document.getElementById('disconnectButton');
        if (disconnectOverlayText) {
            disconnectOverlayText.innerHTML = EXPIRED_CONNECTION_GUIDANCE;
        }

        const errorOverlayText = document.getElementById('errorOverlayInner');
        if (errorOverlayText) {
            errorOverlayText.innerHTML = EXPIRED_CONNECTION_GUIDANCE;
        }
    }, 0);
};

document.body.onload = function() {
    Logger.InitLogging(LogLevel.Warning, true);

    const pageUrl = new URL(window.location.href);
    const connectTicketStorageKey = getConnectTicketStorageKey();
    const reconnectContextStorageKey = getReconnectContextStorageKey();
    const playerQueryStateStorageKey = getPlayerQueryStateStorageKey();
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
    const restorablePlayerQueryFromUrl = toRestorablePlayerQueryString(
        pageUrl.searchParams
    );

    if (connectTicketFromQuery) {
        writeSessionStorage(connectTicketStorageKey, connectTicketFromQuery);
    }
    if (reconnectContextFromQuery) {
        writeSessionStorage(
            reconnectContextStorageKey,
            JSON.stringify(reconnectContextFromQuery)
        );
    }
    if (restorablePlayerQueryFromUrl) {
        writeSessionStorage(playerQueryStateStorageKey, restorablePlayerQueryFromUrl);
    } else if (!hasConnectTicketQueryParam && !hasReconnectQueryParams) {
        removeSessionStorage(playerQueryStateStorageKey);
    }

    const connectTicket =
        connectTicketFromQuery || readSessionStorage(connectTicketStorageKey)?.trim() || '';
    const connectTicketExpiresAtMs = connectTicket
        ? parseConnectTicketExpiryMs(connectTicket)
        : null;
    const reconnectContext =
        reconnectContextFromQuery ??
        loadReconnectContextFromStorage(reconnectContextStorageKey);
    const storedPlayerQuery =
        readSessionStorage(playerQueryStateStorageKey)?.trim() ?? '';

    if (hasConnectTicketQueryParam || hasReconnectQueryParams) {
        pageUrl.searchParams.delete(CONNECT_TICKET_PARAM);
        pageUrl.searchParams.delete(RECONNECT_URL_PARAM);
        pageUrl.searchParams.delete(RECONNECT_REGION_PARAM);
        pageUrl.searchParams.delete(RECONNECT_INSTANCE_ID_PARAM);
        if (!restorablePlayerQueryFromUrl && storedPlayerQuery) {
            applyQueryString(pageUrl.searchParams, storedPlayerQuery);
        }
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
        persistPlayerQueryState(playerQueryStateStorageKey);
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
        const isConnectTicketDisconnect =
            isConnectTicketDisconnectReason(reason) ||
            (connectTicketExpiresAtMs !== null && Date.now() >= connectTicketExpiresAtMs);
        if (!isConnectTicketDisconnect) {
            return;
        }

        const redirected = redirectToSessionManagerForReconnect(reason);
        if (!redirected) {
            showExpiredConnectionGuidance();
        }
    });

    const application = new Application({
        stream,
        onColorModeChanged: (isLightMode) => PixelStreamingApplicationStyles.setColorMode(isLightMode)
    });
    document.body.appendChild(application.rootElement);

    window.pixelStreaming = stream;
}
