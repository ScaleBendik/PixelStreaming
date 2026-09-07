// Copyright Epic Games, Inc. All Rights Reserved.
import http from 'http';
import https from 'https';
import * as wslib from 'ws';
import { StreamerConnection } from './StreamerConnection';
import { PlayerConnection } from './PlayerConnection';
import { SFUConnection } from './SFUConnection';
import { Logger } from './Logger';
import { StreamerRegistry, StreamerIdAuthorizer } from './StreamerRegistry';
import { PlayerRegistry } from './PlayerRegistry';
import { IceCandidateMonitor, IceCandidateMonitorOptions } from './IceCandidateMonitor';
import {
    Messages,
    MessageHelpers,
    SignallingProtocol,
    KeepaliveMonitor
} from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';
import { stringify } from './Utils';
import { redactSensitiveLogValue } from './LogRedaction';

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

    // Idle timeout in milliseconds after which a player that has stopped responding to keepalive
    // pings is forcibly disconnected. 0 (the default) disables the check.
    playerKeepaliveTimeout?: number;

    // Optional hook to authorize (or override) the id a streamer registers as when it identifies
    // itself. This is the seam for consumer-supplied anti-squatting / ownership policy; the project
    // ships no authentication of its own. See StreamerIdAuthorizer. When omitted, the default
    // behaviour is unchanged (requested id accepted, numeric suffix appended on collision).
    authorizeStreamerId?: StreamerIdAuthorizer;

    // Optional hook returning the peer configuration to send to a single connecting peer, in place
    // of the static peerOptions. This is the seam for peer configuration that must not be shared
    // between connections - time limited TURN credentials being the motivating case, since a static
    // credential is sent to every peer that ever connects and cannot be changed without a redeploy.
    // See PeerOptionsProvider. When omitted, each peer receives its role-specific static options.
    peerOptionsProvider?: PeerOptionsProvider;
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
 * The kind of peer a set of peer options is being built for. Provided so a consumer can vary what
 * it returns by peer - a streamer connects once and holds its configuration for as long as it runs,
 * where a player receives a fresh one every time it connects.
 */
export type PeerType = 'streamer' | 'player' | 'sfu';

/**
 * Describes the peer that is about to be sent a config message.
 */
export interface IPeerOptionsRequest {
    // The kind of peer connecting.
    peerType: PeerType;
    // The id the registry assigned this peer. For a streamer or an SFU this is the placeholder the
    // registry allocates on connect, because a streamer is not named until it sends its endpointId
    // message, which happens after it has been configured. A player id is final.
    peerId: string;
}

/**
 * An optional consumer-supplied hook that builds the peer configuration for one connecting peer.
 * Return the object to send as peerConnectionOptions in that peer's config message. This is the
 * seam for per-connection credentials without the project committing to a credential scheme of its
 * own. A provider that throws falls back to the static options for that peer role.
 */
