# Native inspector design application

The inspector and connection manager use the final `design-previews/maestro-topology.html` reference. The native adaptation retains the reference's restrained hierarchy: 17-point medium inspector headings, 11-point metadata, Korean section labels, neutral surfaces, simple separator-based relation rows, and compact native buttons. Color comes from the shared adaptive Palette; these views no longer force a dark color scheme.

Session transcripts, refresh behavior, link validation, reviewed handoff drafts, pending-send state, disabled controls, and Command-Return sending retain the established behavior. Connection editing remains a native secondary sheet so validation and failed persistence keep the current editor available. Project links remain relationship metadata.

Selecting a project node presents its name, roots, session/running/link counts, incoming and outgoing relationships, and connection-management action. Selecting a related project retains project-inspector mode without changing sidebar filtering. Selecting a session returns to the session inspector. Project mode has no session composer. A late transcript read for an earlier session cannot publish under the project inspector.

Source compilation is retained in `evidence/design-inspector-build.log`. Existing connection/transcript regressions are retained in `evidence/design-inspector-tests.log`; project-selection, late-read, and reviewed-handoff regressions are retained in `evidence/design-project-inspector-tests.log`. These are source/store checks, not a rendered appearance or real delivery claim. Runtime inspection and final light/dark visual acceptance belong to the integrated app review.
