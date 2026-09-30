# g8r

A living map of your codebase, organised by the components your plans describe. Click a component to see its plan, its files and what it depends on. Click one that isn't built yet to start building it.

g8r (formerly Gater) is a macOS app. It runs stock Claude Code or Codex sessions in its own terminal panes and watches what they do; it never changes how the agent works.

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
- **Panes.** One session in the repo itself, plus one per worktree. New Delegate creates `../<repo>-<name>` on branch `g8r/<name>` and starts the agent there (`claude --name delegate-<name>`, or `codex`).
- **Agents.** Type `claude` or `codex` (with any arguments) in any g8r pane, the shell g8r opens on included; g8r wires it up. Shims first on the pane's `PATH` start the real program with g8r's hooks (`--settings`) or Codex's `notify` (`-c`), so the session shows up in the event feed ("claude started in shell 1") and the log. Build uses the agent you last started this way; until you start one, Build is off.
- **Plan skill.** Agents started in g8r know how to write plans g8r reads: Claude Code gets the `g8r-plan` skill as a session plugin, and Codex is pointed at the same file.
- **Event log.** Claude Code's hooks report each session's edits, shell commands and stops to `.g8r/events.jsonl`; Codex's `notify` reports each finished turn. They only observe; nothing blocks a tool call.
- **Libraries, not yet wired into the app:** the tree-sitter symbol engine (TypeScript, TSX, JavaScript), the language-server reference engine, and dependency-ordered integration into `g8r/integration` with a test run after each merge.

## Requirements

- macOS on Apple Silicon, Xcode / Swift 6
- [Zig](https://ziglang.org) 0.16 (builds libghostty-vt)
- An agent: [Claude Code](https://code.claude.com) or OpenAI's [Codex CLI](https://github.com/openai/codex). Type `claude` or `codex` in g8r's shell; g8r wires it up
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

g8r opens any folder. Inside a git repository it opens the repository's root; outside one, the nearest folder above it (below your home folder) with a `PLAN.md`, `plans/`, `docs/plans/` or `g8r.json`; otherwise the folder as it is, with the map, shell and event log working and history and builds off until `git init`.

The map follows you. `cd` into another project in the shell you're typing in, or click into a shell that is in one, and within a second the map, the window title, Build, Run tests and the event log switch to that project. `cd` within a project changes nothing, and delegate and build panes never move it. Build sessions already running carry on in the project they started in. ⌘T opens a new shell in the folder the current shell is in. Building from the map needs a commit to branch from: in a repository with none, or a folder with no git, g8r offers to initialize git (if needed) and commit only the plan docs and `g8r.json`.

```sh
cd path/to/your-folder
swift run --package-path path/to/g8r G8r
```

| Shortcut | |
|---|---|
| ⌘⇧D | New delegate (asks for a name) |
| ⌘T | New shell, in the current shell's folder |
| ⌘W | Close the focused pane |
| ⌘1–⌘9 | Focus tabs, then delegate boxes |
| ⌘C / ⌘V | Copy selection / paste |

Delegate boxes collapse from their title bar. **G8r → Auto-trust Delegate Worktrees** (off by default) marks worktrees g8r creates as trusted in Claude Code, only if you already trust the repo, so new sessions skip the trust prompt. Codex needs nothing: it already trusts a worktree of a repo you trust.

### Per-repo config

`<repo>/.g8r/config.json`:

```json
{ "test_command": "npm test", "agent": "codex" }
```

`test_command` is used by the integrator after each merge; `G8R_TEST_COMMAND` overrides it. `agent` is optional: `claude` (the default) or `codex`, the agent g8r starts on its own to read free-form plans (and for New Delegate before you have started one). It doesn't choose the build agent, which is whichever you last started in a pane. `G8R_AGENT` overrides it. `g8r.json` at the repo root takes the same keys and is tracked; `.g8r/config.json` overrides it.

## What g8r writes

In the project root, the folder you open and each one the map follows you to (excluded via `.git/info/exclude` in a git repository, so `git status` stays clean):

| Path | |
|---|---|
| `.g8r/events.jsonl` | the event log |

Hooks are passed to each Claude Code session with `--settings`; hooks an older g8r wrote to a worktree's `.claude/settings.local.json` are taken out when a session opens there.

Next to it: `../<repo>-<name>` worktrees. In your home folder: `~/.g8r/` (event socket, tools, and `~/.g8r/shims/`: the `claude` and `codex` shims, a zsh startup file that keeps them first on `PATH`, and the plan skill) and, only with auto-trust on, trust entries in `~/.claude.json`. `~/.claude` and `~/.codex` are never written: Codex's `notify` and instructions are passed per launch with `-c`. Passing `-c developer_instructions` replaces any your Codex config sets, for that session.

## Repository layout

| Path | |
|---|---|
| `Sources/G8rCore` | event log and bus, hooks, worktrees, integration, language-server client, path globs. No UI, Linux-buildable |
| `Sources/G8rSymbols` | tree-sitter symbol engine, diffs, reference engine |
| `Sources/G8rTerminal` | libghostty-vt terminal core, PTY, sessions |
| `Sources/G8rPTY` | forkpty/exec in C |
| `Sources/g8r-hook` | the hook CLI: Claude Code's hooks, Codex's notify, and the agent shims |
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
| `G8R_AGENT` | `claude` or `codex`; overrides `agent` in `g8r.json` and `.g8r/config.json` (plan reading and New Delegate, not Build) |
| `G8R_AGENT_COMMAND` | run something other than `claude` / `codex` in session panes; a program named `claude` or `codex` still gets that agent's flags |
| `G8R_COLLECTOR` | event socket path (default `~/.g8r/g8r.sock`) |
| `G8R_TSC` | explicit TypeScript 7 binary |
| `G8R_SNAPSHOT=<png>` | render the window to a PNG after 2 s |
| `G8R_DEBUG_DELEGATES=a,b` | open delegates at launch |
| `G8R_DEBUG_COLLAPSED` / `G8R_DEBUG_TOGGLE` | collapse / round-trip delegate boxes |

## Limitations

- The map is a prototype: it scans Swift with regular expressions and is not yet part of the app.
- The symbol and reference engines cover TypeScript, TSX and JavaScript.
- Apple Silicon build of libghostty-vt only (`scripts/build-ghostty.sh`).
