// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'node:crypto';
import {
    CodecTicketPolicy,
    CodecEvidence,
    VideoCodec,
    videoCodecs,
    restrictVideoSdp,
    validateCodecAnswer
} from './CodecPolicy';
import type { IncomingMessage } from 'http';
import WebSocket from 'ws';
import {
    ITransport,
    WebSocketTransportNJS,
    SignallingProtocol,
    MessageHelpers,
    Messages,
    BaseMessage
} from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';
import { IPlayer, IPlayerInfo } from './PlayerRegistry';
import { IStreamer } from './StreamerRegistry';
import { Logger } from './Logger';
import { redactSensitiveLogValue } from './LogRedaction';
import * as LogUtils from './LoggingUtils';
import { SignallingServer } from './SignallingServer';

/**
 * A connection between the signalling server and a player connection.
 * This is where messages expected to be handled by the player come in
 * and where messages are sent to the player.
 *
 * Interesting internals:
 * playerId: The unique id string of this player.
 * transport: The ITransport where transport events can be subscribed to
 * protocol: The SignallingProtocol where signalling messages can be
 * subscribed to.
 */
export class PlayerConnection implements IPlayer, LogUtils.IMessageLogger {
    private codecPolicy?: CodecTicketPolicy;
    private codecOffer?: string;
    private codecOfferFromStreamer?: boolean;
    private codecNegotiated = false;
    private codecHasSubscribed = false;
    private codecConnectionId = randomUUID();
    private codecSequence = 0;
    private codecGeneration = 0;
    private selectedCodec?: VideoCodec;
    private codecSelectionFinalized = false;
    private codecSelectionFailed = false;
    private lastCodecObservation = { frames: 0, bytes: 0 };
    private observedCodec?: string;
    private negotiationTimer?: ReturnType<typeof setTimeout>;
    private streamerDescriptionReceived = false;

    get negotiationPending(): boolean {
        return !!this.codecPolicy && !this.codecNegotiated;
    }

    private clearNegotiationTimer(): void {
        if (this.negotiationTimer) clearTimeout(this.negotiationTimer);
        this.negotiationTimer = undefined;
    }

    private startNegotiationTimer(): void {
        if (!this.codecPolicy || this.codecSelectionFailed || this.negotiationTimer) return;
        // One deadline across capabilities, subscription and SDP; retries on the same
        // socket cannot extend it. Idle warm-pool streamers have no player deadline.
        this.negotiationTimer = setTimeout(() => {
            this.negotiationTimer = undefined;
            if (this.codecNegotiated) return;
            if (
                this.subscribedStreamer &&
                !this.streamerDescriptionReceived &&
                this.scaleWorldSessionIdentityValidated &&
                !this.shadowSessionRequestId
            ) {
                this.server.playerRegistry.emit('streamer_negotiation_timeout', this.subscribedStreamer);
            }
            this.failCodecNegotiation('Stream negotiation timed out');
        }, 60_000);
        this.negotiationTimer.unref();
    }

    get streamerPlayerId(): string {
        return this.codecPolicy
            ? `${this.playerId}-codec-${this.codecConnectionId}-${this.codecGeneration}`
            : this.playerId;
    }

    private shadowSessionRequestId?: string;
    codecAdmissionFailureReason?: string;

    initializeCodecPolicy(policy?: CodecTicketPolicy, shadowSessionRequestId?: string): boolean {
        if (!policy || !this.server.codecJournalReady?.()) return false;
        this.codecPolicy = policy;
        this.shadowSessionRequestId = shadowSessionRequestId;
        this.selectedCodec = policy.defaultCodec;
        if (shadowSessionRequestId) {
            const source = this.shadowSource();
            if (!source || !policy.allowedCodecs.includes(source.selectedCodec!)) return false;
            if (source.selectedCodec === 'H264') {
                this.codecAdmissionFailureReason = 'Shadow connect is unavailable for H264 sessions';
                return false;
            }
            this.selectedCodec = source.selectedCodec;
        }
        try {
            this.recordCodec(
                'connection_opened',
                this.shadowSessionRequestId ? { reason: 'Admin shadow viewer; existing session codec' } : {}
            );
            this.startNegotiationTimer();
            return true;
        } catch {
            return false;
        }
    }

