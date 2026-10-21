# Browser recording usage analytics

Status: PixelStreaming producer, tab outbox and Wilbur relay are implemented.
API capability issuance/ingestion, SQL persistence and Manager analytics presentation
are deployed to Dev, with issuance still disabled. See the
[API owner document](../../scaleworld-server-manager-api/docs/recording-analytics.md)
and [Manager presentation](../../scaleworld-server-manager-web/docs/recording-analytics.md).
The Manager document records the exact API/Web serving builds. Matching player
runtime activation and hosted end-to-end acceptance remain pending. Without a recording capability,
the player makes no new recording reports. Recording itself remains available.

## Meaning of the events

| Event | Trigger | Analytics meaning |
| --- | --- | --- |
| `recording_started` | First nonempty chunk with the expected video codec/container, including a chunk delivered by Stop | The browser produced capture data; a successful file is not yet established |
| `recording_saved` | All chunks written and the local writer successfully closed | One saved clip, reported by the browser |
| `recording_failed` | An attempted recording fails opening, capturing, writing or closing | An unsuccessful attempt; never count it as a saved clip |

Opening Settings, selecting/cancelling a location, or cancelling an opening file
before the recorder starts does not count as recording usage. Errors before a
valid attempt (unsupported stream, missing location) produce no report. Stop,
disconnect, codec/peer replacement and accepted End session use the same existing
file-finalization path, so they produce the same terminal events.

Use saved clips to answer “did this viewer save a video?” Label the result
**browser reported**. No report means **not reported/unknown**, not proof the user
did not record. External screen recorders are invisible, clients can falsify
metadata, and forced tab/browser termination can lose both a file and its report.

Only codec, container, timestamps, duration, bytes, event identity and a fixed
failure code leave the browser. Never send video/audio, filename, chosen folder,
absolute path, camera smoothing state, raw exceptions, or extra user identity.
`bytesWritten` is successfully completed writes; on failure these bytes may have
been aborted rather than saved. `durationMs` is monotonic elapsed capture time
from recorder start to Stop/recorder termination, excluding disk finalization.
It is an estimate of capture time, not demuxed media duration or billing time.

## Wire contract (schema version 1)

The API must issue a **separate recording-only capability**. It is not the
session-end capability, connect ticket, agent credential or API login.

1. API's `Features/Connect/ConnectTicketService.cs` adds `sw_recording=<opaque token>`
   to the existing returned player URL fragment, preserving `sw_end` and all other
   fragment entries. Use one fragment builder, not concatenated `#` characters.
   `ConnectTicketResponse.Url` already carries the URL; no new required response
   property is necessary. Include the exact `SessionRequestId` in the response.
2. Manager's `src/features/secureConnect/api.ts` preserves this fragment while adding
   `sm_session_request_id` and the other reconnect fields. Keep the capability out
   of query parameters, logs, analytics and general API authorization headers.
3. `player.ts` consumes and removes `sw_recording` before player initialization. The
   optional context cache is tab-scoped, keyed by host/path and exact session request.
   A fresh `ct` launch clears cached current credentials and requires URL-provided
   session context. Missing/malformed credentials disable only reporting.
4. The browser sends `POST /api/recording-events` on the stream origin. Wilbur relays
   to **`POST /session/player-recordings`** on the fixed HTTPS
   `instance_agent_api_base_url` / `INSTANCE_AGENT_API_BASE_URL` origin. Neither
   browser nor payload can select an upstream URL. Redirects are rejected.

Headers:

```text
Content-Type: application/json
X-SW-Recording: <recording-only capability>
X-SW-Session-Request: <exact SessionRequestId UUID>
```

Example body (no session/user/instance identity inside the body):

```json
{
  "schemaVersion": 1,
  "recordingId": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "eventType": "recording_saved",
  "occurredAtUtc": "2026-10-21T12:00:00.000Z",
  "codec": "AV1",
  "container": "webm",
  "bytesWritten": 31457280,
  "durationMs": 30000
}
```

`recordingId` is a new cryptographically generated UUID per attempt, stable across
that attempt's events and retries. AV1/VP9 require `webm`; H264 requires `matroska`.
Metrics are nonnegative safe integers, at most 1 TiB and 24 hours. Saved bytes must
be positive. Timestamps are canonical UTC ISO strings with milliseconds. Extra
fields, invalid UUIDs, unsupported codecs and bodies above 8 KiB are rejected.

