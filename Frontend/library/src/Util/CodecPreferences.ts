// Copyright Epic Games, Inc. All Rights Reserved.
/** Reorder advertised capabilities without inventing codec/profile combinations. */
export function preferVideoCodec(codecs: readonly RTCRtpCodec[], preferred: string): RTCRtpCodec[] {
    const [name, ...parameters] = preferred.trim().split(/\s+/);
    const mime = ('video/' + name).toLowerCase();
    const fmtp = parameters.join(' ');
    const priority = (codec: RTCRtpCodec): number => {
        if (codec.mimeType.toLowerCase() !== mime) return 2;
        return !fmtp || codec.sdpFmtpLine === fmtp ? 0 : 1;
    };
    return [...codecs].sort((a, b) => priority(a) - priority(b));
}