    private shadowSource(): PlayerConnection | undefined {
        return this.server.playerRegistry
            .listPlayers()
            .find(
                (player): player is PlayerConnection =>
                    player instanceof PlayerConnection &&
                    player !== this &&
                    player.scaleWorldSessionIdentityValidated &&
                    player.scaleWorldSessionRequestId === this.shadowSessionRequestId &&
                    player.codecPolicy?.policyHash === this.codecPolicy?.policyHash &&
                    player.codecNegotiated &&
                    !!player.subscribedStreamer
            );
    }

    closeOrphanedShadow(): void {
        if (this.shadowSessionRequestId && !this.shadowSource()) this.disconnect();
    }

    private recordCodec(eventType: string, extra: Partial<CodecEvidence> = {}): void {
        const evidenceRequestId = this.shadowSessionRequestId ?? this.scaleWorldSessionRequestId;
        if (!this.codecPolicy || !evidenceRequestId) return;
        if (!this.server.codecEvidenceRecorder) throw new Error('Codec evidence unavailable');
        this.server.codecEvidenceRecorder({
            eventId: randomUUID(),
            sessionRequestId: evidenceRequestId,
            connectionId: this.codecConnectionId,
            sequence: this.codecSequence + 1,
            mediaGeneration: this.codecGeneration,
            eventType,
            codec: this.selectedCodec,
            evidenceSource: 'signalling',
            policyHash: this.codecPolicy.policyHash,
            occurredAtUtc: new Date().toISOString(),
            ...extra
        });
        this.codecSequence++;
    }

    private sendCodecState(status: string, reason?: string): void {
        if (!this.codecPolicy) return;
        this.protocol.sendMessage({
            type: 'scaleWorldCodecState',
            connectionId: this.codecConnectionId,
            mediaGeneration: this.codecGeneration,
            selectedCodec: this.selectedCodec,
            availableCodecs: [this.selectedCodec],
            allowSwitching: false,
            status,
            reason
        } as BaseMessage);
    }

    private filterCodecMessage(message: BaseMessage, fromStreamer: boolean): boolean {
        if (!this.codecPolicy || (message.type !== 'offer' && message.type !== 'answer')) return true;
        if (this.codecSelectionFailed) return false;
        if (
            this.shadowSessionRequestId &&
            (!this.shadowSource() || this.shadowSource()?.selectedCodec !== this.selectedCodec)
        ) {
            this.disconnect();
            return false;
        }
        this.codecSelectionFinalized = true;
        try {
            const description = message as BaseMessage & {
                sdp: string;
                sfu?: boolean;
                scalabilityMode?: string;
            };
            if (description.sfu || (description.scalabilityMode && description.scalabilityMode !== 'L1T1')) {
                throw new Error('Governed codecs require a direct non-SVC stream');
            }
            const result = restrictVideoSdp(description.sdp, this.selectedCodec!);
            if (fromStreamer) {
                this.streamerDescriptionReceived = true;
                this.server.playerRegistry.emit('streamer_negotiation_response', this.subscribedStreamer);
            }
            if (message.type === 'offer') {
                this.codecOffer = result.sdp;
                this.codecOfferFromStreamer = fromStreamer;
                this.codecNegotiated = false;
                this.startNegotiationTimer();
                this.sendCodecState('negotiating');
            } else {
                if (this.codecOfferFromStreamer === fromStreamer)
                    throw new Error('Answer must come from the opposite peer');
                validateCodecAnswer(this.codecOffer, description.sdp);
                this.recordCodec('negotiated');
                this.codecOffer = undefined;
                this.codecOfferFromStreamer = undefined;
                this.codecNegotiated = true;
                this.clearNegotiationTimer();
                this.server.playerRegistry.emit('negotiated', this.playerId);
                // Lifecycle listeners may reject a completion after an irrevocable deadline.
                if (!this.subscribedStreamer) return false;
            }
            description.sdp = result.sdp;
            return true;
        } catch (error) {
            // Only expose our fixed validation messages, never arbitrary SDP or journal errors.
            const knownReasons = [
                'Governed codecs require a direct non-SVC stream',
                'Invalid SDP',
                'Duplicate video payload mapping',
                'Exactly one active video section is required',
                'Answer must come from the opposite peer',
                'Answer without a current offer',
                'Answer changed a video payload mapping',
                'The streamer cannot negotiate ' + this.selectedCodec
            ];
            const detail =
                error instanceof Error && knownReasons.includes(error.message)
                    ? error.message
                    : 'Validation or evidence persistence failed';
            this.failCodecNegotiation('Codec negotiation failed (' + message.type + '): ' + detail);
            return false;
        }
    }

