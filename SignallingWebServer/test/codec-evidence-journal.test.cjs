// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { CodecEvidenceJournal } = require('../dist/codec-evidence-journal.js');
const event = n => ({ eventId: 'event-' + n, sessionRequestId: 'request', connectionId: 'connection', sequence: n });
test('codec evidence survives process replacement and only acknowledged IDs are removed', t => {
 const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codec-journal-test-'));
 t.after(() => fs.rmSync(directory, { recursive: true }));
 const filename = path.join(directory, 'events.json');
 const journal = new CodecEvidenceJournal(filename); journal.append(event(1)); journal.append(event(2));
 const recovered = new CodecEvidenceJournal(filename); assert.deepEqual(recovered.batch(), [event(1), event(2)]);
 recovered.acknowledge(['event-1']); assert.deepEqual(new CodecEvidenceJournal(filename).batch(), [event(2)]);
 recovered.acknowledge(['not-sent']); assert.deepEqual(recovered.batch(), [event(2)]);
});
test('corrupt and full journals fail closed without overwriting unacknowledged evidence', t => {
 const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codec-journal-test-'));
 t.after(() => fs.rmSync(directory, { recursive: true }));
 const filename = path.join(directory, 'events.json'); fs.writeFileSync(filename, 'corrupt');
 const failed = new CodecEvidenceJournal(filename); assert.equal(failed.ready, false); assert.throws(() => failed.append(event(1)));
 assert.equal(fs.readFileSync(filename, 'utf8'), 'corrupt');
 const bounded = new CodecEvidenceJournal(path.join(directory, 'bounded.json'), 2);
 bounded.append(event(1)); bounded.append(event(2)); assert.throws(() => bounded.append(event(3)));
 assert.deepEqual(bounded.batch(), [event(1), event(2)]);
});
