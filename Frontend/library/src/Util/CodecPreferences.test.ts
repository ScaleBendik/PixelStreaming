import { preferVideoCodec } from './CodecPreferences';

describe('browser codec preferences', () => {
    const h264 = { mimeType: 'video/H264', clockRate: 90000, sdpFmtpLine: 'profile-level-id=42e01f;packetization-mode=1' };
    const vp9 = { mimeType: 'video/VP9', clockRate: 90000, sdpFmtpLine: 'profile-id=0' };
    const vp92 = { ...vp9, sdpFmtpLine: 'profile-id=2' };
    const rtx = { mimeType: 'video/rtx', clockRate: 90000 };
    const capabilities = [h264, rtx, vp9, vp92];
    it('keeps real VP9 profiles when policy supplies only a codec family', () => {
        const ordered = preferVideoCodec(capabilities, 'VP9');
        expect(ordered).toEqual([vp9, vp92, h264, rtx]);
        expect(ordered[0]).toBe(vp9);
        expect(ordered.every(c => capabilities.includes(c))).toBe(true);
        expect(capabilities[0]).toBe(h264);
    });
    it('prefers an advertised profile and never fabricates a missing profile', () => {
        expect(preferVideoCodec(capabilities, 'VP9 profile-id=2')[0]).toBe(vp92);
        expect(preferVideoCodec(capabilities, 'VP9 profile-id=3')).toEqual([vp9, vp92, h264, rtx]);
        expect(preferVideoCodec(capabilities, 'AV1')).toEqual(capabilities);
        expect(preferVideoCodec([], 'VP9')).toEqual([]);
    });
});