    private failCodecNegotiation(reason: string): void {
        this.codecSelectionFailed = true;
        this.clearNegotiationTimer();
        try {
            // Retain the existing event vocabulary for older analytics consumers.
            this.recordCodec('switch_failed', { reason });
        } catch {
            reason = 'Codec evidence unavailable; media paused';
        }
        this.unsubscribe();
        this.sendCodecState('failed', reason);
        // A failed socket must leave the viewer registry so lifecycle grace can run.
        // 1001 also prevents the frontend's automatic retry loop from concealing failure.
        this.protocol.disconnect(1001, 'Stream negotiation failed');
    }

    private handleCodecMessage(message: BaseMessage): boolean {
        if (
            message.type !== 'scaleWorldCodecSwitch' &&
            message.type !== 'scaleWorldCodecObservation' &&
            message.type !== 'scaleWorldCodecCapabilities'
        )
            return false;
        if (!this.codecPolicy) return true;
        const data = message as BaseMessage & {
            codec?: VideoCodec;
            supportedCodecs?: unknown;
            mediaGeneration?: number;
            framesDecoded?: number;
            bytesReceived?: number;
        };
        if (message.type === 'scaleWorldCodecCapabilities') {
            if (this.codecSelectionFinalized || this.codecHasSubscribed || this.codecOffer) return true;
            const supported = data.supportedCodecs;
            if (
                supported !== null &&
                (!Array.isArray(supported) ||
                    supported.length > 4 ||
                    supported.some(
                        (c: unknown) => typeof c !== 'string' || !videoCodecs.includes(c as VideoCodec)
                    ))
            )
                return true;
            this.codecSelectionFinalized = true;
            const preferred = this.shadowSessionRequestId
                ? this.selectedCodec!
                : this.codecPolicy.defaultCodec;
            const selected =
                supported === null
                    ? preferred
                    : ((this.shadowSessionRequestId ? [preferred] : [preferred, 'VP9', 'H264']).find(
                          (c) =>
                              this.codecPolicy!.allowedCodecs.includes(c as VideoCodec) &&
                              supported.includes(c)
                      ) as VideoCodec | undefined);
            if (!selected) {
                this.codecSelectionFailed = true;
                this.failCodecNegotiation('Client reports no policy-permitted codec; preferred ' + preferred);
                return true;
            }
            const reason =
                supported === null
                    ? 'Client decoding capabilities unavailable; preferred ' + preferred
                    : selected === preferred
                      ? 'Client advertises preferred ' + preferred
                      : 'Client does not advertise preferred ' + preferred + '; fallback to ' + selected;
            try {
                // Persist intent before any offer. Browser capability reports do not expand policy.
                this.recordCodec('codec_selected', { codec: selected, reason });
                this.selectedCodec = selected;
                this.sendCodecState('negotiating');
            } catch {
                this.codecSelectionFailed = true;
                this.failCodecNegotiation('Codec selection evidence unavailable');
            }
            return true;
        }
        if (message.type === 'scaleWorldCodecSwitch') {
            // Reject legacy clients even when an immutable older ticket permits switching.
            this.sendCodecState('rejected', 'The codec is selected by session policy');
            return true;
        }
        const frames = data.framesDecoded;
        const bytes = data.bytesReceived;
        if (
            data.mediaGeneration !== this.codecGeneration ||
            !this.subscribedStreamer ||
            !this.codecNegotiated ||
            !videoCodecs.includes(data.codec!) ||
            !Number.isSafeInteger(frames) ||
            !Number.isSafeInteger(bytes) ||
            frames! <= this.lastCodecObservation.frames ||
            bytes! <= this.lastCodecObservation.bytes ||
            frames! > 1e12 ||
            bytes! > 1e15
        )
            return true;
        // Persist the first decoded codec per media generation, not periodic samples.
        // Older clients may still report repeatedly; contradictions must never be suppressed.
        if (data.codec === this.observedCodec) return true;
        try {
            // Browser observations are explicitly untrusted evidence, retained even when contradictory.
            this.recordCodec('observed', {
                evidenceSource: 'browser',
                codec: data.codec,
                framesDecoded: frames,
                bytesReceived: bytes
            });
            this.lastCodecObservation = { frames: frames!, bytes: bytes! };
            this.observedCodec = data.codec;
            if (data.codec !== this.selectedCodec) {
                this.failCodecNegotiation('Observed codec differs from negotiated policy');
                return true;
            }
            this.sendCodecState('streaming');
        } catch {
            this.failCodecNegotiation('Codec evidence unavailable');
        }
        return true;
    }

