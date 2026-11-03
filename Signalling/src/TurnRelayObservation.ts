// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'node:crypto';

/** Bounded observations on a ticket-validated signalling connection. */
export class TurnRelayObservationReceiver {
    private readonly connectionId = randomUUID();
    private sequence = 0;
    private lastAt = 0;
    private lastSignature = '';
    private budgetMs = 40_000;
    private refillAt: number | undefined;

    accept(input: Record<string, unknown>, now = Date.now()): Record<string, unknown> | undefined {
        if (
            input['relayEvidenceVersion'] !== 1 ||
            typeof input['usesTurn'] !== 'boolean' ||
            typeof input['localRelay'] !== 'boolean' ||
            typeof input['remoteRelay'] !== 'boolean' ||
            (!input['usesTurn'] && (input['localRelay'] || input['remoteRelay']))
        )
            return;
        const url = input['localRelayUrl'];
        const address = input['remoteRelayAddress'];
        if (
            url !== undefined &&
            (typeof url !== 'string' ||
                url.length > 253 ||
                !/^turns?:[a-z0-9.-]+:\d+\?transport=(udp|tcp)$/i.test(url))
        )
            return;
        if (
            address !== undefined &&
            (typeof address !== 'string' || address.length > 64 || !/^[a-f0-9:.]+$/i.test(address))
        )
            return;
        const fields = {
            relayEvidenceVersion: 1,
            usesTurn: input['usesTurn'],
            localRelay: input['localRelay'],
            remoteRelay: input['remoteRelay'],
            localRelayUrl: input['localRelay'] ? url : undefined,
            remoteRelayAddress: input['remoteRelay'] ? address : undefined
        };
        const signature = JSON.stringify(fields);
        if (signature === this.lastSignature && now - this.lastAt < 10_000) return;
        // Admit a small burst of real path transitions, without allowing an admitted
        // client to flood diagnostics by continually changing candidate addresses.
        this.budgetMs = Math.min(40_000, this.budgetMs + Math.max(0, now - (this.refillAt ?? now)));
        this.refillAt = now;
        if (this.budgetMs < 10_000) return;
        this.budgetMs -= 10_000;
        this.lastAt = now;
        this.lastSignature = signature;
        return { ...fields, connectionId: this.connectionId, sequence: ++this.sequence };
    }
}
