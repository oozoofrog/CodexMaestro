# Topology performance verification

Verified on 2026-10-03 on this Apple Silicon Mac, using the current debug package build.

## Reproducible stress fixtures

`PerformanceFixture.catalog()` provides 601 deterministic synthetic sessions across 31 projects plus one session without project membership. It includes live sessions, running sessions and parent relationships. `PerformanceFixture.store(catalog:)` expands every represented project and selects the all-session scope.

`--performance-demo` opens this synthetic fixture. `--performance-catalog` reads the current real local catalog into an expanded in-memory snapshot. Both use demo mode: no IPC subscription or periodic refresh, no workspace persistence writes, and demo sends never transmit a prompt. A real catalog snapshot therefore exercises real titles and grouping geometry, but does not demonstrate live Codex connectivity. Its session count changes with the local catalog.

With `MAESTRO_PERFORMANCE_LOG=1`, completed drags log the number of gesture updates and topology layout preparations occurring between drag start and end. These counters contain no session content. The layout commit happens after the measured interval, so a zero layout count demonstrates isolation during movement, not absence of layout after drop. Cancellation is not a completed-drag sample.

## Automated regression evidence

Run `swift test --filter PerformanceTests`. Final successful output after the frozen drag-origin change is `evidence/performance-tests-final.log`; the first successful run is `evidence/performance-tests.log`.

Five app-target tests passed with zero failures:

- Fully expanded grouping retains all 601 sessions exactly once, including nil project membership.
- Project ordering matches an independent reference using running status first, then first session position; a selected known project remains visible for an empty search result.
- Collapsing retains the first three sessions, live sessions and the selected session. Expansion, search and explicit project selection retain every matching item.
- 120 drag-state mutations invalidate the registered edge dependency but do not invalidate registered store layout dependencies. Clearing the drag also clears its frozen base point. Committing a position does invalidate workspace layout dependency. This exercises the actual Observable types; it does not mount a SwiftUI view or synthesize an input gesture.
- A 200-iteration grouped layout-preparation sample preserves the full item count. Final observed debug elapsed time was 0.064659667 seconds for the entire loop. This measures filtering, project ordering, dictionary grouping and displayed-session selection. It excludes SwiftUI layout, drawing, input dispatch and presentation.

The initial compilation attempt preceded the drag-state visibility change and failed because the private type could not be imported. Its log is preserved as `evidence/performance-tests-attempt1.log`; it is not a test failure or a valid performance sample.

## Source-level changes and limits

Topology grouping is prepared once per parent body evaluation. Project ordering precomputes first-session positions and running membership before sorting. The dot grid uses a repeated image tile. A card's gesture translation is local to that card, while the observable shared drag state is read by edge layers. Static paths and incident moving paths have separate renderers.

Moving edges still scan displayed sessions and construct a position dictionary when connection rendering is enabled. The change reduces invalidated views and the number of paths stroked, but is not a constant-work algorithm. The current canvas retains all expanded cards rather than virtualizing them.

No controlled before/after frame-time benchmark, compositor FPS measurement, or physical-device performance measurement is supplied by the automated harness. A passing test, elapsed data-preparation sample, or layout invalidation counter does not establish perceived smoothness. Actual macOS gesture evidence belongs in the corresponding runtime evidence log and screenshots.

## 실제 macOS 드래그 관찰

Release 앱의 `--performance-catalog`에서 606개 실제 저장된 세션을 모두 펼쳤습니다. 이 모드는 메모리만 변경하며 Codex 구독과 작업공간 저장을 실행하지 않습니다. `evidence/performance-ui.log`에 기록한 완료 드래그 3회는 각각 33회, 14회, 18회의 좌표 갱신을 수신했습니다. 각 드래그 이동 구간의 토폴로지 배치 재계산은 0회였습니다. 드롭 후 저장과 배치 계산은 측정 구간 뒤에 실행합니다.

프로젝트 행 높이는 각 행의 세 프로젝트 중 가장 많은 표시 카드 수로 정합니다. 앞 행의 높이를 누적하여 다음 행을 배치합니다. 모든 행에 전체 프로젝트의 최대 카드 수를 적용하던 불필요한 빈 공간을 줄였습니다.