    private static readonly minimumConfirmedVideoBytes = 256_000;
    // The unique id of this player connection.
    playerId: string;
    // The websocket transport used by this connection.
    transport: ITransport;
    // The protocol abstraction on this connection. Used for sending/receiving signalling messages.
    protocol: SignallingProtocol;
    // When the player is subscribed to a streamer this will be the streamer being subscribed to.
    subscribedStreamer: IStreamer | null;
    // A descriptive string describing the remote address of this connection.
    remoteAddress?: string;
    // ScaleWorld session identifiers used by runtime telemetry. These may come from query fallback.
    scaleWorldSessionId?: string;
    scaleWorldSessionRequestId?: string;
    // True only when the request id came from a successfully validated connect ticket.
    scaleWorldSessionIdentityValidated: boolean;
    // True only when the optional active-session id came from that validated ticket.
    scaleWorldActiveSessionIdValidated: boolean;
    // The HTTP upgrade request that opened this connection, if available.
    request?: IncomingMessage;

    private server: SignallingServer;
    private streamerIdChangeListener: (newId: string) => void;
    private streamerDisconnectedListener: () => void;
    private scaleWorldMediaEvidenceCapabilityReported: boolean;
    private scaleWorldMediaReceivedReported: boolean;
    private scaleWorldMediaFlowObservedReported: boolean;

    /**
     * Initializes a new connection with given and sane values. Adds listeners for the
     * websocket close and error so it can react by unsubscribing and resetting itself.
     * @param server - The signalling server object that spawned this player.
     * @param ws - The websocket coupled to this player connection.
     * @param remoteAddress - The remote address of this connection. Only used as display.
     * @param request - The HTTP upgrade request that opened this connection, if available.
     */
    constructor(server: SignallingServer, ws: WebSocket, remoteAddress?: string, request?: IncomingMessage) {
        this.server = server;
        this.playerId = '';
        this.subscribedStreamer = null;
        this.startNegotiationTimer();
        this.transport = new WebSocketTransportNJS(ws);
        this.protocol = new SignallingProtocol(this.transport);
        this.remoteAddress = remoteAddress;
        this.scaleWorldSessionIdentityValidated = false;
        this.scaleWorldActiveSessionIdValidated = false;
        this.scaleWorldMediaEvidenceCapabilityReported = false;
        this.scaleWorldMediaReceivedReported = false;
        this.scaleWorldMediaFlowObservedReported = false;
        this.request = request;

        this.transport.on('error', this.onTransportError.bind(this));
        this.transport.on('close', this.onTransportClose.bind(this));

        this.streamerIdChangeListener = this.onStreamerIdChanged.bind(this);
        this.streamerDisconnectedListener = this.onStreamerDisconnected.bind(this);

        this.registerMessageHandlers();
    }

