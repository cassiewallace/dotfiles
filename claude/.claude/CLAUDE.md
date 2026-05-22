@/Users/cassiewallace/.agents/skills/airbnb-swift-style/SKILL.md
@/Users/cassiewallace/.agents/skills/swift-concurrency/SKILL.md
@/Users/cassiewallace/.agents/skills/swift-testing-expert/SKILL.md
@/Users/cassiewallace/.agents/skills/swiftui-expert-skill/SKILL.md
@/Users/cassiewallace/.agents/skills/appkit-accessibility-auditor/SKILL.md
@/Users/cassiewallace/.agents/skills/find-skills/SKILL.md
@/Users/cassiewallace/.agents/skills/uikit-accessibility-auditor/SKILL.md

## Commit message preferences

- Always write 1-line commit messages. No body, no trailing newlines, no extra paragraphs.

## Git push preferences

- Never run `git commit`, `git push` (or `git push --force`, `--force-with-lease`, etc.) unless I explicitly tell you to. Stage changes if helpful, but don't commit or push.

## Verification

- Never assert claims about code behavior, framework APIs, idiomatic patterns, or library internals from memory. Verify in the current session (cupertino, SDK source, running tests, simulator screenshot) or say "I don't know, let me check."
- When a reviewer or user suggests a change, try it first. Defending the existing code is the second move, not the first.
- If verification cost is high (e.g. needs the simulator and would be disruptive), say that and let the user decide whether to verify or trust the claim. Do not silently assert.

## PR preferences

- Format PR titles as `[TICKET-ID] Title` with the ticket ID in square brackets, e.g. `[PROJ-123] Persist navigation state across launches`.
- Use "## Testing" (not "## Test plan") as the testing section heading.
- Use "## Changes" (not "## What changed") as the changes section heading.
- Write testing steps as user-facing scenarios (what the user does and sees), not implementation details. Reference the user type/situation from the Linear ticket when relevant (e.g. "as a returning user with an empty inbox") and frame steps in simulator terms.
- Prefer small, discrete commits with clear commit messages describing the change, even on draft PRs. Don't amend prior commits to fold in new changes; add new commits instead.
