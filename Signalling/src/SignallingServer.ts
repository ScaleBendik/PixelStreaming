// Copyright Epic Games, Inc. All Rights Reserved.
import http from 'http';
import https from 'https';
import * as wslib from 'ws';
import { StreamerConnection } from './StreamerConnection';
import { PlayerConnection } from './PlayerConnection';
import { SFUConnection } from './SFUConnection';
import { Logger } from './Logger';
import { StreamerRegistry } from './StreamerRegistry';
import { PlayerRegistry } from './PlayerRegistry';
import { IceCandidateMonitor, IceCandidateMonitorOptions } from './IceCandidateMonitor';
import { Messages, MessageHelpers, SignallingProtocol } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.7';
import { stringify } from './Utils';

const SCALEWORLD_SESSION_ID_PARAM = 'sm_session_id';
const SCALEWORLD_SESSION_REQUEST_ID_PARAM = 'sm_session_request_id';

type ValidatedConnectTicketIdentity = {
    sessionRequestId: string;
    activeSessionId?: string;
};

type AuthenticatedIncomingMessage = http.IncomingMessage & {
    scaleWorldValidatedConnectTicketIdentity?: ValidatedConnectTicketIdentity;
    scaleWorldConnectTicketIdentityValidated?: boolean;
};

function readScaleWorldQueryParam(request: http.IncomingMessage, name: string): string | undefined {
    try {
        const parsed = new URL(request.url || '/', 'http://localhost');
        const value = parsed.searchParams.get(name)?.trim() ?? '';
        return value || undefined;
    } catch {
        return undefined;
    }
}

function readScaleWorldSessionId(request: http.IncomingMessage): string | undefined {
    return readScaleWorldQueryParam(request, SCALEWORLD_SESSION_ID_PARAM);
}

function readScaleWorldSessionRequestId(request: http.IncomingMessage): string | undefined {
    return readScaleWorldQueryParam(request, SCALEWORLD_SESSION_REQUEST_ID_PARAM);
}

function readRequestPathname(request: http.IncomingMessage): string {
    try {
        return new URL(request.url || '/', 'http://localhost').pathname || '/';
    } catch {
        return '/';
    }
}

function readValidatedConnectTicketIdentity(
    request: http.IncomingMessage
): ValidatedConnectTicketIdentity | undefined {
    const authenticatedRequest = request as AuthenticatedIncomingMessage;
    if (authenticatedRequest.scaleWorldConnectTicketIdentityValidated !== true) {
        return undefined;
    }

    const identity = authenticatedRequest.scaleWorldValidatedConnectTicketIdentity;
    const sessionRequestId = identity?.sessionRequestId?.trim() ?? '';
    const activeSessionId = identity?.activeSessionId?.trim() || undefined;
    if (!sessionRequestId) {
        return undefined;
    }

    return {
        sessionRequestId,
        activeSessionId
    };
}

/**
 * An interface describing the possible options to pass when creating
 * a new SignallingServer object.
 */
export interface IServerConfig {
    // An http server to use for player connections rather than a port. Not needed if playerPort or httpsServer supplied.
    httpServer?: http.Server;

    // An https server to use for player connections rather than a port. Not needed if playerPort or httpServer supplied.
    httpsServer?: https.Server;

    // The port to listen on for streamer connections.
    streamerPort: number;

    // The port to listen on for player connections. Not needed if httpServer or httpsServer supplied.
    playerPort?: number;

    // The port to listen on for SFU connections. If not supplied SFU connections will be disabled.
    sfuPort?: number;

    // The peer configuration object to send to peers in the config message when they connect.
    peerOptions: unknown;

    // Optional peer configuration object to send specifically to player peers.
    peerOptionsPlayer?: unknown;

    // Optional peer configuration object to send specifically to streamer peers.
    peerOptionsStreamer?: unknown;

    // Additional websocket options for the streamer listening websocket.
    streamerWsOptions?: wslib.ServerOptions;

    // Additional websocket options for the player listening websocket.
    playerWsOptions?: wslib.ServerOptions;

    // Additional websocket options for the SFU listening websocket.
    sfuWsOptions?: wslib.ServerOptions;

    // Max number of players per streamer.
    maxSubscribers?: number;

    // Enables websocket ping/pong keepalive for player connections.
    playerKeepalive?: boolean;

    // Interval in milliseconds between player keepalive checks.
    playerKeepaliveIntervalMs?: number;

