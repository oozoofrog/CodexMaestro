# Astra mixed-endpoint implementation review

Review date: 2026-10-03. Scope: directed session → session, project → project, session → project, and project → session relationships. This is an implementation review, separate from the user-owned Astra planning chat and its `ASTRA-FEATURE-PLAN.md`. The reviewer owns only this report and did not change source, tests, or application state or use CUA.

## Disposition

Accepted for the reviewed scope. Core typed identity, storage preservation, generic mutation rollback, and endpoint-specific UI paths are implemented. M2 has been corrected; the reviewer inspected its geometric assertions and final saved native pixels in both directions. The post-correction suite passes 71 tests, and the release package completes strict signature verification. No unresolved blocking source defect, data-loss path, unintended prompt dispatch, or project-membership mutation was found in the reviewed application paths. Native interaction observations belong to the integration owner; the reviewer did not perform CUA actions.

## Findings

### M2 — P2 — Same-column mixed edges pass through intermediate session cards — CORRECTED AND ACCEPTED

Initial location: `Sources/CodexMaestro/TopologyCanvas.swift:441-447`.

The mixed-edge path uses the shared center x coordinate for same-column endpoints. In the default demo, project app has center `(160,68)` and test has center `(160,456)`. The project → test edge runs at x = 160 from y = 97 to y = 400. It crosses the DESIGN card at y = 128...240 and BRIDGE card at y = 264...376. The reverse edge has the same obstruction. Because the edge renderer is beneath the cards, most of the relationship disappears and the remaining fragments resemble a chain through intervening sessions.

The 58-point project and 112-point session boundary calculations were correct, but direct vertical routing was suitable only when no intermediate cards occupied the route. The correction now uses the existing outside-right curve for all same-column relations, with typed heights constraining the source/target side anchors. The new app ↔ test regression checks both directions, control-point bounds, and 999 interior samples per direction: the path stays outside DESIGN/BRIDGE and inside the default 45-point column gap. Independent inspection of the final native screenshots confirms that the forward blue and reverse purple curves clear the intervening card bodies and terminate at their intended target boundaries.

An initial empty-project concern was withdrawn after rereading the current `WorkspaceView.swift:112`, which already checks both session and project emptiness. The current source allows a project-only topology; it is not an open finding.

## Data and schema assessment

`LinkEndpoint` includes kind and ID, so a project and session with the same raw string remain distinct nodes. Self-link checks compare typed endpoints. Direction and purpose participate in duplicate checks. Link UUID uniqueness is checked across all three storage buckets for new application mutations.

`allNodeLinks` adapts existing session and project arrays without rewriting their UUIDs, notes, drafts, or saved positions. New mixed relationships occupy the additive `nodeLinks` bucket. Cross-kind editing builds a candidate workspace, removes the old identity, validates the replacement, and commits only on success. Store mutations retain the complete previous workspace, so persistence failure restores all buckets and the schema marker together.

Creating a mixed relationship advances the workspace marker to version 2. The new reader accepts versions 1 and 2; mixed data on save is written with version 2. Deleting the final mixed relationship does not silently downgrade an already upgraded state. This protects against an older application loading a version-2 workspace because the previous loader rejects unsupported versions. It does not coordinate with an already-running older process that loaded version 1 before the upgrade; no concurrent-writer guarantee is claimed.

Missing endpoints are retained in stored relationships, displayed with typed missing-ID labels, and can be removed or repaired in the manager. New/edited relationships must resolve both typed endpoints against the current catalog. The synthetic unassigned grouping is not a real project and its project-connection controls are disabled. Nodes filtered out of the canvas cause only their projected edges to be omitted; the stored relationship is retained.

The initial generic edit removed and appended even note-only edits. The final source retains the old index for same-bucket edits after validating the candidate. `testNoteOnlyEditsRetainOrderWithinEveryStorageBucket` checks session, project, and mixed buckets. Changing endpoint kinds still moves the identity into its appropriate bucket; it does not duplicate the relationship.

## Capability and state ownership

The manager exposes all four direction filters and separate source/target kind selectors. Both inspectors show incoming and outgoing typed relationships and navigate to the other node. Canvas project and session connection controls use the same typed source/target state and generic save path. Cancellation clears the typed and legacy compatibility state together.

