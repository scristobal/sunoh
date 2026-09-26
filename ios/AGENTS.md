# iOS app

## Ownership and scope

- Keep this a native iPhone app with its Live Activity companion. Write app logic in Swift and use native persistence. Do not add other platforms or foreign language bridges.
- Keep recording and personal history useful without an account, backup or social sharing. Private backup and social sharing must remain optional and independently selectable; personal progress must not depend on social competition.
- Preserve offline use as a product requirement, including first launch. Hosted maps do not replace the deferred requirement for a small bundled fallback that works without online authentication. Its packaging needs an explicit decision.

## Recording and preservation

- Keep recording independent of view lifetime, navigation, route rendering and map-service availability. Backgrounding the app must not end an active recording.
- Treat persisted observations as the source of truth. Never present points as saved before persistence succeeds, and make failures and unsaved work visible.
- Resuming must continue the same activity. Preserve recorded observations and pause boundaries through saving, reopening and changes to storage.
- Preserve existing recordings during changes. Keep consistent backups and verify original observations before accepting a migration or restore. Recovery must establish that storage is healthy before presenting it as ready.
- Keep tests and development data preparation separate from the user's live recording store. Do not reset or replace real recordings to make a test pass.

## Analysis and data exchange

- Keep geographic calculations pure and separate from recording, persistence and presentation.
- Derive summaries, route presentation and previews from the same recording while keeping original observations intact. Display gaps and calculated values must not rewrite the recorded source.
- Keep activity type, sampling quality and source recording boundaries separate. Preserve explicit recording and imported segment boundaries in measurements and route drawing.
- Classify recorded intervals as Lift or Run for now. Detect lift rides and treat all remaining recorded time as Run, including stops, traverses and leading or trailing time. Keep internal lift stops within the lift ride and preserve explicit recording breaks separately.
- Use lift reference geometry as supporting evidence for classification. Missing or conflicting reference data must not veto a lift supported by recorded motion.
- Categorizing time within runs as skiing, snowboarding, transfers or stops is deferred.
- Do not read, persist or present piste or lift names in activity analysis, or expose track-matching ratings. Keep confidence calculations used for lift detection and retain resort identities and names.
- Apply data-quality gates per derivation, including map display, speed and activity classification, rather than through a shared sampling-gap cutoff. Implementing those gates is deferred; do not add a replacement global cutoff in the meantime.
- Rate sampling quality from the interval distribution and the time those intervals represent. Do not let the single longest interval determine an entry's rating.
- Extend recording quality with measurement-error estimation in a later step. Until then, describe the rating as sampling quality and do not imply that it measures positional accuracy.
- Persist statistics and route thumbnails together as derived results. Keep them consistent with the source and rebuild missing or outdated results without losing the recording.
- Failures in history loading, analysis or previews must not stop healthy recording. Keep original activity details usable when derived work fails.
- Export what the recorder provided: timestamps, coordinates, optional recorded elevation and segment boundaries. Do not substitute calculated statistics or inferred samples. Sharing previews must not change the exported recording.
- Preserve existing recordings during data exchange and keep history responsive as it grows. Detailed import and export behavior belongs in executable checks.
- Use GPX as the external format for development track seeds. Keep app-specific storage fields out of seed files.

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