    // Number of consecutive missed pongs before terminating a player connection.
    playerKeepaliveMaxMissedPongs?: number;

    // Passive ICE candidate summary logging for player/streamer candidate types.
    iceCandidateSummary?: boolean;

    // Quiet period before emitting a per-player ICE candidate summary.
    iceCandidateSummaryDelayMs?: number;

    // Maximum player candidate summaries tracked in memory at once.
    iceCandidateSummaryMaxTrackedPlayers?: number;
}

export type ProtocolConfig = {
    [key: string]: any;
};

function formatUnknownValue(rawValue: unknown): string {
    if (
        typeof rawValue === 'string' ||
        typeof rawValue === 'number' ||
        typeof rawValue === 'boolean' ||
        typeof rawValue === 'bigint'
    ) {
        return String(rawValue);
    }

    return Object.prototype.toString.call(rawValue);
}

function parseBooleanOption(rawValue: unknown, fallback: boolean, label: string): boolean {
    if (typeof rawValue === 'boolean') {
        return rawValue;
    }
    if (rawValue === undefined || rawValue === null) {
        return fallback;
    }

    const text = formatUnknownValue(rawValue).trim().toLowerCase();
    switch (text) {
        case '1':
        case 'true':
        case 'yes':
        case 'on':
            return true;
        case '0':
        case 'false':
        case 'no':
        case 'off':
            return false;
        default:
            Logger.warn(`Invalid ${label} value '${text}'. Using fallback ${fallback}.`);
            return fallback;
    }
}

function parseMinIntegerOption(rawValue: unknown, fallback: number, minValue: number, label: string): number {
    if (rawValue === undefined || rawValue === null || rawValue === '') {
        return fallback;
    }

    const text = formatUnknownValue(rawValue);
    const parsed = Number.parseInt(text, 10);
    if (Number.isNaN(parsed) || parsed < minValue) {
        Logger.warn(`Invalid ${label} value '${text}'. Using fallback ${fallback}.`);
        return fallback;
    }

    return parsed;
}

interface IPlayerKeepaliveState {
    missedPongs: number;
    remoteAddress?: string;
}

/**
 * The main signalling server object.
 * Contains a streamer and player registry and handles setting up of websockets
 * to listen for incoming connections.
 */
export class SignallingServer {
    config: IServerConfig;
    protocolConfig: ProtocolConfig;
    protocolConfigPlayer: ProtocolConfig;
    protocolConfigStreamer: ProtocolConfig;
    streamerRegistry: StreamerRegistry;
    playerRegistry: PlayerRegistry;
    startTime: Date;
    private playerKeepaliveEnabled: boolean;
    private playerKeepaliveIntervalMs: number;
    private playerKeepaliveMaxMissedPongs: number;
    private playerKeepaliveTimer: NodeJS.Timeout | null;
    private playerKeepaliveState: Map<wslib.WebSocket, IPlayerKeepaliveState>;
    readonly iceCandidateMonitor: IceCandidateMonitor;