    /**
     * Returns an identifier that is displayed in logs.
     * @returns A string describing this connection.
     */
    getReadableIdentifier(): string {
        return this.playerId;
    }

    /**
     * Sends a signalling message to the player.
     * @param message - The message to send.
     */
    sendMessage(message: BaseMessage): void {
        if (!this.filterCodecMessage(message, true)) return;
        LogUtils.logOutgoing(this, message);
        this.protocol.sendMessage(message);
    }

    /**
     * Returns a descriptive object for the REST API inspection operations.
     * @returns An IPlayerInfo object containing viewable information about this connection.
     */
    getPlayerInfo(): IPlayerInfo {
        return {
            playerId: this.playerId,
            type: 'Player',
            subscribedTo: this.subscribedStreamer?.streamerId,
            remoteAddress: this.remoteAddress
        };
    }

    private registerMessageHandlers(): void {
        /* eslint-disable @typescript-eslint/unbound-method */
        this.protocol.on(
            Messages.subscribe.typeName,
            LogUtils.createHandlerListener(this, this.onSubscribeMessage)
        );
        this.protocol.on(
            Messages.unsubscribe.typeName,
            LogUtils.createHandlerListener(this, this.onUnsubscribeMessage)
        );
        this.protocol.on(
            Messages.listStreamers.typeName,
            LogUtils.createHandlerListener(this, this.onListStreamers)
        );
        this.protocol.on(Messages.ping.typeName, LogUtils.createHandlerListener(this, this.onPingMessage));
        /* eslint-enable @typescript-eslint/unbound-method */

        this.protocol.on(Messages.offer.typeName, this.sendToStreamer.bind(this));
        this.protocol.on(Messages.answer.typeName, this.sendToStreamer.bind(this));
        this.protocol.on(Messages.iceCandidate.typeName, this.onIceCandidateMessage.bind(this));
        this.protocol.on(Messages.dataChannelRequest.typeName, this.sendToStreamer.bind(this));
        this.protocol.on(Messages.peerDataChannelsReady.typeName, this.sendToStreamer.bind(this));
        this.protocol.on(Messages.layerPreference.typeName, this.sendToStreamer.bind(this));

        this.protocol.on('unhandled', (message: BaseMessage) => {
            if (this.handleCodecMessage(message) || this.handleScaleWorldMediaEvidenceMessage(message)) {
                return;
            }

            Logger.warn(
                `Unhandled player protocol message: ${JSON.stringify(redactSensitiveLogValue(message))}`
            );
        });
    }

