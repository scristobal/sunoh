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
- Treat sunoh-docs as a closed, read-only archive. Do not consult or maintain it, restore its contents as active guidance, or make active workflows depend on it.
- Do not retrieve other conversations or saved memories, or use them as context. Saving and inspecting the current conversation are allowed.

# Writing

- When editing text, check it against the rules below, revise it while preserving meaning and intended tone, and reread for clarity. Keep requirements direct without weakening them or adding implementation detail.
- Keep each paragraph and list item on one source line. Do not add manual line wraps or unnecessary blank lines.
- Remove superficial clauses such as "highlighting", "ensuring" or "reflecting" when they add no information. If the claim matters, state it concretely and support it with a source.
- Name the source of an attributed claim. Remove vague appeals to experts, reports or critics when no source is available.
- Prefer plain words over inflated vocabulary such as "additionally", "crucial", "delve", "enduring", "enhance", "fostering", "garner", "interplay", "intricate", "pivotal", "showcase", "testament", "underscore" and "vibrant", or abstract uses of "landscape" and "tapestry". Use "use" instead of "utilize" or "leverage", "help" instead of "facilitate", "many" instead of "numerous", and "if" instead of "in the event that".
- Use "is" or "has" when phrases such as "serves as", "stands as", "boasts" or "features" add no meaning.
- State the point directly instead of framing it as "not just X, but Y".
- Let the content determine how many items a list needs. Do not force ideas into groups of three.
- Use one consistent term for each concept. Do not cycle through synonyms for variety.
- Use "from X to Y" only when the endpoints belong to a meaningful scale. Otherwise, name the topics directly.
- Separate thoughts with periods or commas. Do not use em dashes, en dashes, parentheses or hyphens as substitute separators.
- Use colons before lists or examples, not to connect clauses in the middle of a sentence. Rewrite the sentence so the point stands on its own.
- Use bold sparingly. Do not emphasize every proper noun or acronym.
- Replace list items whose bold label and colon merely repeat the following text with prose. A bold lead-in that ends with a period is acceptable when it names the item and the following sentence adds new information.
- Use sentence case for headings.
- Remove decorative emojis from headings and list items.
- Use straight quotation marks instead of curly quotation marks.
- Remove stock chatbot openings, offers and sign-offs. Respond directly without flattery or exaggerated agreement.
- Cut filler and repetition. Replace "in order to" with "to" and "due to the fact that" with "because". Delete empty announcements such as "it is important to note that".
- Remove stacked hedges while preserving uncertainty that affects the claim. A single "may" is enough when that is the intended meaning.
- End with specific facts or plans when a conclusion is needed. Omit generic optimism and empty closing statements.
- Replace abstract jargon and metaphor with concrete terms. Check words such as "substrate", "wedge", "vector", "locus", "vantage", "nexus", "primitive", "harness", "surface", "bedrock", "scaffolding", "modality", "paradigm", "gold-plating", "ratchet", "evacuate", "endgame", "north star" and "flywheel" when used figuratively. Name the actual mechanism or action, such as "base", "add", "method", "move out" or "a limit that only tightens".
- Explain what something does with concrete instructions, facts, mechanisms or measurements. Replace impressions and slogans with information the reader can act on. Remove generic project descriptions that could appear unchanged in another project's documentation.
- Shorten or split sentences that require rereading. Keep one idea per sentence.
- Prefer active voice and name the actor. Use passive voice only when the actor is unknown or does not matter.
- Cut unnecessary adverbs. Use a stronger verb or a measured result instead of a vague claim about speed or improvement.
- Replace aphorisms, rhetorical fragments, personified code, figurative verbs and stock framing with literal statements. Say what the action or condition means.
- Write complete sentences with articles and verbs. Avoid compressed fragments, arrows and abbreviations that make readers decode the meaning.

<!--
The writing guidance incorporates the unslop skill from cursor/plugins, pstack/skills/unslop/SKILL.md, under the MIT License.
Copyright (c) 2026 Lauren Tan
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

# Project direction

Sunō is a ski and snowboard tracking app that encourages exploration and personal progress. Use Sunō in the interface, documentation and prose. Use Sunoh only when ASCII characters are required.

## Ownership and scope

- Keep map generation, delivery and app integration independent. Consume published interfaces without depending on another project's internal code, configuration or build tools.
- Make only requested changes. Explain additional concerns and the options, including leaving them unchanged, and wait for a decision before implementing a remedy.
- Honor explicit deferrals and retain the outstanding requirement.

## Tests

- During the fast iteration phase, persist tests only for geomatching and pure computations over tracks and geometries. Do not persist UI or UX tests while those behaviors are changing and regressions are expected.
- Use temporary tests during development when they help verify correctness or debug an issue. Run them and remove them before finishing unless they belong to the retained computation coverage.

## Version control

- Always use SSH for Git remotes.
- Commit or push only when explicitly requested.
