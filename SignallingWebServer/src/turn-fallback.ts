// Copyright Epic Games, Inc. All Rights Reserved.
import { lookup } from 'node:dns/promises';

export const RETAINED_TURN_PUBLIC_HOST = 'turn.scaleworld.net';
export const RETAINED_TURN_PRIVATE_HOST = '172.31.32.124';

/** Add an independent authenticated relay; ICE, rather than array order, selects the path. */
export function withTurnFallback(
    peerOptions: unknown,
    peer: 'player' | 'streamer',
    environment: NodeJS.ProcessEnv = process.env
): unknown {
    if (environment.SCALEWORLD_TURN_MODE !== 'redundant') return peerOptions;
    if (environment.SCALEWORLD_STREAMING_LANE !== 'prod') {
        throw Error('Redundant TURN is Prod-only; nonprod uses the retained relay as primary.');
    }
    if (!environment.TURN_FALLBACK_USERNAME?.trim() || !environment.TURN_FALLBACK_CREDENTIAL?.trim()) {
        throw Error('Redundant TURN requires separate fallback credentials.');
    }
    if (
        environment.TURN_FALLBACK_USERNAME === environment.TURN_USERNAME ||
        environment.TURN_FALLBACK_CREDENTIAL === environment.TURN_CREDENTIAL
    )
        throw Error('Primary and fallback TURN must have separate credentials.');
    if (!peerOptions || typeof peerOptions !== 'object' || Array.isArray(peerOptions)) {
        throw Error('Redundant TURN requires configured primary peer options.');
    }
    const copy = structuredClone(peerOptions) as { iceServers?: Array<Record<string, unknown>> };
    if (
        !Array.isArray(copy.iceServers) ||
        !copy.iceServers.some((entry) => {
            const urls = Array.isArray(entry['urls']) ? entry['urls'] : [entry['urls']];
            return urls.some((url) => typeof url === 'string' && /^turns?:/i.test(url));
        })
    )
        throw Error('Redundant TURN requires a primary TURN entry.');
    copy.iceServers.push({
        urls:
            peer === 'player'
                ? [
                      `turn:${RETAINED_TURN_PUBLIC_HOST}:3478?transport=udp`,
                      `turns:${RETAINED_TURN_PUBLIC_HOST}:443?transport=tcp`
                  ]
                : [
                      `turn:${RETAINED_TURN_PRIVATE_HOST}:3478?transport=udp`,
                      `turn:${RETAINED_TURN_PRIVATE_HOST}:3478?transport=tcp`
                  ],
        username: environment.TURN_FALLBACK_USERNAME,
        credential: environment.TURN_FALLBACK_CREDENTIAL
    });
    return copy;
}

export type TurnRelayRole = 'direct' | 'primary' | 'fallback' | 'unknown';

/** Only configured relay identities are classified; arbitrary candidate addresses are never logged. */
export class TurnRelayClassifier {
    private readonly fallbackAddresses = new Set([RETAINED_TURN_PRIVATE_HOST]);
    private readonly primaryAddresses = new Set<string>();
    private lastLookup = 0;
    private lookupInFlight: Promise<void> | undefined;

    constructor(
        private readonly environment: NodeJS.ProcessEnv = process.env,
        private readonly resolveHost = (host: string) => lookup(host, { all: true }),
        private readonly lookupTimeoutMs = 2_000
    ) {}

    refreshAddresses(now = Date.now()): Promise<void> {
        // Every report arriving during the first lookup shares its completion.
        if (this.lookupInFlight) return this.lookupInFlight;
        if (now - this.lastLookup < 60_000) return Promise.resolve();
        this.lastLookup = now;
        this.lookupInFlight = this.resolveAddresses().finally(() => {
            this.lookupInFlight = undefined;
        });
        return this.lookupInFlight;
    }

    private async resolveAddresses(): Promise<void> {
        const boundedLookup = async (host: string): Promise<Array<{ address: string }>> => {
            let timer: ReturnType<typeof setTimeout> | undefined;
            try {
                return await Promise.race([
                    this.resolveHost(host),
                    new Promise<[]>((resolve) => {
                        timer = setTimeout(() => resolve([]), this.lookupTimeoutMs);
                        timer.unref?.();
                    })
                ]);
            } catch {
                return [];
            } finally {
                clearTimeout(timer);
            }
        };
        const resolve = async (hosts: string[], target: Set<string>, retained = false) => {
            const addresses = await Promise.all(hosts.map(boundedLookup));
            target.clear();
            if (retained) target.add(RETAINED_TURN_PRIVATE_HOST);
            for (const result of addresses) for (const item of result) target.add(item.address);
        };
        // Diagnostic enrichment only: DNS failure never blocks media or invents a healthy path.
        await Promise.all([
            this.hasFallback()
                ? resolve([RETAINED_TURN_PUBLIC_HOST], this.fallbackAddresses, true)
                : Promise.resolve(),
            resolve(
                [this.environment.TURN_PUBLIC_HOST, this.environment.TURN_PRIVATE_HOST].filter(
                    (host): host is string => Boolean(host)
                ),
                this.primaryAddresses
            )
        ]);
    }

    private hasFallback(): boolean {
        return (
            this.environment.SCALEWORLD_TURN_MODE === 'redundant' &&
            this.environment.SCALEWORLD_STREAMING_LANE === 'prod'
        );
    }

    classify(evidence: Record<string, unknown>): TurnRelayRole {
        if (evidence['usesTurn'] === false) return 'direct';
        if (evidence['usesTurn'] !== true) return 'unknown';
        const match =
            typeof evidence['localRelayUrl'] === 'string'
                ? /^turns?:([a-z0-9.-]+):\d+\?transport=(?:udp|tcp)$/i.exec(evidence['localRelayUrl'])
                : null;
        const host = match?.[1]?.toLowerCase();
        const remote =
            typeof evidence['remoteRelayAddress'] === 'string' ? evidence['remoteRelayAddress'] : '';
        const roles: TurnRelayRole[] = [];
        if (evidence['localRelay'] === true) {
            // The URL identifies this leg directly; remote addresses belong to a different leg.
            roles.push(
                host && host === this.environment.TURN_PUBLIC_HOST?.toLowerCase()
                    ? 'primary'
                    : this.hasFallback() && host === RETAINED_TURN_PUBLIC_HOST
                      ? 'fallback'
                      : 'unknown'
            );
        }
        if (evidence['remoteRelay'] === true) {
            const primary = this.primaryAddresses.has(remote);
            const fallback = this.hasFallback() && this.fallbackAddresses.has(remote);
            // Overlapping DNS aliases cannot establish which service the remote leg used.
            roles.push(primary === fallback ? 'unknown' : primary ? 'primary' : 'fallback');
        }
        if (roles.includes('fallback')) return 'fallback';
        return roles.length > 0 && roles.every((role) => role === 'primary') ? 'primary' : 'unknown';
    }
}
