// Copyright Epic Games, Inc. All Rights Reserved.
export const videoCodecs = ['VP9', 'AV1', 'H264', 'VP8'] as const;
export type VideoCodec = (typeof videoCodecs)[number];
export interface CodecTicketPolicy {
    version: 1;
    snapshotId: string;
    policyHash: string;
    allowedCodecs: VideoCodec[];
    defaultCodec: VideoCodec;
    allowSwitching: boolean;
}
export function parseCodecPolicy(value: unknown): CodecTicketPolicy | undefined {
    if (!value || typeof value !== 'object') return undefined;
    const p = value as CodecTicketPolicy;
    if (
        p.version !== 1 ||
        !/^[0-9a-f-]{36}$/i.test(p.snapshotId) ||
        !/^[0-9a-f]{64}$/i.test(p.policyHash) ||
        !Array.isArray(p.allowedCodecs) ||
        p.allowedCodecs.length < 1 ||
        p.allowedCodecs.length > 4 ||
        new Set(p.allowedCodecs).size !== p.allowedCodecs.length ||
        p.allowedCodecs.some((c) => !videoCodecs.includes(c)) ||
        !p.allowedCodecs.includes(p.defaultCodec) ||
        typeof p.allowSwitching !== 'boolean'
    )
        return undefined;
    return {
        version: 1,
        snapshotId: p.snapshotId,
        policyHash: p.policyHash,
        allowedCodecs: [...p.allowedCodecs],
        defaultCodec: p.defaultCodec,
        allowSwitching: p.allowSwitching
    };
}

/** Preserve audio/data and video transport attributes; retain only the selected video codec and its RTX. */
export function restrictVideoSdp(
    sdp: string,
    selected: VideoCodec
): { sdp: string; available: VideoCodec[] } {
    if (typeof sdp !== 'string' || sdp.length > 262144 || !sdp.startsWith('v=0'))
        throw new Error('Invalid SDP');
    const sections = sdp.replace(/\r\n/g, '\n').split(/(?=^m=)/m);
    const available = new Set<VideoCodec>();
    let activeVideo = 0;
    const filtered = sections.map((section) => {
        if (!section.startsWith('m=video ')) return section;
        const lines = section.trimEnd().split('\n');
        const media = lines[0].split(/\s+/);
        if (media[1] === '0') return section;
        activeVideo++;
        const offered = new Set(media.slice(3));
        const mappings = new Map<string, string>();
        for (const line of lines) {
            const match = /^a=rtpmap:(\d+) ([^/]+)\/90000(?:\s|$)/i.exec(line);
            if (!match || !offered.has(match[1])) continue;
            if (mappings.has(match[1])) throw new Error('Duplicate video payload mapping');
            mappings.set(match[1], match[2].toUpperCase());
            if (videoCodecs.includes(match[2].toUpperCase() as VideoCodec))
                available.add(match[2].toUpperCase() as VideoCodec);
        }
        const keep = new Set([...mappings].filter(([, codec]) => codec === selected).map(([pt]) => pt));
        if (!keep.size) throw new Error(`The streamer cannot negotiate ${selected}`);
        for (const line of lines) {
            const match = /^a=fmtp:(\d+) .*\bapt=(\d+)(?:;|\s|$)/.exec(line);
            if (match && mappings.get(match[1]) === 'RTX' && keep.has(match[2])) keep.add(match[1]);
        }
        lines[0] = [...media.slice(0, 3), ...media.slice(3).filter((pt) => keep.has(pt))].join(' ');
        return (
            lines
                .filter((line) => {
                    const match = /^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)\b/.exec(line);
                    return !match || keep.has(match[1]);
                })
                .join('\n') + '\n'
        );
    });
    if (activeVideo !== 1) throw new Error('Exactly one active video section is required');
    return { sdp: filtered.join('').replace(/\n/g, '\r\n'), available: [...available] };
}

export interface CodecEvidence {
    eventId: string;
    sessionRequestId: string;
    connectionId: string;
    sequence: number;
    mediaGeneration: number;
    eventType: string;
    codec?: VideoCodec;
    evidenceSource: 'signalling' | 'browser';
    policyHash: string;
    occurredAtUtc: string;
    switchId?: string;
    framesDecoded?: number;
    bytesReceived?: number;
    reason?: string;
    runtimeVersion?: string;
}

/** A player cannot relabel a payload number that the streamer offered as another codec. */
export function validateCodecAnswer(offer: string | undefined, answer: string): void {
    if (!offer) throw new Error('Answer without a current offer');
    const mappings = (sdp: string) => {
        const section = sdp.split(/(?=^m=)/m).find((s) => s.startsWith('m=video ')) ?? '';
        return new Map(
            [...section.matchAll(/^a=rtpmap:(\d+) ([^\r\n]+)/gm)].map((m) => [m[1], m[2].toUpperCase()])
        );
    };
    const expected = mappings(offer);
    for (const [pt, codec] of mappings(answer)) {
        if (expected.get(pt) !== codec) throw new Error('Answer changed a video payload mapping');
    }
}