Only `recording_failed` includes mandatory `failureCode`, one of:
`file_open_failed`, `recorder_start_failed`, `recorder_failed`, `start_timeout`,
`format_mismatch`, `write_backpressure`, `write_failed`, `stop_timeout`, `stop_failed`,
`write_timeout`, `empty_recording`, `file_close_failed`. These are categories, never
exception messages. A per-write timeout is included in `write_failed`;
`write_timeout` means the final drain of queued writes timed out.

After a committed SQL insert **or an identical already-committed retry**, API returns
HTTP 200 with this acknowledgement. Wilbur validates all four values and removes
any upstream extras; browser removes the queued event only after matching it.

```json
{
  "accepted": true,
  "sessionRequestId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "recordingId": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "eventType": "recording_saved"
}
```

Use canonical lowercase UUIDs when issuing session context. Errors: 400/413/415/422
invalid report, 401/403 unauthorized, 409 identity/payload/terminal conflict, 410
expired grant, 429 rate limit, 503 transient unavailability. The relay preserves
these statuses and 404/501 (integration not deployed); other upstream failures or
incorrect acknowledgements become 502. Network/timeout failures become 503.
Responses are `no-store`; no request or response secrets/raw bodies are logged.

## Delivery and failure isolation

`localRecording.ts` creates an optional observer per attempt before file I/O,
then emits lifecycle metadata without awaiting it. Synchronous exceptions and
rejected observer promises cannot break recording, stream controls or navigation.
`recordingControl.ts`/`playerRecording.ts` pass the observer without changing media
selection. No Unreal Blueprint or new signalling protocol messages are required.

`recordingTelemetry.ts` persists a bounded outbox in sessionStorage before sending.
Each entry retains its original session request and capability even after a reload
or a fresh session launch; old events are never attributed to a new owner/session.
Current credentials are cached separately. Storage failure falls back to memory.
The outbox holds at most 128 events for at most 24 hours, prioritizing terminal
events over unacknowledged starts when full. Reporting is best effort; eviction,
browser storage clearing and permanent errors can lose events.

Two concurrent requests allow a saved report to start while the first event is
awaiting acknowledgement. Requests use `keepalive`, omit cookies, reject redirects,
and time out after five seconds (relay upstream timeout: four seconds). Transient
network, 429 and 5xx errors retry after 2/4/8/16/32/60 seconds, then every 60 seconds
until expiry. 400/401/403/404/405/409/410/413/415/422/501 are terminal report failures.
Visibility changes, pagehide and online events also flush due entries. No delivery
wait is added to file saving or navigation. Keepalive does not guarantee delivery.
The same-origin relay must still be reachable: WebRTC loss alone does not prevent
HTTP reporting, but instance/Wilbur shutdown can. If a session-end action takes the
relay offline before a final save is reported, the file can be saved without a
matching analytics event. The queue can retry on reload/recovery within the grant's
acceptance window; it cannot guarantee recovery after the tab is closed.

The outbox contains a purpose-limited bearer token: protect it like existing player
session credentials and exclude it from telemetry/debug dumps. It survives tab
reload, not reliably tab closure. Reload retries may duplicate an accepted request
whose acknowledgement was lost; API idempotency is mandatory. An unconfigured API,
old runtime, expired capability or absent analytics service must never disable
local recording or trigger a user-facing recording error.

## API implementation contract

Implemented in `scaleworld-server-manager-api/ScaleWorld.ServerManager.Api`;
the following requirements describe its contract and acceptance boundaries:

1. **Capability service and issuance.** Follow the purpose-specific end-session
   integration pattern, with independent credential storage/validation and no stop
   permission. Generate at least 32 random bytes; retain only a hash. Bind to the
   immutable SessionRequestId, stable authenticated viewer AccessSubjectId, canonical
   customer identity and issuing instance/session generation. Do not resolve a late
   event using the instance's current owner. Initial scope: issue to the admitted
   session owner only. Shadow/admin recording remains available locally but is not
   attributed to the owner; add explicit viewer attribution before enabling their
   telemetry. Proposed maximum grant lifetime: 24 hours. Permit terminal reports
   for 15 minutes after that exact session ends, bounded by grant expiry. Validate
   against the original session even after instance reassignment; never reopen it.
   Ticket refresh/new launches must not invalidate still-live grants for pending
   clips in the same session. Revocation and subject deletion still take precedence.
