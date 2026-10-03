# Astra completion and functional review

Review date: 2026-10-03. Scope: session connections, project connections, local Codex integration, and the large-catalog drag path. This review inspected the implementation and test assertions independently. No real user session received a review prompt. No production workspace was edited. There is no Git metadata in this checkout, so the reviewed unit is the source tree and the named evidence artifacts, not a commit.

## Final disposition

**Accepted within the documented local-app scope after fixes. No unresolved blocking defect was found in the reviewed paths.** The initial review requested changes for one reproducible main-actor transport stall and two correctness defects. All three were corrected and re-reviewed against current source and targeted regression evidence. This disposition does not certify perceived drag smoothness, actual model-response completion, future private-IPC compatibility, or distribution readiness. Final release packaging after the fixes remains a separate validation step owned by the implementation session.

## Findings

### R1 — P1 — Socket backpressure blocks the UI and its request timeout — RESOLVED

Initial locations: `Sources/MaestroCore/DesktopBridge.swift:106`, `Sources/MaestroCore/DesktopBridge.swift:316-328`.

`DesktopBridge` runs on `MainActor` and synchronously invokes `UnixTransport.send`. That method holds an `NSLock` while looping over blocking `Darwin.write` calls. There is no nonblocking output queue or socket write deadline. If the desktop stops reading after owner discovery and a prompt exceeds socket-buffer capacity, the write blocks the actor. The timeout task on the same actor cannot execute, and actor-driven disconnect cannot recover the UI while the write remains blocked.

This was reproduced with the compiled pre-fix `MaestroCore.o` and a disposable local socket. The fixture answered initialization and owner discovery, then stopped draining for two seconds. An 8 MiB synthetic prompt blocked a 100 ms MainActor heartbeat until 2.071 seconds; the send failed only when the fixture closed. See `evidence/astra-backpressure-before.log`. The source and executable harness were created under `/tmp/maestro-review-backpressure*`. This did not contact the user's Codex endpoint.

Required correction: serialize output away from MainActor, permit bounded shutdown during backpressure, and prove actor responsiveness plus single-attempt send behavior under a stalled peer. Moving only the timeout does not fix the blocked UI.

### R2 — P2 — Transcript work can replace the selected session's load and leave stale content — RESOLVED

Initial locations: `Sources/CodexMaestro/MaestroStore.swift:195-214`, `Sources/CodexMaestro/MaestroStore.swift:230`; rendering at `Sources/CodexMaestro/SessionInspector.swift:54-76`.

Selecting B immediately changes the inspector header but leaves A's transcript visible until the asynchronous B read finishes. More seriously, when a send to A completes after the user selected B, `send` calls `loadTranscript(A)`. That call changes the shared generation and loading state before checking selection. Its completion returns early because A is no longer selected, leaving loading active and invalidating B's pending read. The next periodic refresh may repair this, but the inspector can display another session's text in the meantime.

Required correction: reject reads for a non-selected session before touching inspector state; clear or explicitly key displayed transcript data when selection changes; use generation-safe cleanup for loading. Add a controlled overlapping-read regression and a stale-send-completion regression.

### R3 — P2 — Canvas connection creation bypasses current endpoint validation and dismisses failed edits — RESOLVED

Initial locations: `Sources/CodexMaestro/MaestroStore.swift:234-241`; `Sources/CodexMaestro/WorkspaceView.swift:185`.

The connection manager calls `saveSessionLink`, which validates both endpoints against the current catalog. The canvas path instead calls `workspace.addLink` directly. If an endpoint is archived while its sheet remains open, the next refresh removes it from the catalog, but the sheet can still create a new dangling link. In addition, the sheet dismisses unconditionally on duplicate or persistence failure. The rollback protects the graph, but the editor's completion behavior does not reflect the failed mutation.

Required correction: use the same catalog validation and persistence path for both entry points, return success explicitly, and dismiss only after success. Preserve already stored orphaned links as documented; the validation applies to new or repaired relationships.

## Evidence assessed

- Initial `evidence/team-tests.log`: 22 core tests and 12 app tests passed, with zero failures. After review fixes, `evidence/astra-fix-tests.log` records 23 core tests and 17 app tests, for **40 tests with zero failures**. The two test bundles report totals separately. These are not an end-to-end send validation.
- Connection tests cover version-1 decoding without `projectLinks`, malformed field rejection, directed and purpose-specific duplicate checks, identity-preserving edits, read-failure protection, persistence rollback, draft preservation, and handoff preparation without sending.
- Socket fixtures cover framing, owner routing, inherited settings, missing-owner refusal, runtime projection, and resnapshot recovery. Initial fixtures continuously drain the socket and did not detect R1.
- Performance tests exercise all 601 synthetic sessions, nil project membership, ordering/filtering, collapse/expansion retention, and Observation dependency isolation. Their timing loop excludes SwiftUI rendering and presentation.
- `evidence/performance-ui.log`: three completed drags report 33, 14, and 18 updates, each with zero topology layout preparations during movement. These counters support isolation, not an FPS or perceived-smoothness claim. Drop-time layout work is outside their measured interval.
- `evidence/team-live-probe.log`: a read-only probe observed 31 projects, 605 unarchived sessions, and six live desktop snapshots. These counts are timestamp-specific and can differ from a later UI snapshot.
- Packaging logs exist for release compilation and local ad-hoc signing. Final packaging after review fixes needs its own evidence.

## Accepted boundaries and unverified behavior