    private handleScaleWorldMediaEvidenceMessage(message: BaseMessage): boolean {
        const isCapability = message.type === 'scaleWorldMediaEvidenceCapability';
        const isMediaReceived = message.type === 'scaleWorldMediaReceived';
        const isMediaFlowObserved = message.type === 'scaleWorldMediaFlowObserved';
        if (!isCapability && !isMediaReceived && !isMediaFlowObserved) {
            return false;
        }

        if (!this.scaleWorldSessionIdentityValidated || !this.scaleWorldSessionRequestId || !this.playerId) {
            Logger.warn(
                `Ignoring ${message.type} from player ${this.playerId || '<unregistered>'} without validated ScaleWorld session identity.`
            );
            return true;
        }

        const evidence = message as BaseMessage & {
            telemetryVersion?: unknown;
            proofType?: unknown;
            mediaPresentationGuardVersion?: unknown;
            videoWidth?: unknown;
            videoHeight?: unknown;
            mediaTimeSeconds?: unknown;
            presentedFrames?: unknown;
            observationWindowMs?: unknown;
            videoBytesReceivedDelta?: unknown;
            videoPacketsReceivedDelta?: unknown;
            videoFramesDecodedDelta?: unknown;
            firstFramePresented?: unknown;
        };
        const finiteNumber = (value: unknown): number | undefined =>
            typeof value === 'number' && Number.isFinite(value) ? value : undefined;
        const metadata = {
            telemetryVersion: finiteNumber(evidence.telemetryVersion),
            proofType: evidence.proofType === 'video_frame_callback' ? evidence.proofType : undefined,
            mediaPresentationGuardVersion: evidence.mediaPresentationGuardVersion === 2 ? 2 : undefined,
            videoWidth: finiteNumber(evidence.videoWidth),
            videoHeight: finiteNumber(evidence.videoHeight),
            mediaTimeSeconds: finiteNumber(evidence.mediaTimeSeconds),
            presentedFrames: finiteNumber(evidence.presentedFrames)
        };

        if (isMediaFlowObserved) {
            const boundedCounter = (value: unknown, maximum: number): number | undefined => {
                const parsed = finiteNumber(value);
                return parsed !== undefined &&
                    Number.isSafeInteger(parsed) &&
                    parsed >= 0 &&
                    parsed <= maximum
                    ? parsed
                    : undefined;
            };
            const observationWindowMs = boundedCounter(evidence.observationWindowMs, 60_000);
            const videoBytesReceivedDelta = boundedCounter(
                evidence.videoBytesReceivedDelta,
                1_000_000_000_000
            );
            const videoPacketsReceivedDelta = boundedCounter(
                evidence.videoPacketsReceivedDelta,
                1_000_000_000
            );
            const videoFramesDecodedDelta = boundedCounter(evidence.videoFramesDecodedDelta, 1_000_000_000);
            const firstFramePresented = evidence.firstFramePresented === true;
            if (
                evidence.proofType !== 'webrtc_stats_window' ||
                observationWindowMs === undefined ||
                observationWindowMs < 5_000 ||
                videoBytesReceivedDelta === undefined ||
                videoPacketsReceivedDelta === undefined ||
                videoFramesDecodedDelta === undefined
            ) {
                Logger.warn(
                    `Ignoring invalid ScaleWorld media-flow observation from player ${this.playerId}.`
                );
                return true;
            }

            if (!this.scaleWorldMediaFlowObservedReported) {
                this.scaleWorldMediaFlowObservedReported = true;
                const flowConfirmed =
                    firstFramePresented &&
                    videoBytesReceivedDelta >= PlayerConnection.minimumConfirmedVideoBytes &&
                    videoPacketsReceivedDelta > 0 &&
                    videoFramesDecodedDelta > 0;
                this.server.playerRegistry.emit('scaleWorldMediaFlowObserved', this.playerId, {
                    telemetryVersion: finiteNumber(evidence.telemetryVersion),
                    proofType: evidence.proofType,
                    mediaPresentationGuardVersion:
                        evidence.mediaPresentationGuardVersion === 2 ? 2 : undefined,
                    observationWindowMs,
                    videoBytesReceivedDelta,
                    videoPacketsReceivedDelta,
                    videoFramesDecodedDelta,
                    firstFramePresented,
                    flowStatus: flowConfirmed ? 'confirmed' : 'not_confirmed'
                });
            }
            return true;
        }

        if (isCapability) {
            if (!this.scaleWorldMediaEvidenceCapabilityReported) {
                this.scaleWorldMediaEvidenceCapabilityReported = true;
                this.server.playerRegistry.emit('scaleWorldMediaEvidenceCapable', this.playerId, metadata);
            }
            return true;
        }

        if (!this.scaleWorldMediaReceivedReported) {
            this.scaleWorldMediaReceivedReported = true;
            this.server.playerRegistry.emit('scaleWorldMediaReceived', this.playerId, metadata);
        }
        return true;
    }

