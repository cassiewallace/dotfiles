# iOS dotfiles

My macOS dotfiles as an iOS engineer working with AI coding agents: shell config, Claude Code setup, and a manifest of agent skills for Swift, SwiftUI, UIKit, and accessibility work.

This repo is the source of truth for my AI-era dev environment: global Claude Code instructions, hooks that keep agents on the rails of Apple-platform tooling (FlowDeck instead of raw `xcodebuild`/`xcrun simctl`), and a reproducible list of agent skills covering Swift concurrency, Swift Testing, SwiftUI patterns, iOS/UIKit/AppKit accessibility audits, and the Airbnb Swift style guide. Inside:

- **`zsh/`**: `.zshrc` and `.aliases`.
- **`claude/.claude/`**: global config for [Claude Code](https://claude.com/claude-code).
  - `CLAUDE.md`: global instructions covering Swift style, verification rules, PR/commit conventions, and pointers to every agent skill.
  - `settings.json`: theme, enabled plugins, and the FlowDeck PreToolUse hook.
  - `hooks/flowdeck/flowdeck-guard.sh`: blocks `xcodebuild`, `xcrun simctl`, `xcrun devicectl`, and friends in favor of [FlowDeck](https://flowdeck.dev), the agent-friendly replacement for Apple's CLI tools.
- **`skills.manifest`**: every external [agent skill](https://www.anthropic.com/news/skills) I use, with the `npx skills add` command to re-install it.
- **`Brewfile`**: Homebrew packages (scaffold; add as you go).

## Agent skills

The skills in `skills.manifest` cover the surface area of iOS work I hand off to agents:

| Skill | What it does | Source |
|---|---|---|
| `swift-concurrency` | async/await, actors, Sendable, Swift 6 strict-concurrency migration | [avdlee/swift-concurrency-agent-skill](https://github.com/avdlee/swift-concurrency-agent-skill) |
| `swift-testing-expert` | Swift Testing (`@Test`, `#expect`, traits, parameterization), XCTest migration | [avdlee/swift-testing-agent-skill](https://github.com/avdlee/swift-testing-agent-skill) |
| `swiftui-expert-skill` | SwiftUI state, layout, animation, Instruments trace analysis | [avdlee/swiftui-agent-skill](https://github.com/avdlee/swiftui-agent-skill) |
| `airbnb-swift-style` | enforces the Airbnb Swift style guide | [cassiewallace/Airbnb-Swift-Style-Agent-Skill](https://github.com/cassiewallace/Airbnb-Swift-Style-Agent-Skill) |
| `ios-accessibility` | VoiceOver, Dynamic Type, traits, focus order; iOS-wide audit | [dadederk/iOS-Accessibility-Agent-Skill](https://github.com/dadederk/iOS-Accessibility-Agent-Skill) |
| `uikit-accessibility-auditor` | UIKit-specific accessibility audits | [rgmez/apple-accessibility-skills](https://github.com/rgmez/apple-accessibility-skills) |
| `swiftui-accessibility-auditor` | SwiftUI-specific accessibility audits | [rgmez/apple-accessibility-skills](https://github.com/rgmez/apple-accessibility-skills) |
| `appkit-accessibility-auditor` | macOS / AppKit accessibility audits | [rgmez/apple-accessibility-skills](https://github.com/rgmez/apple-accessibility-skills) |
| `find-skills` | discover and install new skills from skills.sh | [vercel-labs/skills](https://github.com/vercel-labs/skills) |

Two CLI tools that I use alongside the skills above are installed separately. Both ship their own Claude Code skill as part of the install:

- **[FlowDeck](https://flowdeck.dev)**: agent-friendly replacement for `xcodebuild`, `xcrun simctl`, `xcrun devicectl`, `instruments`, and the rest of Apple's CLI tooling. Returns structured JSON, handles build/run/test/launch/log/screenshot, and drives UI automation on iOS and macOS. The FlowDeck install bundles its own Claude Code skill (at `~/.claude/skills/flowdeck/`), and `claude/.claude/hooks/flowdeck/flowdeck-guard.sh` in this repo blocks agents from falling back to the raw Apple CLIs.
- **[RocketSim](https://www.rocketsim.app)**: iOS Simulator companion app whose `rocketsim` CLI exposes accessibility-element snapshots and gesture/keyboard input to agents. Also ships its own Claude Code skill.

## Install

```sh
git clone git@github.com:<you>/dotfiles.git ~/Developer/personal/dotfiles
cd ~/Developer/personal/dotfiles
./install.sh --dry-run    # preview first
./install.sh              # symlink files + restore agent skills
./install.sh --brew       # also run `brew bundle`
```

Re-running `install.sh` on the same machine is a no-op. If it finds an existing real file where a symlink should go, it moves the original to `<file>.dotfiles-backup-<timestamp>` before linking.

Requirements: macOS, Bash, `git`. `npx` (from Node) is required for skill restore; skip it with `--skip-skills` if Node isn't installed yet.

## Adding a new tracked file

Put it at the same relative path inside a package. The tree mirrors `$HOME`:

```
zsh/.zshrc                              -> ~/.zshrc
claude/.claude/settings.json            -> ~/.claude/settings.json
claude/.claude/hooks/foo/foo.sh         -> ~/.claude/hooks/foo/foo.sh
```

Then re-run `./install.sh`. The installer walks each package as files (not directories), so existing unrelated content in `~/.claude` (sessions, plans, etc.) is left alone.

## Adding a new agent skill

Append a line to `skills.manifest`:

```
<skill-name> | npx skills add <owner>/<repo>@<skill> -g -y
```

`install.sh` skips any skill whose `~/.agents/skills/<skill-name>/` directory already exists, so it's safe to re-run after adding a line.
