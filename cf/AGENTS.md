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

Sunō is a ski and snowboard tracking app that encourages exploration. This repository owns map publication and delivery through Cloudflare Workers and private R2 storage.

## Ownership and scope

- Accept completed map packages from the generation project. Keep generation, delivery and app integration independent; do not import companion repositories' code or configuration, or invoke their build tools.
- Keep service access independent of client platforms. Deliver credentials as neutral data; each client owns its local setup and integration.
- Preserve approved package contents, map appearance, source attribution and the public address contract. Delivery changes must not alter the map project's data or rendering decisions.
- Make only requested changes. Explain additional concerns and the options, including leaving them unchanged, before implementing a remedy. Honor explicit deferrals and retain the outstanding requirement.
- Resolve compatibility within the chosen toolchain before introducing alternatives. Consult authoritative platform guidance and identify custom integration work. Add dependencies or automation only for a demonstrated need.
- Keep related statements together in code and separate distinct operations with deliberate spacing.

## Local workflows

- Group Just recipes by responsibility and reserve the main entry point for shared actions. Keep publication and verification in one package group with an explicit local or cloud destination, and name the infrastructure group terraform. Selecting a group must list its actions without starting an operation.
- Give each public and private Just recipe a single-word name. Do not join several words with punctuation or run them together to avoid that rule.
- Keep setup responsibilities together, with separate choices for package input and local runtime storage. Keep credential lifecycle actions in their own group.
- Define configuration requirements in executable code. Fail clearly when required storage is unavailable; never silently select another location.
- Warn about unknown names in project configuration without blocking work, exposing values or rewriting the user's settings. Keep warnings in diagnostic output and ignore unrelated inherited settings.
- Keep local storage identity and layout stable. Do not introduce alternate storage targets, relocate state or remove it as a side effect of tooling changes.
- Serve development maps through one workflow that shuts down cleanly when interrupted. Default to the latest successfully published local release and require an explicit choice to use a remote release.
- Verify map rendering and app integration with the actual app in debug mode. Do not maintain a browser viewer for verification.
- Stop local serving before publication or verification accesses the same persisted storage. Provisioning and deployment must never run implicitly from local work.
- Maintain command help alongside its implementation. Keep procedural instructions short and ordered, with only the actions needed to complete the workflow.

## Package publication and delivery

- Use the same publication behavior and input choices for local and cloud storage. Storage differences belong at the storage boundary.
- Leave source packages unchanged. Verify their integrity before publication and verify transferred data before reporting success. Reuse verified unchanged content when publication is repeated.
- Transfer package contents sequentially and bound the work within each transfer. Keep transfer size and concurrency configurable within storage limits so large archives do not require unbounded memory.
- Preserve interrupted transfers for manual retry. Resume only when the input and acknowledged progress match exactly, prevent concurrent work from sharing that progress, and require an explicit action to abandon a transfer.
- Give each release an unambiguous identity that is safe for public addresses. Keep storage organization out of those addresses and publish the completion record only after all content is ready.
- Fast verification must compare the complete local package with the exact published inventory and integrity evidence without downloading large remote bodies. A multipart transfer receipt does not prove whole-file integrity.
- Budget storage for both the source package and the local storage copy. Avoid another full-sized assembly copy and access storage only through supported interfaces.
- Preserve map-response caching. Keep cached content separate across deployments and selected releases so an update cannot reuse stale responses.
- Keep R2 private behind the delivery service.

## Infrastructure ownership

- Use Terraform as the sole owner of production resources, service credentials and deployments. Import existing resources before changing them. Keep Wrangler for local development and bundling; do not deploy through it or bypass Terraform with ad hoc service calls.
- Keep map publication separate from infrastructure management. Build and validate the deployment artifact explicitly, then let Terraform own its upload and activation.
- Keep runtime code and local tooling separate. Infrastructure declarations remain Terraform-only; executable infrastructure helpers belong with local tooling. Verify that deployment artifacts contain no local tooling dependencies.
- Declare shared development dependencies once and keep one dependency lock. Use the latest published versions when selecting dependencies, verify them against their registry and align runtime support with the selected platform.
- Keep one private, locked infrastructure state outside version control. Back it up before applying a reviewed, saved plan. Check the active deployment when assessing drift; historical deployment records are insufficient.
- Bootstrap management access outside the state it manages. Keep one management credential and derive its storage access locally; keep it separate from publication credentials and client applications.
- Prefer a clean managed setup for development credentials over compatibility layers that preserve manually created access.

## Access and public distribution

- Keep controlled-device development access separate from public distribution. Require implementation and verification of the public-access design before release; a working development credential does not establish readiness.
- Preserve the agreed public-access design: verify installations with App Attest before distributing renewable Cloudflare Access credentials, without requiring user accounts. Keep bootstrap, map and management privileges separate.
- Use a bounded shared pool of expiring map credentials. Keep rotation and revocation under service ownership, and fail closed when verification or credential issuance fails. Development clients must not create production bypasses.
- Enforce map authorization before Worker execution at every entry point, including previews and cached responses. Never cache credential-exchange responses or expose credentials through diagnostics.
- Before public distribution, validate abuse limits, bounded resource use, monitoring and incident response. Authentication and usage alerts do not establish a spending cap.
- Keep credentials, installed dependencies, map packages and runtime data out of version control.

## Operations and evidence

- Run imports, publications, benchmarks, provisioning, deployments and version control commits or pushes only when explicitly requested. A tooling change does not authorize an operational run.
- Do not add tuning or benchmark machinery without a request. Failed transfers can be retried manually through the established workflow.
- Distinguish intended behavior, implementation, verification and deployment in reports. Local emulation cannot establish production access enforcement, edge caching or network performance.