    private sendToStreamer(message: BaseMessage): void {
        const generation = (message as BaseMessage & { mediaGeneration?: number }).mediaGeneration;
        if (
            this.codecPolicy &&
            ['answer', 'offer', 'iceCandidate'].includes(message.type) &&
            generation !== this.codecGeneration
        )
            return;
        // Only the first browser offer may bootstrap an implicit subscription. Late ICE or
        // answers must not revive a paused/unsubscribed managed media generation.
        if (
            this.codecPolicy &&
            !this.subscribedStreamer &&
            ['answer', 'offer', 'iceCandidate'].includes(message.type) &&
            (message.type !== 'offer' || this.codecHasSubscribed)
        )
            return;
        if (!this.filterCodecMessage(message, false)) return;
        if (!this.subscribedStreamer) {
            Logger.warn(
                `Player ${this.playerId} tried to send to a streamer but they're not subscribed to any.`
            );
            const streamerId = this.server.streamerRegistry.getFirstStreamerId();
            if (!streamerId) {
                Logger.error('There are no streamers to force a subscription. Disconnecting.');
                this.disconnect();
                return;
            } else {
                Logger.warn(`Subscribing to ${streamerId}`);
                this.subscribe(streamerId);
                // subscribe() declines silently, most often because maxSubscribers is reached, and
                // says so only by leaving subscribedStreamer unset. Forwarding anyway dereferences
                // null, which surfaces as an uncaughtException and exits the process.
                if (!this.subscribedStreamer) {
                    Logger.error(
                        `Player ${this.playerId} could not be subscribed to ${streamerId}. Disconnecting.`
                    );
                    this.disconnect();
                    return;
                }
            }
        }

        message.playerId = this.streamerPlayerId;
        LogUtils.logForward(this, this.subscribedStreamer, message);
        this.subscribedStreamer.protocol.sendMessage(message);
    }

    private onIceCandidateMessage(message: BaseMessage): void {
        this.server.iceCandidateMonitor.recordPlayerCandidate(this, this.subscribedStreamer, message);
        this.sendToStreamer(message);
    }

    private subscribe(streamerId: string) {
        if (this.codecSelectionFailed) return;
        this.codecSelectionFinalized = true;
        if (typeof streamerId !== 'string') {
            Logger.warn('Ignoring malformed subscription and disconnecting its peer.');
            this.disconnect();
            return;
        }

        const streamer = this.server.streamerRegistry.find(streamerId);
        if (this.shadowSessionRequestId && this.shadowSource()?.subscribedStreamer !== streamer) {
            this.disconnect();
            return;
        }
        if (streamer && this.codecPolicy && streamer.getStreamerInfo().type !== 'Streamer') {
            this.sendCodecState('failed', 'Codec policy requires a direct streamer connection');
            return;
        }
        // Block before sending playerConnected to Unreal. This also covers stale
        // shadow tickets and duplicate owner tabs; the existing viewer stays intact.
        if (
            streamer &&
            this.codecPolicy &&
            this.server.playerRegistry
                .listPlayers()
                .some(
                    (player) =>
                        player instanceof PlayerConnection &&
                        player !== this &&
                        player.subscribedStreamer === streamer &&
                        (this.selectedCodec === 'H264' || player.selectedCodec === 'H264')
                )
        ) {
            this.failCodecNegotiation(
                'H264 sessions support one viewer. Close the existing player before reconnecting.'
            );
            return;
        }
        if (!streamer) {
            Logger.error(
                `subscribe: Player ${this.playerId} tried to subscribe to a non-existent streamer ${streamerId}`
            );
            const failureMessage = MessageHelpers.createMessage(Messages.subscribeFailed, {
                message: `Streamer ${streamerId} does not exist.`
            });
            this.protocol.sendMessage(failureMessage);
            return;
        }

        if (this.subscribedStreamer) {
            Logger.warn(
                `subscribe: Player ${this.playerId} is resubscribing to a streamer but is already subscribed to ${this.subscribedStreamer.streamerId}`
            );
            this.unsubscribe();
        }

        if (streamer.maxSubscribers > 0 && streamer.subscribers.size >= streamer.maxSubscribers) {
            Logger.error(
                `subscribe: Player ${this.playerId} could not subscribe to ${streamerId}. Max players (${streamer.maxSubscribers}) reached.`
            );
            const failureMessage = MessageHelpers.createMessage(Messages.subscribeFailed, {
                message: `Streamer ${streamerId} is full. Max players = ${streamer.maxSubscribers}.`
            });
            this.protocol.sendMessage(failureMessage);
            return;
        }

        if (this.codecPolicy) {
            if (this.codecHasSubscribed) {
                this.codecGeneration++;
                this.codecOffer = undefined;
                this.codecOfferFromStreamer = undefined;
                this.codecNegotiated = false;
                this.lastCodecObservation = { frames: 0, bytes: 0 };
                this.observedCodec = undefined;
                this.sendCodecState('restarting');
            }
            this.codecHasSubscribed = true;
        }
        this.subscribedStreamer = streamer;
        this.streamerDescriptionReceived = false;
        this.startNegotiationTimer();
        this.subscribedStreamer.subscribers.add(this.playerId);
        this.subscribedStreamer.on('id_changed', this.streamerIdChangeListener);
        this.subscribedStreamer.on('disconnect', this.streamerDisconnectedListener);

        const connectedMessage = MessageHelpers.createMessage(Messages.playerConnected, {
            playerId: this.playerId,
            dataChannel: true,
            sfu: false
        });
        this.sendToStreamer(connectedMessage);
    }

