# Directed workspace connections

Codex Maestro records four directed endpoint combinations in its local workspace:

- Session → session: individual Codex sessions, with an optional reviewed context-transfer draft.
- Project → project: relationships between registered Codex projects.
- Session → project: a session's context, dependency, or review relationship to a project.
- Project → session: a project's context, dependency, or review relationship to a particular session.

Each endpoint stores both its node kind and identifier. A project and session with the same raw identifier remain distinct endpoints. The connection manager has an All filter plus one filter per direction. Its editor independently selects the source and target node kinds and identities. New connections seed the selected session or project as their source when it fits the chosen direction.

The connection manager supports creating, editing, and removing all four combinations. The direction is shown as `source → target`. Reverse relationships are separate, and different purposes may coexist between the same endpoints. Self-links to the same typed endpoint, empty endpoints, duplicate directed relationships of the same purpose, and duplicate link UUIDs are rejected. Editing preserves the UUID and note even when changing node kinds moves the relationship between storage arrays. Failed edits or deletes restore all affected arrays.

Both the project and session inspectors show incoming and outgoing relationships from the complete typed graph. Navigating a related endpoint opens the corresponding inspector. A project endpoint is a registered Codex project; the synthetic unassigned-session group does not become a persistent project endpoint, and its connection-creation action is disabled.

The manager retains links whose endpoint is no longer present in the current catalog, shows the missing identifier, and allows repairing or removing them. It does not silently delete stored relationships when a project disappears or a session is archived. Action preparation revalidates both endpoints and the concrete receiving session against the current catalog.

Saving a link records relationship metadata; it does not send a prompt, create a Codex dependency, relocate work, or impose scheduling. All four endpoint combinations can have a configured function and reviewed execution draft. Project execution requires an explicitly chosen current member session; it never chooses an arbitrary recipient or broadcasts to the project. Removing a relationship removes Maestro's local link and its function configuration.

## Item overlap and execution functions

Drag the source session card or project header onto another visible eligible item and release. The item moves with the pointer; no modifier key or cable drag is required. Meaningful rectangle overlap opens `다음 작업`. Selecting Reference, Handoff, Review, or Custom saves or reuses the directed context relationship together with its function configuration, then opens the request sheet. Canceling before that selection preserves the original position, links, and drafts. An empty-area drop saves only the position. Escape, focus loss, or a canceled gesture restores the origin without saving. Project header movement preserves individual child positions and updates its membership edges.

The connection-icon then target-click alternative and manager editing remain available. Closing a request sheet after a relationship has been saved preserves that relationship. The manager and both inspectors expose `요청` for reopening it. Double-clicking a session or project opens its recorded context topology. Current behavior and scope are described in [Context topology and item overlap](CONTEXT-TOPOLOGY.md).

The four functions have defaults, while every function allows execution on either side:

| Function | Default execution side | Opposite endpoint supplies |
| --- | --- | --- |
| Reference / `참고` | Source | Reference material for the current task |
| Handoff / `전달` | Target | Prior results and context to continue |
| Review / `검토` | Target | Material to review |
| Custom / `직접 요청` | Source, with either side selectable | Reference material accompanying the authored request |

`담당` selects the execution side; the compact sheet names the actual work location and opposite reference endpoint in its `작업` and `참고` rows. Graph direction and execution side are separate. A session endpoint fixes the receiving session. A project endpoint requires the user to choose an explicit session that currently belongs to that project, including catalog sessions regardless of live status. An unresolved project configuration may be saved without a recipient, but draft preparation is blocked until one is selected.

Maestro has no manual skill picker. The composed prompt asks the actual execution session to select suitable skills that are available to it. If no appropriate skill is available, the session is instructed to use its ordinary workflow; a required unavailable skill must be reported as missing. This prompt instruction does not establish destination loader exposure or prove that a skill ran.

The initially collapsed `보낼 내용` disclosure shows the composed draft for the selected execution session and opposite reference endpoint. Preparing uses those exact preview bytes and revalidates the relationship and receiving session. An existing nonempty draft is preserved: preparation refuses to overwrite it or silently append. The user then reviews the receiving session's draft and explicitly sends it. Saving configuration and preparing a draft do not dispatch work automatically. 

The earlier Command gesture implementation and its native evidence remain in [Historical Command connections](COMMAND-CONNECTIONS.md). Those logs do not validate the newer item-overlap or context-topology UI.

## Persistence compatibility

