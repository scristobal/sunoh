# Maintaining this document

- Keep this as the only non-code file written for agents. Documentation and READMEs are the only exceptions. Do not create separate files that narrate the code.
- Record lasting decisions, ownership, tradeoffs and deferred commitments. Add a rule only when user direction or an accepted decision establishes its lasting scope, it guides a future choice, and it remains useful across implementations that preserve the same intent.
- State durable decisions precisely, including chosen platforms or tools when the choice matters. Keep command examples, source inventories, paths, configuration values and implementation descriptions with the code that defines them.
- Code and tests establish current behavior. A requested behavior change alone does not establish permanent policy. Before finishing an edit, check every changed rule against the inclusion criteria above and remove implementation descriptions or unsupported constraints. Resolve uncertain intent before creating a requirement.
- Record lasting user conventions in the same change. Preserve their scope and strength, distinguish requirements from preferences, and keep exceptions beside their rules. Do not generalize temporary corrections or silently change policy.
- Before retiring guidance, preserve still-relevant decisions here and keep operational knowledge discoverable through code and tool help. Keep task updates and incident histories in the conversation.
- Give each rule one purpose. Revise existing rules instead of appending duplicates. Merge overlaps, remove obsolete guidance and explain reasons where they help future decisions.
- Read and follow [unslop](https://www.skills.sh/cursor/plugins/unslop) when editing. Use plain words and complete sentences, cut filler and repetition, and reread for clarity. Keep the wording direct without weakening requirements or adding implementation detail. Keep each paragraph and list item on one source line; do not add manual line wraps or unnecessary blank lines.
- Treat sunoh-docs as a closed, read-only archive. Do not consult or maintain it, restore its contents as active guidance, or make active workflows depend on it.
- Do not retrieve other conversations or saved memories, or use them as context. Saving and inspecting the current conversation are allowed.

# Project direction

Sunō is a ski and snowboard tracking app that encourages exploration and personal progress. Use Sunō in the interface, documentation and prose. Use Sunoh only when ASCII characters are required.

## Ownership and scope

- Keep this a native iPhone app with its Live Activity companion. Write app logic in Swift and use native persistence. Do not add other platforms or foreign language bridges.
- Let the map generation and delivery projects own their respective work. Consume their published interfaces without depending on their internal code or tooling.
- Keep recording and personal history useful without an account, backup or social sharing. Private backup and social sharing must remain optional and independently selectable; personal progress must not depend on social competition.
- Preserve offline use as a product requirement, including first launch. Hosted maps do not replace the deferred requirement for a small bundled fallback that works without online authentication. Its packaging needs an explicit decision.

## Recording and preservation

- Keep recording independent of view lifetime, navigation, route rendering and map-service availability. Backgrounding the app must not end an active recording.
- Treat persisted observations as the source of truth. Never present points as saved before persistence succeeds, and make failures and unsaved work visible.
- Resuming must continue the same activity. Preserve recorded observations and pause boundaries through saving, reopening and changes to storage.
- Preserve existing recordings during changes. Keep consistent backups and verify original observations before accepting a migration or restore. Recovery must establish that storage is healthy before presenting it as ready.
- Keep tests and development data preparation separate from the user's live recording store. Do not reset or replace real recordings to make a test pass.

## Analysis and data exchange

- Derive summaries, route presentation and previews from the same recording while keeping original observations intact. Display gaps and calculated values must not rewrite the recorded source.
- Persist statistics and route thumbnails together as derived results. Keep them consistent with the source and rebuild missing or outdated results without losing the recording.
- Failures in history loading, analysis or previews must not stop healthy recording. Keep original activity details usable when derived work fails.
- Export what the recorder provided: timestamps, coordinates, optional recorded elevation and segment boundaries. Do not substitute calculated statistics or inferred samples. Sharing previews must not change the exported recording.
- Preserve existing recordings during data exchange and keep history responsive as it grows. Detailed import and export behavior belongs in executable checks.

## Interaction and accessibility

- Prefer native SwiftUI navigation and presentation. Let content and available space determine layout; do not depend on a particular device's dimensions or fixed safe areas.
- Make map previews tap targets that open the interactive map with a native zoom transition. Keep other map gestures in the full-screen presentation and keep draggable map details separate from tab navigation.
- Keep recording controls separate from full-screen map exploration.
- Use native default spacing instead of fixed spacing values.
- Keep recording status consistent across the app and its Live Activity. Distinguish readiness, ongoing work and failure so the interface does not promise an action the app cannot perform.
- Preserve readable content and reachable controls as text size, language and available space change. Keep primary recording actions stable during state changes and confirm destructive actions.
- Resolve map attribution before public release. Hiding it during development does not settle how the released app will credit its sources.

## Map access and privacy

- Keep development credentials and private recordings out of version control. Large offline map data also belongs outside the source repository.
- Keep infrastructure management and publication credentials out of the app. Send map-access credentials only to the intended secure service, including after redirects, and never expose them through diagnostics.
- Treat controlled-device access as a development arrangement. The agreed public design uses App Attest to obtain renewable Cloudflare Access credentials without requiring user accounts. The delivery service owns issuance and revocation; the app provides installation proof and refreshes its credentials.
- Keep development and production verification separate. Any unsupported-device policy needs an explicit decision; do not add a silent production bypass.
- Keep access failures separate from recording and history. Preserve offline use when changing authentication or map delivery.

## Validation

- After behavior changes, run the repository's test workflow and build, install and launch the app through its supported development workflow.
- Discover the selected simulator or device at runtime. Do not assume a device identity, model or screen geometry.
- Verify visible interactions on a running simulator or device. Exercise affected states and native system presentations; a successful build alone does not establish that they work.
- No not perform any accessibility audit nor checks, including but not limited to text size, VoiceOver visibility, reachability it, unless the user explicitly requests them.
- Distinguish automated checks, visual review and physical-device evidence. Report unavailable checks and unresolved diagnostics without calling them passed.
