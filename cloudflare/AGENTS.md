# Map delivery

This project owns map publication and delivery through Cloudflare Workers and private R2 storage.

## Ownership and scope

- Accept completed map packages from the generation project.
- Keep service access independent of client platforms. Deliver credentials as neutral data; each client owns its local setup and integration.
- Preserve approved package contents, map appearance, source attribution and the public address contract. Delivery changes must not alter the map project's data or rendering decisions.
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

- Run imports, publications, benchmarks, provisioning and deployments only when explicitly requested. A tooling change does not authorize an operational run.
- Do not add tuning or benchmark machinery without a request. Failed transfers can be retried manually through the established workflow.
- Distinguish intended behavior, implementation, verification and deployment in reports. Local emulation cannot establish production access enforcement, edge caching or network performance.