Legacy-only workspaces keep version `1`. Adding a mixed relationship promotes the workspace to version `2`, and persistence also writes version `2` whenever the mixed `nodeLinks` array is nonempty. Connection function configurations promote persistence to version `3`, stored in `connectionActions` keyed by relationship UUID. The current app reads versions `1`, `2`, and `3`. An older app rejects a schema newer than it supports when loading the file, preventing that loaded run from dropping unknown mixed relationships or function configurations. This marker does not coordinate an older process that already loaded a version `1` snapshot; simultaneous workspace writers are not supported. The optional `projectLinks` and `nodeLinks` JSON fields are additive; older version `1` files without them decode with empty added arrays while preserving session links, positions, and private drafts. Existing session and project links keep their legacy encodings. Mixed relationships use `nodeLinks`, whose source and target objects each carry `kind` and `id`. `allNodeLinks` adapts the legacy arrays into one typed graph for the manager, inspectors, and topology. Editing a relationship across endpoint kinds keeps its UUID while moving it into the matching storage array.

Legacy `.skill` function values remain decodable in version `3` records. They normalize to `.custom`, preserving the original nonempty prompt, execution side, and recipient; an empty legacy request receives the general reference-task fallback. Manual skill name and path fields are cleared during normalization and save. Reading legacy configuration does not create a separate skill-selection flow.

Invalid non-null project-link data fails decoding rather than silently becoming an empty graph. Failed workspace loading disables writes so corrupted source data is not overwritten. Connection mutations roll back if workspace persistence cannot complete. Demo mode maintains the graph in memory and never writes the user's workspace.

## Historical verification

The logs and counts in this section belong to earlier implementation snapshots. They are retained as evidence for those snapshots and do not establish acceptance of the current item-overlap or context-topology flow.

`Tests/MaestroCoreTests/ConnectionTests.swift` exercises legacy JSON decoding, graph round trips alongside drafts and session links, directed/purpose-specific duplicate rules, UUID uniqueness, editing identity, failed-edit preservation, and malformed data handling.

`Tests/MaestroAppTests/ConnectionStoreTests.swift` exercises project and session CRUD membership checks, duplicate protection, preservation of session membership/drafts, rollback on persistence failure, and handoff success/failure behavior. Canvas creation uses the same endpoint validation as the manager; a missing or archived endpoint, duplicate connection, or failed save keeps the connection editor open and retains its source. These are local model/store checks. They do not establish successful communication with a running Codex instance or production usage of project relationships.

The focused `swift test --filter Connection` run passes 16 tests (6 core, 8 connection store, and 2 inspector/canvas regressions), including a deterministic failing-write fixture and a corrupted-workspace fixture. Full output is retained in `evidence/connection-tests.log`; the initial app compilation is in `evidence/connection-build.log`. The tests compile the updated connection editor and store extensions; successful compilation alone does not verify the rendered UI.

`Tests/MaestroCoreTests/StalledPeerTests.swift` supplies a local IPC peer that answers initialization and owner discovery, then stops draining the socket. A 4 MiB fixture prompt fills the write buffer. The test requires a MainActor heartbeat within 1.5 seconds and disconnect completion within one second, and the peer watchdog releases any blocked writer after three seconds. The initial synchronous transport fails this regression with a 3.043-second heartbeat delay (`evidence/connection-stalled-peer-attempt.log`). The fixture never acknowledges a turn and does not access a real Codex session.

After the transport writes moved to a serial queue using nonblocking sends and a poll deadline, the same stalled-peer regression passes: heartbeat resumes in 0.157278 seconds and disconnect releases the pending prompt in 0.000117 seconds (`evidence/connection-stalled-peer-final.log`). This is local backpressure/cancellation evidence, not real-session delivery or a general UI frame-rate measurement.

## 이전 통합 검증

Astra 지적을 수정한 `evidence/astra-fix-tests.log`에는 Core 23개와 앱 17개, 총 40개 테스트의 통과가 기록되어 있습니다. 이 중 연결 모델 테스트는 6개이고 연결 저장·전달·캔버스 편집 흐름 테스트는 8개입니다. 별도 대화 선택 테스트 4개는 이전 세션의 결과가 현재 상세 패널에 적용되지 않는 것을 검증합니다. 초기 focused 로그의 테스트 수는 당시 소스 스냅샷에 해당합니다.

## Typed endpoint regression checks

`Tests/MaestroAppTests/ConnectionManagerEndpointTests.swift` exercises all four manager direction filters, typed identity when project and session IDs overlap, both inspectors' relationship membership, selected-source defaults, endpoint-kind edits that move storage buckets without changing identity, and failed-write rollback across all arrays. The tests are local model/store/editor-state checks; rendered controls and real Codex delivery require separate evidence.

## Historical function verification boundaries

The earlier test counts and timings above describe their recorded source snapshots. The Command-drag implementation, configured execution on either side, exact-preview preparation, and session-managed skill instructions have historical source, fixture, and native UI evidence in [COMMAND-CONNECTIONS.md](COMMAND-CONNECTIONS.md). Current interaction is documented in [CONTEXT-TOPOLOGY.md](CONTEXT-TOPOLOGY.md), while aggregate validation belongs in [VALIDATION.md](VALIDATION.md). A native demo draft does not establish delivery to a real Codex session or completion of the requested work.
