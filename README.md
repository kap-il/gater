# g8r

A living map of your codebase, organised by the components your plans describe. Click a component to see its plan, its files and what it depends on. Click one that isn't built yet to start building it.

g8r (formerly Gater) is a macOS app. It runs stock Claude Code sessions in its own terminal panes and watches what they do; it never changes how Claude works.

```
┌──────────────────────┬──────────────────┬───────────────────┐
│ map  shell           │ build: auth      │  Events           │
│                      │  (claude)        │  15:02 edit …     │
│  living map          ├──────────────────┤  15:02 command …  │
│                      │ build: dash      │  15:03 stop …     │
│                      │  (claude)        │                   │
└──────────────────────┴──────────────────┴───────────────────┘
```

## Status

The map exists today as a prototype in `planmap/`, run against g8r's own source. The app is the workbench the map will move into: terminal panes, worktrees, and a log of what each session did. `planmap/PLAN.md` is the plan for joining the two.

## The map

```sh
python3 planmap/build_map.py --test   # measure the repo, run the tests
open planmap/index.html
```

- **Components, not tasks.** Nodes come from plan docs and stay after the plan ships.
- **Measured.** Files, lines, tests and edges are read from the repo. A node is "built, tests pass" because the tests passed.
- **Plan against code.** Edges are drawn as confirmed, in the code but not the plan, or in the plan but not the code. Code no plan mentions shows up as its own node.
- **Plans as overlays.** Unbuilt components appear dashed, in build order, with what they would change outlined.
- **Build prompts.** An unbuilt node composes a prompt from its plan section and the real signatures of what it depends on.
- **Replay.** The slider rebuilds the map commit by commit.

`planmap/plan.json` holds the components each plan doc declares. Everything else is measured by `build_map.py`.

## The app

- **Terminal.** A native AppKit terminal on [libghostty-vt](https://github.com/ghostty-org/ghostty), with CoreText rendering, selection, scrollback and mouse reporting.
- **Panes.** One session in the repo itself, plus one per worktree. New Delegate creates `../<repo>-<name>` on branch `g8r/<name>` and starts `claude --name delegate-<name>` there.
- **Event log.** Hooks report each session's edits, shell commands and stops to `.g8r/events.jsonl`. The hooks only observe; nothing blocks a tool call.
- **Libraries, not yet wired into the app:** the tree-sitter symbol engine (TypeScript, TSX, JavaScript), the language-server reference engine, and dependency-ordered integration into `g8r/integration` with a test run after each merge.

## Requirements

- macOS on Apple Silicon, Xcode / Swift 6
- [Zig](https://ziglang.org) 0.16 (builds libghostty-vt)
- [Claude Code](https://code.claude.com)
- Optional: [Bun](https://bun.sh), to install TypeScript 7 for the reference engine

## Setup

```sh
git clone --recurse-submodules https://github.com/kap-il/gater.git g8r
cd g8r
scripts/build-ghostty.sh          # builds Vendor/ghostty/GhosttyVT.xcframework
swift build

# Optional, TypeScript 7 for the reference engine, kept out of your home folder:
mkdir -p ~/.g8r/tools && cd ~/.g8r/tools
[ -f package.json ] || echo '{"name":"g8r-tools","private":true}' > package.json
bun add typescript@^7
```

## Running

g8r works on a git repository with at least one commit:

```sh
cd path/to/your-repo
swift run --package-path path/to/g8r G8r
```

| Shortcut | |
|---|---|
| ⌘⇧D | New delegate (asks for a name) |
| ⌘T | New shell |
| ⌘W | Close the focused pane |
| ⌘1–⌘9 | Focus tabs, then delegate boxes |
| ⌘C / ⌘V | Copy selection / paste |

Delegate boxes collapse from their title bar. **G8r → Auto-trust Delegate Worktrees** (off by default) marks worktrees g8r creates as trusted in Claude Code, only if you already trust the repo, so new sessions skip the trust prompt.

### Per-repo config

`<repo>/.g8r/config.json`:

```json
{ "test_command": "npm test" }
```

Used by the integrator after each merge. `G8R_TEST_COMMAND` overrides it.

## What g8r writes

In your repository (excluded via `.git/info/exclude`, so `git status` stays clean):

| Path | |
|---|---|
| `.g8r/events.jsonl` | the event log |
| `.claude/settings.local.json` | g8r's hooks, merged with yours, in each session's worktree |

Next to it: `../<repo>-<name>` worktrees. In your home folder: `~/.g8r/` (event socket, tools) and, only with auto-trust on, trust entries in `~/.claude.json`.

## Repository layout

| Path | |
|---|---|
| `Sources/G8rCore` | event log and bus, hooks, worktrees, integration, language-server client, path globs. No UI, Linux-buildable |
| `Sources/G8rSymbols` | tree-sitter symbol engine, diffs, reference engine |
| `Sources/G8rTerminal` | libghostty-vt terminal core, PTY, sessions |
| `Sources/G8rPTY` | forkpty/exec in C |
| `Sources/g8r-hook` | the Claude Code hook CLI |
| `App/` | the macOS app: terminal view, panes, event feed |
| `planmap/` | the map prototype and the plan |
| `Vendor/ghostty` | Ghostty submodule (pinned) + build output |

## Development

```sh
swift test
```

The language-server tests need TypeScript 7 in `~/.g8r/tools` and skip otherwise.

| Variable | |
|---|---|
| `G8R_AGENT_COMMAND` | run something other than `claude` in session panes |
| `G8R_COLLECTOR` | event socket path (default `~/.g8r/g8r.sock`) |
| `G8R_TSC` | explicit TypeScript 7 binary |
| `G8R_SNAPSHOT=<png>` | render the window to a PNG after 2 s |
| `G8R_DEBUG_DELEGATES=a,b` | open delegates at launch |
| `G8R_DEBUG_COLLAPSED` / `G8R_DEBUG_TOGGLE` | collapse / round-trip delegate boxes |

## Limitations

- The map is a prototype: it scans Swift with regular expressions and is not yet part of the app.
- The symbol and reference engines cover TypeScript, TSX and JavaScript.
- Apple Silicon build of libghostty-vt only (`scripts/build-ghostty.sh`).