export type PeerOptionsProvider = (request: IPeerOptionsRequest) => unknown;

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
        Logger.debug('Started SignallingServer with config: %s', stringify(redactSensitiveLogValue(config)));

        this.config = config;
        this.streamerRegistry = new StreamerRegistry(config.authorizeStreamerId);
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

    private sendConfigMessage(
        connection: { sendMessage(msg: Messages.config): void },
        peerRequest: IPeerOptionsRequest
    ): void {
        // peer connection options is a general field with all optional fields;
        // it doesnt play nice with mergePartial so we just add it verbatim
        const message: Messages.config = MessageHelpers.createMessage(Messages.config, this.protocolConfig);
        message.peerConnectionOptions = this.getPeerOptions(peerRequest);
        connection.sendMessage(message);
    }

    /**
     * Resolves the peer options for one connecting peer, deferring to peerOptionsProvider when the
     * consumer supplied one.
     */
    private getPeerOptions(peerRequest: IPeerOptionsRequest): Messages.config['peerConnectionOptions'] {
        const staticConfig =
            peerRequest.peerType === 'player'
                ? this.protocolConfigPlayer
                : peerRequest.peerType === 'streamer'
                  ? this.protocolConfigStreamer
                  : this.protocolConfig;
        if (!this.config.peerOptionsProvider) {
            // eslint-disable-next-line @typescript-eslint/no-unsafe-return
            return staticConfig['peerConnectionOptions'];
        }

        try {
            // The provider is consumer code, so its return is unknown to us; it travels as an
            // opaque blob in the config message either way.
            return this.config.peerOptionsProvider(peerRequest) as Messages.config['peerConnectionOptions'];
        } catch (error) {
            // A provider is consumer code and may reach outside the process for a credential. If it
            // fails we still send a config message, because a peer that never receives one simply
            // waits forever with nothing in its log to explain why.
            Logger.error(
                'peerOptionsProvider threw for %s peer %s, falling back to the static peer options: %s',
                peerRequest.peerType,
                peerRequest.peerId,
                error instanceof Error ? error.message : stringify(error)
            );
            // eslint-disable-next-line @typescript-eslint/no-unsafe-return
            return staticConfig['peerConnectionOptions'];
        }
    }

    private onStreamerConnected(ws: wslib.WebSocket, request: http.IncomingMessage) {
        Logger.info(`New streamer connection: %s`, request.socket.remoteAddress);

        const newStreamer = new StreamerConnection(this, ws, request.socket.remoteAddress, request);
        newStreamer.maxSubscribers = this.config.maxSubscribers || 0;

        // The streamer protocol requires config -> identify -> endpointId. In particular,
        // Pixel Streaming 2 may initialize its EpicRtc room as soon as identify arrives,
        // so sending identify first can race application of the ICE-server configuration.
        newStreamer.streamerId = this.streamerRegistry.sanitizeStreamerId(newStreamer.streamerId);
        this.sendConfigMessage(newStreamer, { peerType: 'streamer', peerId: newStreamer.streamerId });

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

        const newPlayer = new PlayerConnection(this, ws, request.socket.remoteAddress, request);
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

        // This optional signalling ping/pong monitor is separate from ScaleWorld's websocket
        // control-frame watchdog. It stays disabled unless its timeout is explicitly configured.
        // Optionally monitor the player connection for liveness. A player whose socket dies without
        // a clean close frame (sleeping laptop, dropped Wi-Fi, killed tab) is otherwise only removed
        // once the OS TCP keepalive eventually reaps it, leaving it subscribed in the meantime. When
        // maxSubscribers is set this can hold a slot that no live player is using. We use
        // ws.terminate() rather than a graceful close because a dead peer never completes the close
        // handshake. The monitor stops itself on transport 'close', so no manual teardown is needed.
        const keepaliveTimeout = this.config.playerKeepaliveTimeout || 0;
        if (keepaliveTimeout > 0) {
            const keepalive = new KeepaliveMonitor(newPlayer.protocol, keepaliveTimeout);
            keepalive.onTimeout = () => {
                Logger.info(
                    `Player %s (%s) failed keepalive - terminating dead connection.`,
                    newPlayer.playerId,
                    request.socket.remoteAddress
                );
                ws.terminate();
            };
        }

        this.sendConfigMessage(newPlayer, { peerType: 'player', peerId: newPlayer.playerId });
    }

    private onSFUConnected(ws: wslib.WebSocket, request: http.IncomingMessage) {
        Logger.info(`New SFU connection: %s`, request.socket.remoteAddress);
        const newSFU = new SFUConnection(this, ws, request.socket.remoteAddress, request);

        // SFU acts as both a streamer and player
        this.streamerRegistry.add(newSFU);
        this.playerRegistry.add(newSFU);
        newSFU.transport.on('close', () => {
            this.streamerRegistry.remove(newSFU);
            this.playerRegistry.remove(newSFU);
            Logger.info(`SFU %s (%s) disconnected.`, newSFU.streamerId, request.socket.remoteAddress);
        });

        this.sendConfigMessage(newSFU, { peerType: 'sfu', peerId: newSFU.streamerId });
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
