// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const { restrictVideoSdp, parseCodecPolicy, validateCodecAnswer } = require('../dist/cjs/CodecPolicy.js');
const offer = ['v=0', 'a=group:BUNDLE 0 1', 'm=audio 9 UDP/TLS/RTP/SAVPF 111', 'a=rtpmap:111 opus/48000/2',
 'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100', 'a=mid:1', 'a=ice-ufrag:test', 'a=rtpmap:96 H264/90000',
 'a=rtpmap:97 rtx/90000', 'a=fmtp:97 apt=96', 'a=rtpmap:98 VP9/90000', 'a=rtpmap:99 rtx/90000',
 'a=fmtp:99 apt=98', 'a=rtcp-fb:96 nack', 'a=rtcp-fb:98 nack', 'a=rtpmap:100 AV1/90000',
 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel', 'a=sctp-port:5000', ''].join('\r\n');
test('external VP9 policy retains audio/data/RTX and removes H264/AV1 and their payload attributes', () => {
 const result = restrictVideoSdp(offer, 'VP9');
 assert.deepEqual(result.available, ['H264', 'VP9', 'AV1']);
 assert.match(result.sdp, /m=video 9 UDP\/TLS\/RTP\/SAVPF 98 99\r\n/);
 assert.match(result.sdp, /a=fmtp:99 apt=98/); assert.match(result.sdp, /opus\/48000\/2/);
 assert.match(result.sdp, /a=sctp-port:5000/); assert.match(result.sdp, /a=ice-ufrag:test/);
 assert.doesNotMatch(result.sdp, /H264|AV1|(?:rtpmap|fmtp|rtcp-fb):9[67]/);
 assert.equal(restrictVideoSdp(result.sdp, 'VP9').sdp, result.sdp);
 assert.throws(() => restrictVideoSdp(result.sdp, 'H264'));
});
test('unsupported codec, multiple active video sections and duplicate payload mappings fail closed', () => {
 assert.throws(() => restrictVideoSdp(offer, 'VP8'));
 assert.throws(() => restrictVideoSdp(offer + 'm=video 9 UDP/TLS/RTP/SAVPF 98\r\na=rtpmap:98 VP9/90000\r\n', 'VP9'));
 assert.throws(() => restrictVideoSdp(offer.replace('a=mid:1', 'a=rtpmap:98 H264/90000\r\na=mid:1'), 'VP9'));
});
test('answer payload numbers must match the filtered offer', () => {
 const sdp = restrictVideoSdp(offer, 'VP9').sdp;
 assert.doesNotThrow(() => validateCodecAnswer(sdp, sdp));
 assert.throws(() => validateCodecAnswer(undefined, sdp));
 assert.throws(() => validateCodecAnswer(sdp, sdp.replaceAll('98', '96')));
});
test('signed codec claim rejects malformed policies and defaults outside allowlist', () => {
 const policy = { version: 1, snapshotId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', policyHash: 'A'.repeat(64), allowedCodecs: ['VP9'], defaultCodec: 'VP9', allowSwitching: false };
 assert.deepEqual(parseCodecPolicy(policy), policy);
 for (const invalid of [undefined, {}, {...policy, version: 2}, {...policy, defaultCodec: 'H264'}, {...policy, allowedCodecs: ['VP9', 'FAKE']}, {...policy, allowedCodecs: []}]) assert.equal(parseCodecPolicy(invalid), undefined);
});