Project connections are local directed metadata. They do not alter Codex project membership, enforce scheduling, or send prompts. Session handoff prepares an editable target draft; transmission remains a separate explicit action. This matches the implementation and avoids a false automated-orchestration claim.

The adapter reads Codex databases in read-only mode and uses the installed desktop's private IPC, currently version 11 for state broadcasts. Public app-server compatibility, remote hosts, cloud conversations, future desktop versions, Developer ID signing, and notarization are outside the demonstrated scope.

The large-catalog changes remove per-pointer topology preparation, use a tiled background, separate static paths from incident moving paths, and freeze the card origin during a drag. Expanded cards are still eagerly retained. The moving-edge renderer still scans displayed items and builds a position dictionary. No controlled before/after frame-time or compositor measurement establishes that the reported sluggishness is fully resolved. Cancellation, long-duration live refresh during dragging, and accessibility navigation have not been independently exercised in this review.

Real prompt acceptance and model-response completion remain unverified. Fixture success must not be reported as actual business-session send E2E. Demo-backed UI snapshots demonstrate interaction with local in-memory data, not live Codex connectivity or durable production writes.

## Re-review

**R1:** Current `DesktopBridge.swift:318-364` serializes writes on a dedicated queue, uses `MSG_DONTWAIT` plus deadline-bounded `poll`, and allows `close()` to issue `shutdown` without waiting for the writer's I/O. Reader and writer closures retain the transport until descriptor use ends. A request timeout disconnects the transport so queued frames are not intentionally sent afterward (`DesktopBridge.swift:99-108`). The implementation preserves one-shot prompt dispatch and does not introduce automatic retries.

The review independently recompiled and reran the same stalled-peer harness against the rebuilt core object. The 100 ms heartbeat resumed after **0.180 seconds**, while the send remained pending until the peer closed after **2.082 seconds**; `heartbeatRan=true`. See `evidence/astra-backpressure-after.log`, compared with the 2.071-second blocked heartbeat before the fix. This is a transport responsiveness regression measurement, not a UI-frame measurement. The added `StalledPeerTests` also records a 0.159-second heartbeat and a 0.000124-second disconnect completion in `evidence/astra-fix-tests.log`.

**R2:** Current `MaestroStore.swift:206-225` clears transcript/error/loading state and invalidates the old generation on selection change. `loadTranscript` rejects an unselected ID before changing shared state, and its `defer` clears loading only for the owning generation. The four controlled actor-gated tests cover immediate selection clearing, rejection of an old target read while B is loading, stale A success, and stale A failure. Both stale completions preserve B's loading state and only B publishes content. Production selection and handoff paths now call the same selection helper.

**R3:** Current `MaestroStore.swift:245-249` returns a Boolean and delegates canvas creation to `saveSessionLink`. Current `WorkspaceView.swift:186-187` retains the editor when validation or persistence fails and dismisses only on success. The added store regression checks failed canvas creation with a removed endpoint, preserved editor source/target state, successful creation, and duplicate rejection. Existing connection persistence rollback regressions continue to pass. Retention and dismissal were assessed from source plus store tests; the revised failure sheet was not independently driven in the macOS UI during this review.

The implementation session subsequently reported eight live sessions in the normal application UI after snapshots arrived. The earlier zero count was the launch frame. This report treats that UI observation as implementation-session evidence; the independently inspected saved probe remains the six-snapshot run described above. It must not be replaced by demo or stress-fixture status.

## Post-fix delivery evidence

The implementation session completed the reviewed release build and local ad-hoc signing verification in `evidence/team-reviewed-package.log`. The rebuilt read-only probe in `evidence/reviewed-live-probe.log` records 31 projects, 608 unarchived sessions, eight live snapshots, and 22 messages in the latest saved transcript. These files were inspected during the following design review; counts remain specific to that run.

The implementation session also drove the final Release demo UI: a CodexMaestro → RunnersHeart project arrow rendered, and a duplicate canvas connection retained its sheet with the inline duplicate error after R3's correction. These are implementation-session observations, not independently repeated CUA actions by this reviewer. Both interactions were memory-only and sent no production prompt or saved production link.

## 리더 세션의 검토 후 검증 추가 기록

다음 항목은 Astra의 독립 실행 결과와 구분한 리더 세션의 실행 증거입니다.

- `evidence/team-reviewed-package.log`: R1–R3 수정 후 Release 빌드와 앱 번들 로컬 서명 검증 통과.
- `evidence/reviewed-live-probe.log`: 프로젝트 31개, 보관되지 않은 세션 608개, 실제 열린 세션 8개의 상태 수신.
- 최종 Release 데모 UI: `CodexMaestro → RunnersHeart` 프로젝트 연결선과 방향 화살표 표시 확인.
- 최종 Release 데모 UI: 중복 세션 연결을 거부한 뒤 편집기와 인라인 오류 유지 확인. 오류를 소비한 뒤 취소하면 같은 전역 오류 알림이 다시 표시되지 않도록 UI 한 줄을 추가 수정했습니다.

실제 Codex 세션에는 검증 프롬프트를 전송하지 않았습니다. 인라인 오류 상태 소비는 기능 계약을 바꾸지 않으며 리더 세션에서 빌드와 UI로 확인합니다.

리더의 최종 확인: `evidence/final-package.log`에서 마지막 UI 오류 상태 소비 수정 후 Release 빌드와 로컬 서명 검증이 통과했습니다. `evidence/final-ui-observations.log`에 중복 오류 취소 후 정상 창 복귀와 일반 실행 모드의 608개 세션·8개 실시간 상태 표시를 기록했습니다.
