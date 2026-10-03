# Astra design-application review

Review date: 2026-10-03. Authoritative reference: `design-previews/maestro-topology.html`, supplied from chat `01a1010f-d0da-79e1-98fb-85e938299200`. Review scope: the applied native design, functional regressions, blocking layout defects, accessibility, and preservation of the previously accepted IPC and drag ownership. The reviewer inspected source and saved evidence without taking CUA control or changing implementation.

## Disposition

**Accepted within the documented native local-app scope after corrections. No unresolved blocking defect was found in the reviewed paths.** The palette, panel hierarchy, project inspection, and restrained native controls substantially implement the reference. Two P2 defects were found: incorrect unassigned-project inspection totals and collision-prone relationship labels. Both have been corrected and re-reviewed against source and tests; the label correction was also independently confirmed in saved light/dark pixels. No new IPC, persistence, prompt-authorization, or transcript-ownership regression was found. This acceptance is not a claim of complete HTML interaction parity, arbitrary dense-graph readability, measured FPS, or actual prompt E2E completion.

## Findings

### D1 — P2 — Unassigned project inspection reports zero sessions — RESOLVED

Initial location: `Sources/CodexMaestro/SessionInspector.swift:33`.

The new project inspector filtered membership with `session.projectID == project.id`, but the graph represents nil membership using the synthetic ID `unassigned`. Selecting that node therefore showed zero sessions and zero running sessions despite nonzero card/sidebar totals.

The implementation now uses `ProjectInspectorSummary` with the same nil-membership mapping as topology grouping. The added `testUnassignedInspectorMatchesGroupingTotalsAndDirectionalLinkMembership` checks three unassigned sessions, one running session, exclusion of a registered running session, and incoming/outgoing project-link membership. The focused run in `evidence/design-unassigned-inspector-tests.log` passes. This is source/store evidence; the reviewer did not drive the inspector with CUA.

### D2 — P2 — Relationship labels overlap cards and become unreadable — RESOLVED

Initial locations: `Sources/CodexMaestro/TopologyCanvas.swift:325-333`; reference `design-previews/maestro-topology.html:119-135`.

The initial native label renderer always placed text at a cubic midpoint, beneath the node layer. Adjacent column centers were 285 points apart with 240-point cards, leaving only a 45-point gap. A wider relationship label therefore crossed a card boundary. Same-column links could also collide with nearby cards. Endpoint-pair lane offsets separated repeated links but did not avoid unrelated cards or labels.

The reference includes a `placeLabel` collision search over node and existing-label rectangles. The implementation session reproduced clipping in the basic demo. This reviewer independently inspected the saved pixels in `evidence/design-dark-initial.png`: the bridge → test review caption is partly hidden under the neighboring SYNC card. The correction now searches clear positions against card bounds and previously reserved caption bounds, includes label half-size in the obstacle prefilter, and draws a leader when displaced from the curve. Final rendered acceptance checks are listed below.

## Reference alignment and intentional native differences

The adaptive light/dark palette mirrors the reference's canvas, sidebar, text, borders, selection, status, and relationship colors. The code uses the system font hierarchy, smaller headings, compact cards, blue selection, subdued membership branches, a dotted background, relationship captions, and a legend. The toolbar now uses native macOS controls instead of reproducing window controls in app content. Sidebar and inspector visibility controls are present.

Project-node selection is separate from the sidebar filter. Selecting a project inspects its relationships without changing graph scope; selecting a session restores session inspection. Project selection invalidates old transcript work and preserves drafts. Tests also verify return from project inspection to the handoff target. A selected project's incoming and outgoing relations are available in the inspector, and connection management keeps explicit direction, purpose, notes, edit/delete, and reviewed draft preparation.

The native implementation retains split-view resizing, a scrollable/zoomable graph, collapsed large-catalog groups, and nested native connection sheets. These are reasonable desktop adaptations rather than byte-for-byte copies of the six-session browser mockup. The minimum application size remains 1120 × 720; the HTML's phone-sized responsive layouts are not implemented or claimed.

One interaction differs from the reference: HTML relationship captions are accessible buttons that select the destination and the connections tab. Native captions are painted Canvas text beneath `allowsHitTesting(false)` and do not provide that direct activation. Equivalent relationship navigation remains available in the inspector and manager. This is a nonblocking reference-parity limitation, not a claim that native captions are accessible controls. VoiceOver and complete keyboard navigation were not independently exercised.

## Performance and correctness boundaries