    /**
     * Initializes the server object and sets up listening sockets for streamers
     * players and optionally SFU connections.
     * @param config - A collection of options for this server.
     */
    constructor(config: IServerConfig) {
        Logger.debug('Started SignallingServer with config: %s', stringify(config));

        this.config = config;
        this.streamerRegistry = new StreamerRegistry();
        this.playerRegistry = new PlayerRegistry();
        const sharedPeerOptions = this.config.peerOptions || {};
        const playerPeerOptions = this.config.peerOptionsPlayer || sharedPeerOptions;
        const streamerPeerOptions = this.config.peerOptionsStreamer || sharedPeerOptions;
        this.protocolConfig = {
            protocolVersion: SignallingProtocol.SIGNALLING_VERSION,
            peerConnectionOptions: sharedPeerOptions
        };
        this.protocolConfigPlayer = {
            protocolVersion: SignallingProtocol.SIGNALLING_VERSION,
            peerConnectionOptions: playerPeerOptions
        };
        this.protocolConfigStreamer = {
            protocolVersion: SignallingProtocol.SIGNALLING_VERSION,
            peerConnectionOptions: streamerPeerOptions
        };
        this.startTime = new Date();
        this.playerKeepaliveEnabled = parseBooleanOption(
            this.config.playerKeepalive,
            true,
            'playerKeepalive'
        );
        this.playerKeepaliveIntervalMs = parseMinIntegerOption(
            this.config.playerKeepaliveIntervalMs,
            30_000,
            1_000,
            'playerKeepaliveIntervalMs'
        );
        this.playerKeepaliveMaxMissedPongs = parseMinIntegerOption(
            this.config.playerKeepaliveMaxMissedPongs,
            2,
            1,
            'playerKeepaliveMaxMissedPongs'
        );
        this.playerKeepaliveTimer = null;
        this.playerKeepaliveState = new Map();
        this.iceCandidateMonitor = new IceCandidateMonitor({
            enabled: this.config.iceCandidateSummary,
            summaryDelayMs: this.config.iceCandidateSummaryDelayMs,
            maxTrackedPlayers: this.config.iceCandidateSummaryMaxTrackedPlayers
        } satisfies IceCandidateMonitorOptions);

        if (!config.playerPort && !config.httpServer && !config.httpsServer) {
            Logger.error('No player port, http server or https server supplied to SignallingServer.');
            return;
        }

        // Streamer connections
        const streamerServer = new wslib.WebSocketServer({
            port: config.streamerPort,
            backlog: 1,
            ...config.streamerWsOptions
        });
        streamerServer.on('connection', this.onStreamerConnected.bind(this));
        Logger.info(`Listening for streamer connections on port ${config.streamerPort}`);

        // Player connections
        const server = config.httpsServer || config.httpServer;
        const playerServer = new wslib.WebSocketServer({
            server: server,
            port: server ? undefined : config.playerPort,
            ...config.playerWsOptions
        });
        playerServer.on('connection', this.onPlayerConnected.bind(this));
        if (!config.httpServer && !config.httpsServer) {
            Logger.info(`Listening for player connections on port ${config.playerPort}`);
        }
        this.initializePlayerKeepaliveWatchdog();

        // Optional SFU connections
        if (config.sfuPort) {
            const sfuServer = new wslib.WebSocketServer({
                port: config.sfuPort,
                backlog: 1,
                ...config.sfuWsOptions
            });
            sfuServer.on('connection', this.onSFUConnected.bind(this));
            Logger.info(`Listening for SFU connections on port ${config.sfuPort}`);
        }
    }

    private onStreamerConnected(ws: wslib.WebSocket, request: http.IncomingMessage) {
        Logger.info(`New streamer connection: %s`, request.socket.remoteAddress);

        const newStreamer = new StreamerConnection(this, ws, request.socket.remoteAddress);
        newStreamer.maxSubscribers = this.config.maxSubscribers || 0;

        // The streamer protocol requires config -> identify -> endpointId. In particular,
        // Pixel Streaming 2 may initialize its EpicRtc room as soon as identify arrives,
        // so sending identify first can race application of the ICE-server configuration.
        const message: Messages.config = MessageHelpers.createMessage(
            Messages.config,
            this.protocolConfigStreamer
        );
        // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
        message.peerConnectionOptions = this.protocolConfigStreamer['peerConnectionOptions'];
        newStreamer.sendMessage(message);

        // add it to the registry and when the transport closes, remove it.
        this.streamerRegistry.add(newStreamer);
        newStreamer.transport.on('close', () => {
            this.streamerRegistry.remove(newStreamer);
            Logger.info(
                `Streamer %s (%s) disconnected.`,
                newStreamer.streamerId,
                request.socket.remoteAddress
            );
        });
    }

