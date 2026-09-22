# Scope and discovery

- These instructions apply throughout the repository. Before working in a subfolder, look for and read every AGENTS.md along the path from the repository root to the files you will touch. Repeat this check when working in deeper folders. More-specific instructions take precedence within their subtree.
- Keep shared instructions in this file and project-specific instructions in nested AGENTS.md files. Do not duplicate inherited rules.
- Keep Codex configuration at the repository root, not in per-project folders.

# Maintaining these instructions

- Keep AGENTS.md files as the only non-code files written for agents. Documentation and READMEs are the only exceptions. Do not create separate files that narrate the code.
- Record lasting decisions, ownership, tradeoffs and deferred commitments. Add a rule only when user direction or an accepted decision establishes its lasting scope, it guides a future choice, and it remains useful across implementations that preserve the same intent.
- State durable decisions precisely, including chosen platforms or tools when the choice matters. Keep command examples, source inventories, paths, configuration values and implementation descriptions with the code that defines them.
- Code and tests establish current behavior. A requested behavior change alone does not establish permanent policy. Before finishing an edit, check every changed rule against the inclusion criteria above and remove implementation descriptions or unsupported constraints. Resolve uncertain intent before creating a requirement.
- Record lasting user conventions in the same change. Preserve their scope and strength, distinguish requirements from preferences, and keep exceptions beside their rules. Do not generalize temporary corrections or silently change policy.
- Before retiring guidance, preserve still-relevant decisions in the applicable AGENTS.md and keep operational knowledge discoverable through code and tool help. Keep task updates and incident histories in the conversation.
- Give each rule one purpose. Revise existing rules instead of appending duplicates. Merge overlaps, remove obsolete guidance and explain reasons where they help future decisions.
- Read and follow [unslop](https://www.skills.sh/cursor/plugins/unslop) when editing. Use plain words and complete sentences, cut filler and repetition, and reread for clarity. Keep the wording direct without weakening requirements or adding implementation detail. Keep each paragraph and list item on one source line; do not add manual line wraps or unnecessary blank lines.
- Treat sunoh-docs as a closed, read-only archive. Do not consult or maintain it, restore its contents as active guidance, or make active workflows depend on it.
- Do not retrieve other conversations or saved memories, or use them as context. Saving and inspecting the current conversation are allowed.

# Project direction

Sunō is a ski and snowboard tracking app that encourages exploration and personal progress. Use Sunō in the interface, documentation and prose. Use Sunoh only when ASCII characters are required.

## Ownership and scope

- Keep map generation, delivery and app integration independent. Consume published interfaces without depending on another project's internal code, configuration or build tools.
- Make only requested changes. Explain additional concerns and the options, including leaving them unchanged, and wait for a decision before implementing a remedy.
- Honor explicit deferrals and retain the outstanding requirement.

## Version control

- Always use SSH for Git remotes.
- Commit or push only when explicitly requested.
