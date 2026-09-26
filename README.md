# Gater

A macOS terminal for running several Claude Code sessions on one codebase at once — one **orchestrator** that plans, and **delegates** that each build a piece in their own git worktree — while Gater watches the work, catches the places where agents step on each other, and wakes the orchestrator to correct course.

Gater never decides *what* to delegate. The orchestrator (Claude) makes every decision; Gater makes the work visible, traceable, and conflict-aware, and handles the mechanics (worktrees, sessions, merges).

```
┌──────────────────────┬──────────────────┬───────────────────┐
│ orchestrator  shell  │ delegate: auth   │  Tree  Web  Events│
│                      │  (claude)        │ ┌ Auth ─── pass ┐ │
│  claude              ├──────────────────┤ │ ⚠ getUser …   │ │
│  (plans, delegates,  │ delegate: dash   │ │ d-001 · …     │ │
│   finishes)          │  (claude)        │ └───────────────┘ │
└──────────────────────┴──────────────────┴───────────────────┘
```

## What it does

- **Terminal.** A native AppKit terminal built on [libghostty-vt](https://github.com/ghostty-org/ghostty) (VT parsing, rendering state, key/mouse/paste encoding), with CoreText rendering, selection and copy, scrollback, and mouse reporting. Delegates appear as collapsible boxes beside the orchestrator.
- **Delegation protocol.** The orchestrator hands out work with Claude Code's `SendMessage` tool, leading each message with a small `GATER/1` block (type, dish id, feature, directive, scope). A hook validates the block — and the ids against the plan — and blocks malformed messages with the expected format so Claude retries. Delegates report back with a `GATER-DONE` note (`did` / `assumed` / `touched`).
- **Auto-spawned delegates.** Sending `type: delegate` to a `delegate-<name>` that doesn't exist yet makes Gater create the worktree (`../<repo>-<name>` on branch `gater/<name>`), open a pane running `claude --name delegate-<name>`, and deliver the message once the session is ready.
- **Plan.** Every event goes to an append-only log (`.gater/events.jsonl`); `.gater/plan.json` — features, dishes, states, history — is derived from it and rebuilt on every launch.
- **Symbols.** Every edit (Edit/Write tools *and* shell commands, via git) is re-parsed with tree-sitter (TypeScript/TSX/JS). Changes are classified as `added` / `removed` / `signature` / `body`; signature changes to exported symbols are **public surface**.
- **Ownership.** [Jev](https://typesafe.ai) (TypeSafe AI) classifies which feature each symbol implements; below 0.88 confidence it's marked uncertain.
- **References.** One TypeScript 7 language server (`tsc --lsp`, native — no node) per worktree answers "who uses this symbol in the other agents' code?".
- **Overlap detection.** When one agent changes the public surface of code another agent uses (in either order), or two agents edit the same feature, Gater flags it, checks the call sites' arity with the parser, asks Jev whether it's a real conflict, and — if yes or unsure — types a `[GATER] overlap on …` message into the orchestrator, which answers with an `instruct`.
- **Finishing (the kitchen).** Dishes move `cooking → pass → finished → served`. On `pass` the orchestrator gets the diff + note; on `finish` Gater merges into `gater/integration` (its own worktree) in dependency order — holding dishes that use unmerged work, merging cycles together — runs your tests after each merge, and on `served` closes the delegate and removes its worktree (branch kept). Merging `gater/integration` into `main` stays your call.
- **Map.** A live tree of features → dishes → agents (status, directives, what each agent is doing now, overlap flags, owned files and symbols), a web view of "uses" edges, and a file view highlighting owned lines and overlapping call sites.
- **Accountability.** Commits made in Gater panes get `Gater-Dish`, `Gater-Feature` and `Gater-Agent` trailers.

## Requirements

- macOS on Apple Silicon, Xcode / Swift 6
- [Zig](https://ziglang.org) 0.16 (builds libghostty-vt)
- [Bun](https://bun.sh) (installs TypeScript 7 for the language servers)
- [Claude Code](https://code.claude.com) 2.1.224 or later (cross-session messaging)
- Optional: a [Jev](https://typesafe.ai) API key for ownership and conflict review

## Setup

```sh
git clone --recurse-submodules https://github.com/kap-il/gater.git
cd gater
scripts/build-ghostty.sh          # builds Vendor/ghostty/GhosttyVT.xcframework
swift build

# TypeScript 7 for the language servers, kept out of your home folder:
mkdir -p ~/.gater/tools && cd ~/.gater/tools
[ -f package.json ] || echo '{"name":"gater-tools","private":true}' > package.json
bun add typescript@^7
```

Secrets and settings live in `~/.gater/.env` (never in a repo; real environment variables override it):

```sh
JEV_API_KEY=...
# JEV_BASE_URL=https://api.typesafe.ai
# JEV_MODEL=jev-latest
```

Without a Jev key, everything works except ownership and conflict review; overlaps still wake the orchestrator.

## Running

Gater works on a git repository with at least one commit:

```sh
cd path/to/your-repo
swift run --package-path path/to/gater Gater
```

The orchestrator pane starts `claude` in the repo. Tell it it's the orchestrator and that it should split work into delegates — for example: *"You're the orchestrator. Split this into parallel workstreams and delegate each to its own delegate session (open them yourself, named after their work)…"*.

| Shortcut | |
|---|---|
| ⌘⇧D | New delegate (asks for a name) |
| ⌘T | New shell |
| ⌘W | Close the focused pane |
| ⌘⇧I | Inject text into the orchestrator |
| ⌘1–⌘9 | Focus tabs, then delegate boxes |
| ⌘C / ⌘V | Copy selection / paste |

Delegate boxes collapse from their title bar (▾ or double-click). **Gater → Auto-trust Delegate Worktrees** (off by default) marks Gater-created worktrees as trusted in Claude Code, only if you already trust the repo, so new delegates skip the trust prompt.

### Per-repo config

`<repo>/.gater/config.json`:

```json
{ "test_command": "npm test" }
```

Run after every merge into `gater/integration`; a failure points at the dish just merged. `GATER_TEST_COMMAND` overrides it.

## What Gater writes

In your repository (all excluded via `.git/info/exclude`, so `git status` stays clean):

| Path | |
|---|---|
| `.gater/events.jsonl` | the event log — the single source of truth |
| `.gater/plan.json` | the plan, derived from the log |
| `.gater/snapshots/` | per-worktree symbol snapshots |
| `.claude/settings.local.json` | Gater's hooks (merged with yours), in each agent worktree |
| `.claude/skills/gater-delegate/` | the delegation-format skill, for the orchestrator |
| `.git/hooks/prepare-commit-msg` | commit trailers (never replaces an existing hook) |

Next to it: `../<repo>-<name>` delegate worktrees (removed once served) and `../<repo>-integration`.

In your home folder: `~/.gater/` (event socket, `.env`, tools) and — only with auto-trust on — trust entries in `~/.claude.json`.

## How a delegate session gets created

The orchestrator calls `SendMessage(to: "delegate-billing", …)` with a `GATER/1 type: delegate` block. Claude Code runs Gater's `PreToolUse` hook first; `gater-hook` validates the block and asks the app (over `~/.gater/gater.sock`) to ensure the session exists. The app creates the worktree and branch, installs the hooks there, opens a pane running `claude --name delegate-billing`, and waits until that session's cross-session socket appears. The hook then exits 0 and Claude Code delivers the message. Claude's own subagents and background sessions don't go through Gater and aren't tracked; use delegates for implementation that should be isolated and checked for conflicts.

## Repository layout

| Target | |
|---|---|
| `Sources/GaterCore` | event log and bus, GATER/1 protocol, plan, hooks, worktrees, Jev ownership, LSP client, overlap detection, finishing, map model — no UI, Linux-buildable |
| `Sources/GaterSymbols` | tree-sitter symbol engine, diffs, call arity, reference engine |
| `Sources/GaterTerminal` | libghostty-vt terminal core, PTY, sessions |
| `Sources/GaterPTY` | forkpty/exec in C |
| `Sources/gater-hook` | the Claude Code hook CLI |
| `App/` | the macOS app: terminal view, panes, map |
| `claude/` | canonical skill and git-hook templates (embedded via `scripts/gen-templates.py`) |
| `Vendor/ghostty` | Ghostty submodule (pinned) + build output |

## Development

```sh
swift test
```

The language-server tests need TypeScript 7 in `~/.gater/tools` and skip otherwise.

Useful environment variables for development and headless checks:

| Variable | |
|---|---|
| `GATER_AGENT_COMMAND` | run something other than `claude` in agent panes |
| `GATER_COLLECTOR` | event socket path (default `~/.gater/gater.sock`) |
| `GATER_TSC` | explicit TypeScript 7 binary |
| `GATER_SNAPSHOT=<png>` | render the window to a PNG after 2 s |
| `GATER_DEBUG_DELEGATES=a,b` | open delegates at launch |
| `GATER_DEBUG_COLLAPSED` / `GATER_DEBUG_TOGGLE` | collapse / round-trip delegate boxes |
| `GATER_DEBUG_MAP_TAB`, `GATER_DEBUG_MAP_EXPAND`, `GATER_DEBUG_OPEN_FILE="Feature\|path"` | map snapshots |

## Limitations

- Overlap detection covers TypeScript/TSX/JavaScript.
- Local sessions only: Claude Code cloud sessions can't message back yet.
- Apple Silicon build of libghostty-vt only (`scripts/build-ghostty.sh`).