    private unsubscribe() {
        this.codecOffer = undefined;
        this.codecOfferFromStreamer = undefined;
        this.codecNegotiated = false;
        if (!this.subscribedStreamer) {
            return;
        }

        this.subscribedStreamer.subscribers.delete(this.playerId);

        const disconnectedMessage = MessageHelpers.createMessage(Messages.playerDisconnected, {
            playerId: this.playerId
        });
        this.sendToStreamer(disconnectedMessage);

        this.subscribedStreamer.off('id_changed', this.streamerIdChangeListener);
        this.subscribedStreamer.off('disconnect', this.streamerDisconnectedListener);
        this.subscribedStreamer = null;
    }

    private disconnect() {
        this.unsubscribe();
        this.clearNegotiationTimer();
        this.protocol.disconnect();
    }

    private onStreamerDisconnected(): void {
        this.disconnect();
    }

    private onTransportError(error: ErrorEvent): void {
        Logger.error(`Player (${this.playerId}) transport error ${error.message}`);
    }

    private onTransportClose(_event: CloseEvent): void {
        try {
            this.recordCodec('connection_closed');
        } catch {
            Logger.error('Codec close evidence could not be persisted');
        }
        Logger.debug('PlayerConnection transport close.');
        this.server.iceCandidateMonitor.flushPlayer(this.playerId, 'player_disconnected');
        this.disconnect();
    }

    private onSubscribeMessage(message: Messages.subscribe): void {
        this.subscribe(message.streamerId);
    }

    private onUnsubscribeMessage(_message: Messages.unsubscribe): void {
        this.unsubscribe();
    }

    private onListStreamers(_message: Messages.listStreamers): void {
        const listMessage = MessageHelpers.createMessage(Messages.streamerList, {
            ids: this.server.streamerRegistry.streamers
                .filter((streamer) => streamer.streaming)
                .map((streamer) => streamer.streamerId)
        });
        this.sendMessage(listMessage);
    }

    private onStreamerIdChanged(newId: string) {
        const renameMessage = MessageHelpers.createMessage(Messages.streamerIdChanged, { newID: newId });
        this.sendMessage(renameMessage);
    }

    private onPingMessage(message: Messages.ping): void {
        this.sendMessage(MessageHelpers.createMessage(Messages.pong, { time: message.time }));
    }
}
