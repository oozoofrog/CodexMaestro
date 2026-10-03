# Codex desktop adapter

## Sources of truth

- The owning Mac's installed desktop bundle and runtime socket determine compatibility.
- Local catalog: `state_*.sqlite`, opened using `SQLITE_OPEN_READONLY`; newer numbered state files take priority.
- Project identity: `threads.project_id`, with longest matching root at a path boundary only when it is absent. Unrelated roots in the same project do not affect ranking; trailing root separators are normalized and `/` matches absolute paths.
- User-facing title: persisted `name`, then `title`; nonempty existing titles are preserved.
- Runtime status: versioned desktop snapshots/patches, never inferred from modification time.
- Conversation text: persisted `thread_history_1.sqlite` projection. This is not a token streaming transcript.
- Graph relations: Maestro-owned workspace state; fork/spawn ancestry is separate from user-created links.

Official public app-server reference: https://developers.openai.com/codex/app-server (checked 2026-10-03). Public app-server connections have their own runtime ownership. Starting an independent server and resuming the same thread would not prove control of the desktop's active session; Maestro therefore uses desktop coordination for existing local sessions.

## Desktop IPC contract

This is an internal adapter, verified against Desktop 26.930.31428 (12913). It does not bundle or execute copied desktop implementation code.

Transport: Unix stream socket, each JSON object prefixed by a 4-byte unsigned little-endian UTF-8 byte count. Frame size validation follows the observed 256 MiB desktop limit. Connect only to an existing socket owned by the current UID. No server socket creation, chmod, daemon start, token reading, or desktop configuration changes.

Request envelope:

```json
{
  "type": "request",
  "requestId": "unique UUID",
  "sourceClientId": "id returned by initialize",
  "method": "thread-owner-discovery",
  "version": 1,
  "params": { "hostId": "local", "conversationId": "thread UUID" },
  "timeoutMs": 5000
}
```

- `initialize` v0: clientType `codex-maestro`; source client starts as `initializing-client`.
- `thread-stream-following-changed` v1 broadcast: `hostId`, `conversationId`, `following`.
- `thread-stream-state-changed` v11 broadcast: snapshot with `conversationState`, or `patches` with `baseRevision` / `revision` and Immer-style path arrays.
- `thread-stream-following-status-requested` v1: renew an existing subscription when desktop ownership changes.
- `thread-owner-discovery` v1: select the existing owner using returned `handledByClientId`.
- `thread-follower-start-turn` v2: route to that exact owner. Params contain `conversationId`, `turnStart.request` (`threadId`, literal text input, client message ID) and `turnStart.context.inheritThreadSettings=true`.
- Maestro responds negatively to client discovery for methods it does not own. It never claims to be a desktop owner or handles approvals.

The bridge maintains only a small status/model/title projection of snapshots. It does not retain entire conversation snapshots. Token/text patches do not force graph updates unless the displayed projection changes.

## Failure behavior

- Missing/offline desktop: read-only catalog remains visible; status becomes unknown; sending is disabled.
- Absent owner: no start-turn request. The UI asks the user to open the original session in Codex.
- Mismatched protocol version: invalidate live state and report incompatibility.
- Missing or nonadvancing patch revision, malformed patch collection, or invalid indexed projection patch: invalidate live state and request a fresh snapshot. Relevant patches apply transactionally, with Immer array insertion/replacement/removal semantics.
- Desktop client disconnect: invalidate sessions owned by that client.
- Send timeout or disconnect: keep the draft, report unconfirmed delivery, never automatically retry. Request timeout closes the transport so queued or partial frames cannot continue on that connection.
- Socket backpressure: frames are written in order on a background queue, using nonblocking send and a deadline-limited wait. The main actor remains available for cancellation and disconnect. Shutdown interrupts pending I/O; the descriptor remains owned until retained reader/writer work finishes.
- Reconnect: clear previous live state, initialize a new client, resubscribe to current local sessions.
- Malformed workspace JSON: preserve existing bytes and refuse saves for the current app run.

The app-server public contract and desktop coordination contract are distinct. Compatibility checks here do not imply a supported third-party API or future version compatibility.

## Inspector actions and validation boundary

The inspector can refresh the selected session's persisted conversation without refreshing the whole catalog, open the original session in Codex, and navigate to a loaded parent session. The refresh action reads the saved projection; it does not request token streaming or send a prompt. Parent ancestry remains separate from user-created graph relations.

`IntegrationProjectionTests` exercises indexed waiting flags, transaction rollback for malformed patches, irrelevant conversation patches, multi-root project fallback, explicit membership preservation, and nonpositive transcript limits. `StreamRecoveryTests` also verifies invalid revisions, malformed indexed patches, and unknown change shapes invalidate and resubscribe over a disposable fake Unix socket. Desktop transport/request routing remains covered by the fake Unix-socket tests; these checks do not prove real desktop prompt acceptance or future private-protocol compatibility.

## 선택한 세션의 대화 일관성

세션 선택이 바뀌면 이전 대화·오류·로딩 상태를 즉시 지웁니다. 대화 읽기는 현재 선택한 세션만 시작할 수 있습니다. 읽기 토큰이 현재 토큰과 일치할 때만 결과와 오류를 적용합니다. 이전 세션으로 보낸 프롬프트의 응답이 늦게 도착해도 현재 세션의 대화 읽기를 무효화하지 않습니다. `TranscriptSelectionTests`의 네 가지 actor 제어 테스트가 이 경계를 검증합니다.