    private onPlayerConnected(ws: wslib.WebSocket, request: http.IncomingMessage) {
        Logger.info(
            `New player connection: %s (path=%s, query=redacted)`,
            request.socket.remoteAddress,
            readRequestPathname(request)
        );

        const newPlayer = new PlayerConnection(this, ws, request.socket.remoteAddress);
        const validatedIdentity = readValidatedConnectTicketIdentity(request);
        const scaleWorldSessionId = validatedIdentity?.activeSessionId ?? readScaleWorldSessionId(request);
        if (scaleWorldSessionId) {
            newPlayer.scaleWorldSessionId = scaleWorldSessionId;
        }
        const scaleWorldSessionRequestId =
            validatedIdentity?.sessionRequestId ?? readScaleWorldSessionRequestId(request);
        if (scaleWorldSessionRequestId) {
            newPlayer.scaleWorldSessionRequestId = scaleWorldSessionRequestId;
        }
        newPlayer.scaleWorldSessionIdentityValidated = validatedIdentity !== undefined;
        newPlayer.scaleWorldActiveSessionIdValidated = validatedIdentity?.activeSessionId !== undefined;
        this.registerPlayerKeepalive(ws, request.socket.remoteAddress);

        // add it to the registry and when the transport closes, remove it
        this.playerRegistry.add(newPlayer);
        newPlayer.transport.on('close', () => {
            this.unregisterPlayerKeepalive(ws);
            this.playerRegistry.remove(newPlayer);
            Logger.info(`Player %s (%s) disconnected.`, newPlayer.playerId, request.socket.remoteAddress);
        });

        // because peer connection options is a general field with all optional fields
        // it doesnt play nice with mergePartial so we just add it verbatim
        const message: Messages.config = MessageHelpers.createMessage(
            Messages.config,
            this.protocolConfigPlayer
        );
        // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
        message.peerConnectionOptions = this.protocolConfigPlayer['peerConnectionOptions'];
        newPlayer.sendMessage(message);
    }

    private onSFUConnected(ws: wslib.WebSocket, request: http.IncomingMessage) {
        Logger.info(`New SFU connection: %s`, request.socket.remoteAddress);
        const newSFU = new SFUConnection(this, ws, request.socket.remoteAddress);

        // SFU acts as both a streamer and player
        this.streamerRegistry.add(newSFU);
        this.playerRegistry.add(newSFU);
        newSFU.transport.on('close', () => {
            this.streamerRegistry.remove(newSFU);
            this.playerRegistry.remove(newSFU);
            Logger.info(`SFU %s (%s) disconnected.`, newSFU.streamerId, request.socket.remoteAddress);
        });

        // because peer connection options is a general field with all optional fields
        // it doesnt play nice with mergePartial so we just add it verbatim
        const message: Messages.config = MessageHelpers.createMessage(Messages.config, this.protocolConfig);
        // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
        message.peerConnectionOptions = this.protocolConfig['peerConnectionOptions'];
        newSFU.sendMessage(message);
    }

    private initializePlayerKeepaliveWatchdog(): void {
        if (!this.playerKeepaliveEnabled) {
            Logger.info('[player-keepalive] Disabled.');
            return;
        }

        this.playerKeepaliveTimer = setInterval(() => {
            this.runPlayerKeepaliveTick();
        }, this.playerKeepaliveIntervalMs);
        this.playerKeepaliveTimer.unref();

        Logger.info(
            `[player-keepalive] Enabled (intervalMs=${this.playerKeepaliveIntervalMs}, maxMissedPongs=${this.playerKeepaliveMaxMissedPongs}).`
        );
    }

    private registerPlayerKeepalive(ws: wslib.WebSocket, remoteAddress?: string): void {
        if (!this.playerKeepaliveEnabled) {
            return;
        }

        this.playerKeepaliveState.set(ws, { missedPongs: 0, remoteAddress });
        ws.on('pong', () => {
            const state = this.playerKeepaliveState.get(ws);
            if (!state) {
                return;
            }

            state.missedPongs = 0;
        });
        ws.on('close', () => {
            this.unregisterPlayerKeepalive(ws);
        });
    }

    private unregisterPlayerKeepalive(ws: wslib.WebSocket): void {
        if (!this.playerKeepaliveEnabled) {
            return;
        }

        this.playerKeepaliveState.delete(ws);
    }

    private runPlayerKeepaliveTick(): void {
        for (const [ws, state] of this.playerKeepaliveState.entries()) {
            if (ws.readyState !== wslib.WebSocket.OPEN) {
                this.playerKeepaliveState.delete(ws);
                continue;
            }

            if (state.missedPongs >= this.playerKeepaliveMaxMissedPongs) {
                Logger.warn(
                    `[player-keepalive] Terminating stale player connection (${state.remoteAddress || 'unknown'}). Missed pongs=${state.missedPongs}.`
                );
                this.playerKeepaliveState.delete(ws);
                ws.terminate();
                continue;
            }

            state.missedPongs++;
            try {
                ws.ping();
            } catch (error) {
                const message = error instanceof Error ? error.message : 'unknown error';
                Logger.warn(
                    `[player-keepalive] Ping failed for player connection (${state.remoteAddress || 'unknown'}): ${message}. Terminating socket.`
                );
                this.playerKeepaliveState.delete(ws);
                ws.terminate();
            }
        }
    }
}