The local `GestureState`, frozen drag origin, edge-only shared observable drag state, separate static/incident edge renderers, and cached dot tiles remain in place. New related-node highlighting computes sets outside pointer updates; it does not make the layout observe drag offsets. Grouping still occurs once per topology body evaluation. Expanded cards remain eagerly retained, and moving-edge work still scales with displayed items and relevant relationships. Label collision work must remain in the edge layer and must not reintroduce parent-layout invalidations.

The previously accepted read-only SQLite access, inherited thread settings, explicit reviewed prompt send, one-shot dispatch, off-main deadline-bounded writes, disconnect behavior, connection rollback, and generation-owned transcript reads remain present. The design does not convert project relations into actual Codex dependencies or automatic sends.

## Evidence

- `evidence/design-tests.log`: the initial integrated design run passes 23 core and 22 app tests, 45 total, with zero failures. Final `evidence/design-final-tests.log` passes **23 core and 29 app tests, 52 total, with zero failures**, including the review corrections.
- `ProjectInspectorSelectionTests`: graph-filter independence, draft preservation, stale-transcript exclusion, and handoff return to session inspection.
- `TopologyDesignTests`: both-direction neighbor highlighting and preservation of all 601 synthetic sessions plus saved positions across project-node selection.
- `evidence/design-package.log`: initial integrated release build and local ad-hoc package generation completed. This artifact precedes review corrections where applicable.
- `evidence/design-final-package.log`: final corrected release build/package completed; the implementation session reports local signature verification. This remains local ad-hoc packaging, not notarized distribution.
- `evidence/design-dark-initial.png`: independently inspected saved screenshot confirms the dark palette/panel hierarchy and reproduces the initial D2 label clipping. It is not final corrected-layout evidence.
- `evidence/performance-label-tests-final.log`: 13 focused tests pass: six label-geometry tests, five existing 601-session performance tests, and two design tests. The geometry regressions reproduce the 45-point gap collision, check project headers and an intervening card, reserve distinct parallel/reverse labels, reject a fully blocked search, and cover an obstacle outside the center-search radius but inside the label frame.
- Earlier transport review: `evidence/astra-backpressure-before.log` and `evidence/astra-backpressure-after.log` independently demonstrate the corrected stalled-peer actor responsiveness. The design test run retains the stalled-peer regression.

The implementation session owns actual light/dark UI, connection-flow, and dragging QA. Those observations and any independently inspected screenshots will be identified explicitly in the final re-review. Passing tests do not establish visual fidelity, FPS, perceived smoothness, actual prompt E2E completion, notarization, or future private-IPC compatibility.

## Final re-review

The corrected geometry and its actual assertions were inspected independently. Static reservations are calculated by `TopologyEdges`, which observes the dragged session ID but not its offset. The incident renderer receives those reservations and observes offset/base point. This preserves pointer-update ownership while giving stationary labels stable positions. The prefilter was widened after a reviewer-identified boundary case so a full candidate frame cannot overlap an omitted edge obstacle.

Two explicit limits remain. A moving unrelated card can temporarily cover a static caption until drop; rebuilding every static reservation on each pointer tick was intentionally avoided. If no clear candidate exists within the bounded 240-point search, the caption is omitted while the relation remains drawn and accessible through the inspector/manager. These are documented tradeoffs, not a general guarantee for arbitrary dense graphs.

The reviewer independently inspected four final saved screenshots captured by the implementation session at 1480 × 920 points and 85% graph zoom:

- `evidence/design-dark-final.png` and `evidence/design-light-final.png`: all three demo project columns are visible. The bridge → test review caption clears the SYNC card and is readable in both themes. Inspector headings, relationship rows, composer, sidebar, and legend retain the intended hierarchy.
- `evidence/design-session-label-final.png`: the same-row design → watch context caption is placed above the cards with a leader to its arrow. It is not clipped by either endpoint.
- `evidence/design-project-label-final.png`: the same-row app → runner project context caption is placed above the header cards. The session caption remains separate and readable.

The saved `evidence/design-ui.log` records implementation-session CUA observations for appearance switching, project inspection without graph filtering, hiding/restoring both panels, connection creation, handoff draft preparation, and demo send. These actions were not repeated by the reviewer. They used in-memory demo relationships and sent no real prompt.

The final saved read-only probe in `evidence/design-live-probe.log` reports 31 projects, 606 unarchived sessions, 11 live snapshots, and 30 saved transcript messages. These are run-specific actual-catalog observations, separate from the six-session demo screenshots. Additional full-catalog drag counters may supplement performance evidence; they are not needed to reinterpret the source/tests or final screenshot findings and do not establish perceived smoothness by themselves.
