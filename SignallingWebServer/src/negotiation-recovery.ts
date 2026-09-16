// Copyright Epic Games, Inc. All Rights Reserved.
/** Accumulate unanswered Unreal wait time across sockets for the same signed request.
 * Time with no waiting viewer does not count and cannot trigger a warm-pool restart. */
export class NegotiationRecovery {
    private readonly requests = new Map<
        object,
        Map<
            string,
            {
                elapsed: number;
                since: number;
                lastSeen: number;
                players: Set<string>;
                reported: boolean;
            }
        >
    >();

    constructor(
        private readonly fault: (streamer: object) => void,
        private readonly now = Date.now
    ) {}

    started(streamer: object, request: string, player: string): void {
        if (!streamer || !request || !player) return;
        this.prune();
        let requests = this.requests.get(streamer);
        if (!requests) {
            requests = new Map();
            this.requests.set(streamer, requests);
        }
        let state = requests.get(request);
        if (!state)
            requests.set(
                request,
                (state = {
                    elapsed: 0,
                    since: this.now(),
                    lastSeen: this.now(),
                    players: new Set(),
                    reported: false
                })
            );
        if (state.players.size === 0) state.since = this.now();
        state.players.add(player);
        state.lastSeen = this.now();
        this.check();
    }

    abandoned(streamer: object, request: string, player: string): void {
        const state = this.requests.get(streamer)?.get(request);
        if (!state || !state.players.delete(player)) return;
        if (state.players.size === 0) state.elapsed += Math.max(0, this.now() - state.since);
        state.lastSeen = this.now();
    }

    responded(streamer: object, request: string): void {
        this.requests.get(streamer)?.delete(request);
    }

    removed(streamer: object): void {
        this.requests.delete(streamer);
    }

    check(): void {
        this.prune();
        for (const [streamer, requests] of this.requests) {
            for (const state of requests.values()) {
                if (
                    !state.reported &&
                    state.players.size > 0 &&
                    state.elapsed + Math.max(0, this.now() - state.since) >= 60_000
                ) {
                    state.reported = true;
                    this.fault(streamer);
                }
            }
        }
    }

    private prune(): void {
        for (const [streamer, requests] of this.requests) {
            for (const [request, state] of requests) {
                if (state.players.size === 0 && this.now() - state.lastSeen > 300_000)
                    requests.delete(request);
            }
            if (requests.size === 0) this.requests.delete(streamer);
        }
    }
}