Project connection selection remains separate from sidebar filtering. Typed projection keys prevent a dragged session from moving a project with the same raw ID. The canonical saved positions are preserved, and only edges incident to the dragged session move. Static label reservations remain outside pointer-offset observation; the prior performance and label-placement limits still apply.

Only session → session relationships expose reviewed handoff preparation. Other combinations store metadata; they do not broadcast prompts, create execution dependencies, reassign sessions, move project roots, or invent a project-wide recipient. Existing one-shot prompt dispatch and generation-owned transcript reads remain separate from graph mutation. After review, the unified canvas editor's copy is conditional: session → session describes reviewed drafts, while project-involved relations explicitly state that they record reference relationships and send no message.

## Evidence inspected so far

- `NodeLinkTests`: all four direction/type combinations, same raw IDs in distinct namespaces, reverse relationships, purpose-specific duplicates, cross-bucket identity preservation, failed-edit atomicity, legacy version-1 decoding, version-2 round trip, malformed mixed storage rejection, disk preservation, and final `0600` permissions.
- `ConnectionManagerEndpointTests`: direction filtering, typed inspector membership, defaults, cross-kind edits, missing-endpoint validation through the store, unchanged session/draft/execution state, and persistence-failure rollback. These exercise model/store helpers; the test name mentioning rendering is not evidence that native views were mounted.
- `NodeConnectionSelectionTests`: all four canvas state transitions, typed target retention on failure, cancellation, unchanged membership/drafts, related empty project visibility, and sidebar-filter isolation.
- `MixedTopologyTests`: typed projection, incoming/outgoing highlighting, project/session boundary dimensions, same-ID drag isolation, filtered endpoint omission, and caption clearance. The original boundary test covers adjacent mixed endpoints and does not cover M2's intermediate-card obstruction.
- `evidence/mixed-final-tests.log`: the first integrated run passes 28 core and 41 app tests, **69 total**, with zero failures. This predates any M2 correction where applicable.
- `evidence/performance-mixed-route-tests.log`: 19 focused tests pass after M2's correction: six mixed topology tests, five 601-session performance tests, two design tests, and six label-placement tests. The reviewer inspected the route assertions rather than relying only on the test count.

Final corrected geometry, post-correction regression totals, package evidence, and independently inspected saved pixels are recorded below. No real user session prompt was sent by this reviewer. No performance, rendering, delivery, or persistence claim is inferred solely from another agent's completion statement.

## Final re-review

- `evidence/mixed-corrected-tests.log`: 29 core tests and 42 application tests pass after the final source corrections, **71 total**, with zero failures. This includes preservation of same-bucket edit order and the corrected long mixed-edge route. The reported 601-session layout sample is a layout-preparation measurement; it is not a rendering or frame-rate result.
- `evidence/mixed-corrected-package.log`: production build completes and the final bundle path is emitted. The reviewed `scripts/package-app.sh` uses `set -euo pipefail` and runs `codesign --verify --strict` before that final output, so this log supports completed packaging and strict signature verification. This is a locally ad-hoc signed bundle, not a notarized or published release.
- `evidence/mixed-long-edge-forward-final.png`: independently inspected saved native demo pixels show project CodexMaestro → TEST traveling around the right side of DESIGN and BRIDGE. The blue arrow terminates at TEST; the intervening card bodies no longer hide the long edge.
- `evidence/mixed-long-edge-reverse-final.png`: independently inspected saved native demo pixels show TEST → project CodexMaestro as the purple reverse curve, with its arrow terminating at the project header. Both directed mixed relationships remain visible alongside the existing session relationships.
- `evidence/mixed-project-inspector-final.png`: independently inspected saved native pixels show the selected project's three relations: outgoing project → project, outgoing project → session, and incoming session → project. The inspector distinguishes project and session endpoints and states that relations do not automatically deliver messages to project sessions. The canvas also shows session → session relationships. A still image establishes these rendered states, not the complete interaction sequence used to create them.

The accepted evidence covers source behavior, automated regression checks, local release packaging, and the saved native demo states above. It does not establish real-session prompt delivery, concurrent writes by older already-running app versions, notarization, publication, or rendering performance.
