# Maintaining this document

- Keep this as the only non-code file written for agents. Documentation and READMEs are the only exceptions. Do not create separate files that narrate the code.
- Record lasting decisions, ownership, tradeoffs and deferred commitments. Each rule must guide a choice or protect a requirement as the code evolves.
- State durable decisions precisely, including chosen platforms or tools when the choice matters. Keep command examples, source inventories, paths, configuration values and implementation descriptions with the code that defines them.
- Code and tests establish current behavior, not permanent policy. Ground new rules in explicit user direction or accepted decisions; resolve uncertain intent before turning an observation or proposal into a requirement.
- Record lasting user conventions in the same change. Preserve their scope and strength, distinguish requirements from preferences, and keep exceptions beside their rules. Do not generalize temporary corrections or silently change policy.
- Before retiring guidance, preserve still-relevant decisions here and keep operational knowledge discoverable through code and tool help. Keep task updates and incident histories in the conversation.
- Give each rule one purpose. Revise existing rules instead of appending duplicates. Merge overlaps, remove obsolete guidance and explain reasons where they help future decisions.
- Read and follow [unslop](https://www.skills.sh/cursor/plugins/unslop) when editing. Use plain words and complete sentences, cut filler and repetition, and reread for clarity. Keep the wording direct without weakening requirements or adding implementation detail. Keep each paragraph and list item on one source line; do not add manual line wraps or unnecessary blank lines.
- Treat sunoh-docs as a closed, read-only archive. Do not consult or maintain it, restore its contents as active guidance, or make active workflows depend on it.
- Do not retrieve other tasks or saved memories, generate memories, or save task transcripts. Disable supported task-history persistence, and report any retention that project configuration cannot prevent.

# Project direction

Sunō is a ski and snowboard tracking app that encourages exploration. This repository owns acquiring map inputs, generating and validating map data, and assembling a completed package for delivery.

- The resort geometry pipeline collects and preprocesses ski resort, run and lift data for automatic resort selection and track matching. It does not render maps.
- Use OpenSkiData's single-file GeoPackage as the initial source for the resort geometry pipeline until a concrete blocker requires reconsidering it.

## Ownership and scope

- End this repository's responsibility at the completed package. Publication, delivery and app integration belong to the companion projects. Do not depend on their internal code, configuration or build tools.
- Make only requested changes. Explain additional concerns and the options, including leaving them unchanged, and wait for a decision before implementing a remedy.
- Preserve approved map appearance and rendering behavior. Refactoring the pipeline does not authorize changes to geometry, labels, zoom behavior, terrain treatment or source selection.
- Keep road geometry visible without street-name labels.
- Preserve source attribution and license notices in generated data and completed packages.
- Honor explicit deferrals. Do not restore removed experiments or temporary production paths, or introduce deferred packaging and runtime approaches, without a separate request.

## Generation and handoff

- Keep dependency discovery, scheduling, validation and packaging under Snakemake. Processing helpers must not become another scheduler.
- Make packaging consume completed inputs without starting generation. The completed package must contain everything its consumers need, without requiring the generation checkout or intermediate data.
- Keep completed packages immutable. Never overwrite them or automatically remove nonempty staging work after a failed or interrupted attempt.
- Preserve dependency tracking and cache identities. Do not force existing outputs to become a new baseline or add migration machinery without a request.
- Treat edits to work that determines cache identity as potentially expensive, even when behavior is unchanged. Avoid incidental formatting or refactoring that would invalidate reusable results.
- Process worldwide data with bounded memory and disk use. Preserve streaming and compression, and avoid unnecessary intermediate copies.

## Environment and preservation

- Use the project's pinned dependency environment. Do not install its dependencies system-wide or change the toolchain incidentally.
- Require the selected external data location to exist. Do not silently fall back, create a replacement or relocate data as a side effect.
- Keep generated data, workflow state, local configuration and credentials outside version control and separate from source and dependencies.
- Preserve expensive source and terrain caches. Do not use cleanup as a migration or debugging shortcut.

## Execution and verification

- Run worldwide builds, destructive cleanup, cloud operations and version control publication only with explicit authorization. A task that downloads or regenerates large inputs is an operational run, not a routine check.
- Keep routine validation lightweight and relevant to the change. If inputs or storage are unavailable, report the limit instead of downloading data just to make a check pass.
- Before an authorized worldwide run, review the configuration, storage capacity, input readiness and planned work. Preserve completed packages throughout the run.
- Distinguish a valid plan from a completed run. Work discovered during execution needs execution evidence; a dry run cannot prove the whole pipeline succeeds.
- Treat downstream import, publication, delivery and visual inspection as separately requested activities. They are not prerequisites for producing the package.