2. **Authenticated ingestion.** `Web/Controllers/PlayerRecordingController.cs` implements
   the endpoint above: anonymous only with respect to the normal login scheme,
   always authenticated by the recording capability. Enforce exact header/claim
   identity, schema, event time bounds relative to grant/session (allow bounded
   browser clock skew), per-grant/IP rate limits and server `ReceivedAtUtc`. Preserve
   original event timestamps on retries; do not trust browser time for authority.
3. **Separate SQL ledger.** Add a recording-events table and per-clip projection
   under `Features/SessionAnalytics`, keyed by `(SessionRequestId, ViewerSubjectId,
   RecordingId, EventType)`, plus a canonical payload hash. Commit ledger and
   projection atomically before acknowledgement; identical retries acknowledge,
   differing duplicates return 409. Saved and failed are mutually exclusive terminal
   states; reject conflicts. Accept terminal events without a preceding start and
   never regress a terminal state on a late start. A lost start must not hide a saved
   file. A delayed start may be rejected after session-end grace without removing
   the already accepted terminal event.
4. **Analytics read projection.** `RecordingAnalyticsService` exposes a separate
   paged `/admin/session-analytics/sessions/{id}/recordings` endpoint with recording
   counts, saved bytes/duration and clip entries, preserving existing session DTOs
   and sealed event exports. Count distinct saved clip IDs by viewer, not events/HTTP calls.
   Keep recording evidence outside Billing and sealed session-evidence hashes;
   late reports must not mutate billing amounts, lifecycle status or sealed inputs.
   Return absence as not reported, and describe observed attempts separately from
   saved clips. Apply existing tenant/admin read permissions, retention and
   subject/session privacy deletion/export rules to this new ledger.

Do not feed this through the ordinary `instance-agent.ts` pending runtime-event
queue: it is memory-only, capped at the newest 100, and does not provide the required
durable per-event acknowledgement. The existing agent analytics event allowlist
does not ingest these browser events. This implementation adds no agent credentials
to the browser, no agent queue and no video artifact/upload contract.

## Manager implementation

`scaleworld-server-manager-web` preserves and tests `sw_recording` alongside `sw_end`
and reconnect context. The API builds the URL; Manager does not manufacture a token.
Its session-details section shows **Videos saved**, total saved duration/bytes,
codec/container and reported outcome. An optional list-column/filter can follow
once query/index cost is measured. Existing sessions/older API responses should
show **Not reported**, with no invented zero/“never recorded” assertion. Show viewer
identity only from the authorized API projection, never browser-provided data.

## Rollout, rollback and acceptance

- Deploy API schema + ingestion with capability issuance disabled, then publish and
  activate an explicitly selected runtime artifact containing this player/relay.
  Deploy the optional Manager analytics presentation; enable issuance for accepted
  runtime cohorts. Validate actual running identities, not just successful builds.
- This is additive/optional: no required response fields, existing agent protocol
  bump or minimum-runtime admission increase is needed. Use schema version 1 for
  this new endpoint. Older API omits the token; old runtimes ignore it or return
  404 for a new player's relay request. Mixed versions retain local recording.
- Rollback: disable issuance first, retain ingestion for already-issued grants and
  pending saves, then revert frontend/runtime if needed. Keep the additive SQL data;
  do not roll back Billing/session lifecycle or delete accepted recording evidence.
- API acceptance: real SQL commit/replay, idempotent duplicate/out-of-order events,
  terminal conflicts, forged/wrong-session IDs, stale instance/new-owner replay,
  denied/expired/revoked grants, owner vs shadow attribution, post-end save grace,
  rate/retention behavior and unchanged billing/sealed evidence.
- Pixel local checks: controller lifecycle/failure isolation, exact ack/retry/reload
  identity, bounded queue, storage denied/corrupt, no token, fixed-destination relay,
  strict payload/parser limits and no secrets in errors. The synthetic browser proof
  now also compares saved analytics bytes with the real finalized OPFS file and
  sends metadata through real browser fetch to a local mock acknowledgement endpoint.
  This tests the browser producer, not live API persistence or native picker behavior.
- Hosted acceptance still required: exact API/Manager/runtime/Unreal builds, native
  Chrome/Edge picker, save after Disconnect/End session, multiple clips and reload,
  API outage/retry and missing integration, session reassignment, analytics UI
  counts, and confirmation that recording/input remain usable throughout failures.

No publication, activation or hosted acceptance is implied by the local
PixelStreaming/API/Web implementation. API capability issuance remains off by default.
