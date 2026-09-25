# Gater — Full Scope Spec (v1)

> A macOS terminal emulator (Swift + libghostty-vt) that makes multi-agent Claude Code work **visible, traceable, and conflict-aware**, while leaving Claude Code's own behavior as close to stock as possible.

Status: spec locked from design session, 2026-09-25. Target: build everything below as V1. The UI can be plain; it can be restyled later.

---

## 1. Problem

Today's multi-feature agentic workflow is: one worktree per agent, one agent per feature, and a human who merges by hand. Coordination lives in the human's head.

- **Native tools resolve conflicts at merge time only.** Claude Code Projects has a "Resolve conflicts" button on each PR. VS Code 1.136 has Agent Merge. Neither catches conflicts **while agents are still working**.
- **Semantic conflicts are invisible.** Agent A changes `getUser()`'s signature. Agent B writes new calls to the old signature in another file. Git merges both cleanly, and the result is broken.
- **You can't easily see what the orchestrator told each sub-agent.** There's no combined view of who is doing what, why, and where.

**Gater's value is the visibility, ontology, and conflict layer, not the delegation itself.**

---

## 2. Design principles (non-negotiable)

1. **Stock Claude Code.** Gater never changes *when* or *whether* Claude delegates, plans, or codes. It only adds:
   - a skill covering **how** to format a delegation once Claude has chosen to delegate,
   - hooks, for observation and format enforcement,
   - a delegate closing-note convention.
2. **Delegation is optional.** If the orchestrator never delegates, Gater is just a terminal running Claude. Gater stays **dormant until the first delegation**.
3. **Commands trickle down.** Human → orchestrator → delegates. The orchestrator answers only to the human. Delegates don't push back up, but they do report completion status.
4. **Adaptive conflict resolution, not upfront guards.** No up-front locks, which would leave delegates idle. The orchestrator watches, and Gater raises overlap events. The orchestrator then sends corrective instructions down. A conflict is a loop iteration to renegotiate, not a failure.
5. **The orchestrator is the continuity layer and head chef.** It holds the vision, keeps delegates consistent (catches hallucinations and context breaks), and **finishes dishes** at the pass. It does not do bulk implementation. Delegates build.
6. **Ground truth over self-report.** Agent location, touched files, and changed symbols come from hooks and parsing, never from agents announcing their status.
7. **Plans are amorphous.** There is no upfront plan document. The plan is derived from delegation events and versioned over time.
8. **Deterministic where possible, AI where judgment is needed.** Tree-sitter and LSP provide facts. Jev handles only the judgment calls.

---

## 3. Architecture overview

```
┌──────────────────────────────── Gater.app (Swift, macOS) ────────────────────────────────┐
│                                                                                           │
│  Terminal panes (libghostty-vt)          Map UI (tree / web / file-highlight views)       │
│   ├─ Orchestrator pane (claude)            ▲                                              │
│   ├─ Delegate pane A (claude, worktree A)  │                                              │
│   └─ Delegate pane B (claude, worktree B)  │                                              │
│            │ pty I/O                        │                                              │
│            ▼                                │                                              │
│  ┌──────────────────────── GaterCore (Swift package, Linux-testable) ─────────────────┐  │
│  │ Event Bus (Unix socket) ← hook events                                               │  │
│  │ Event Log (append-only JSONL)                                                       │  │
│  │ Plan Store (derived from delegation events → plan.json, versioned)                  │  │
│  │ Symbol Engine (tree-sitter: symbols, ranges, public-surface diffs)                  │  │
│  │ Ownership Classifier (Jev: symbol → feature)                                        │  │
│  │ Reference Engine (LSP per active worktree: who uses symbol X)                       │  │
│  │ Overlap Detector (triggers → overlap events → orchestrator wake)                    │  │
│  │ Lifecycle Tracker (cooking → pass → finished → served)                              │  │
│  └─────────────────────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────────────────┘
          ▲                                  ▲                             ▲
   Claude Code hooks                  typescript-language-server       Jev API (HTTP)
   (gater-hook CLI → socket)          (one per active worktree)
```

---

## 4. Components

### 4.1 Terminal (Swift + libghostty-vt)

**libghostty-vt provides:** VT parsing, terminal state (grid, cursor, styles, scrollback, reflow), and a renderer-state API describing *what* to draw.

**Gater implements:**

1. **PTY management.** Call `forkpty()` and spawn `claude` (or `$SHELL`) with the pane's cwd set to its worktree. Read the master fd on a background queue and write keystrokes to it.
2. **Feed loop.** Read pty bytes → feed libghostty-vt → mark the pane dirty.
3. **Rendering.** A custom `NSView` per pane. Each frame, read renderer state and draw the cells with CoreText (glyphs, fg/bg color, bold/italic, cursor). Metal can come later.
4. **Input.** Map `NSEvent` key events to terminal input bytes. Use libghostty's key encoder if it's exposed; otherwise write a basic encoder covering printable keys, arrows, ctrl combos, enter, backspace and tab. Also handle paste.
5. **Resize.** Recompute cols/rows from the font's cell size, tell libghostty, and send `TIOCSWINSZ` to the pty.
6. **Layout.** A split view: left side holds the terminal panes (tabbed or stacked), right side holds the map. Keep it simple.
7. **Input injection API.** `pane.inject(text:)` writes text into a pane's pty as if typed. This is how Gater wakes the orchestrator (see 4.8).

**Reference:** `ghostty-org/ghostling` is a minimal libghostty terminal in one C file with Raylib. Port its loop to Swift/AppKit.

**Build:** compile libghostty-vt with Zig (the version Ghostling pins, currently 0.16.x) into a static lib plus headers. Expose it to Swift through a module map (`module GhosttyVT { header "ghostty/vt.h"; link "ghostty-vt" }`).

**Pane types:**

- `orchestrator`: exactly one per session.
- `delegate`: one per worktree. Gater has a "New delegate" action that creates the worktree (`git worktree add ../<repo>-<name> -b gater/<name>`) and launches `claude` in it.
- `shell`: plain shell, not tracked.

### 4.2 Event bus + hook bridge

- Gater listens on a Unix socket at `~/.gater/gater.sock`.
- `gater-hook` is a tiny CLI (Swift or shell + `nc -U`). It reads the hook's JSON from stdin, adds `pane_id` (from env `GATER_PANE_ID`, which Gater sets when it spawns each pane), and forwards it to the socket.
- Gater also sets `GATER_ROLE=orchestrator|delegate` and `GATER_WORKTREE=<path>` in each pane's environment.

**Hooks installed** (project `.claude/settings.json`, or user settings scoped by env):

| Hook | Matcher | Purpose |
|---|---|---|
| `PreToolUse` | cross-session send-message tool | **Format enforcement.** If the `GATER/1` block is missing or invalid, exit code 2 with the expected format on stderr, so Claude sees it and retries. |
| `PostToolUse` | cross-session send-message tool | Log the delegation event. |
| `PostToolUse` | `Edit\|Write\|MultiEdit` | Log file edits (path, pane) and trigger the symbol engine. |
| `PostToolUse` | `Bash` | Optional: log commands (tests, builds) for "what the delegate is doing now." |
| `Stop` | — | Log that the agent went idle and capture its last message (for the closing note). |

> ⚠️ **Verify first (Phase 2):** the exact tool name of Claude Code's cross-session messaging tool, whether hooks fire on it, and whether cloud sessions can receive and send. At time of writing, a session can list and message other local sessions and your cloud sessions, but cloud sessions can't message back.

### 4.3 Delegation protocol (format only, never decisions)

**Skill: `gater-delegate`.**

- **Description (the trigger):** "Use when sending work to another Claude session." It loads only after Claude has already decided to delegate.
- **Body:** the message format, the message types, and the finishing step. Nothing about *when* to delegate.

**Message format.** This block leads every cross-session message from the orchestrator:

```
GATER/1
type: delegate | rescope | cancel | merge | instruct | finish
id: <dish id, e.g. d-007>          # new for delegate, existing otherwise
feature: <feature name>             # e.g. "Auth"
directive: <one line: what is being asked>
scope: <comma-separated paths/globs or symbols the orchestrator expects to be touched>
merge_into: <dish id>               # only for type=merge
---
<free-form instructions to the delegate>
```

- `delegate`: creates a dish and a feature node (if the feature is new).
- `rescope`: changes a dish's scope or directive.
- `cancel`: kills a dish.
- `merge`: combines two dishes or features.
- `instruct`: an adaptive correction (the main output of conflict handling).
- `finish`: the orchestrator marks the dish as taken to the pass for finishing.

**Delegate closing-note convention.** This is also in the skill: the orchestrator includes it in every delegation's instructions, so delegates need nothing preinstalled. At the end of each unit of work, the delegate replies:

```
GATER-DONE d-007
did: <what was done>
assumed: <assumptions made — this is where context breaks surface>
touched: <optional; Gater verifies against actual edits anyway>
```

**Git trailers for traceback.** A `prepare-commit-msg` git hook in each worktree appends:

```
Gater-Dish: d-007
Gater-Feature: Auth
Gater-Agent: <pane id>
```

This keeps accountability in git itself, where it survives outside Gater.

### 4.4 Event log

Append-only JSONL at `<repo>/.gater/events.jsonl`. It is the single source of truth, and every view is derived from it.

```json
{"ts":"...","kind":"delegation","pane":"orch","to":"pane-A","gater":{"type":"delegate","id":"d-007","feature":"Auth","directive":"...","scope":["src/auth/**"]},"raw":"..."}
{"ts":"...","kind":"edit","pane":"pane-A","path":"src/auth/session.ts","tool":"Edit"}
{"ts":"...","kind":"symbols_changed","pane":"pane-A","path":"...","changes":[{"symbol":"getUser","change":"signature"}]}
{"ts":"...","kind":"ownership","symbol":"src/users.ts#getUser","feature":"Auth","confidence":0.93}
{"ts":"...","kind":"overlap","node":"Auth","panes":["pane-A","pane-B"],"symbol":"...","refs":["src/dashboard.ts:42"]}
{"ts":"...","kind":"review","overlap_id":"...","verdict":"conflict","confidence":0.88}
{"ts":"...","kind":"lifecycle","dish":"d-007","state":"pass"}
{"ts":"...","kind":"done_note","dish":"d-007","did":"...","assumed":"..."}
{"ts":"...","kind":"human_intervention","pane":"pane-B","text":"..."}
```

Anything a human types into a delegate pane is captured by the terminal's input path and logged as `human_intervention`, so traceback has no gaps.

### 4.5 Plan store (the amorphous plan)

- `<repo>/.gater/plan.json` is **written only by Gater** and derived by replaying delegation events. Claude never writes it.
- Contents: the feature list, dishes (id, feature, directive, scope, assigned pane, lifecycle state), and plan version.
- **Versioned:** every change is a log event, so you can scrub the timeline to see how the plan evolved and *why* (from the directive text).
- **Human edits** (for example, dragging a scope boundary on the map) become a message **to the orchestrator only**, injected into its pane. They never go directly to delegates.
- The feature list is the **option set for Jev**, always with `unassigned` appended.

### 4.6 Symbol engine (tree-sitter)

- It parses files with tree-sitter. V1 supports TypeScript/TSX; the architecture is language-agnostic.
- Per-language "what is a symbol" queries go in `tags.scm`. Reuse the ones Neovim and Helix ship.
- **Output per file:** symbols with `{name, kind, range, isExported, signatureHash, bodyHash}`.
- **On each edit event:** re-parse, then diff against the previous snapshot, classifying each change as:
  - `added` / `removed`
  - `signature` (params, return type or export changed): **public surface**
  - `body` (internals only): **not public surface**
- **Ownership is stored per symbol, never per line number.** Ranges are recomputed on demand, so they don't drift as agents edit.
- Snapshots are kept per worktree.

**Swift:** SwiftTreeSitter plus the tree-sitter-typescript grammar.

### 4.7 Ownership classifier (Jev)

**Jev (TypeSafe AI)** returns typed, calibrated decisions in about 70–500ms, parallel questions add little latency, and input costs about $0.04 per 1M tokens. You have API access.

**Job:** decide which feature each symbol **implements**. This is judgment, so Jev handles it.

- **Question type:** `Choice`. Options = the plan's features + `unassigned` (Choice allows up to 255 options).
- **State given to Jev per symbol:**
  - the feature list with each feature's directive text
  - the symbol's name, kind, file path and code snippet
  - optionally, neighboring symbols' current owners
- **Batching:** send all changed or unclassified symbols as parallel questions in one call.
- **Confidence handling:**
  - ≥ threshold (0.88): assign.
  - < threshold and **not** involved in an overlap: mark **uncertain** (dashed on the map). It gets re-classified naturally as work continues.
  - < threshold **and** involved in an overlap: include it in the orchestrator review.
- **Re-sweep** affected symbols when features are merged or renamed, or when a symbol's body changes substantially.

**Not Jev's job:** "which features does this code *use*." That's deterministic and comes from LSP (4.8).

> ⚠️ **Verify first (Phase 5):** Jev's request/response schema, context limit (diff and snippet size), and accuracy on a real `getUser()` conflict case.

### 4.8 Reference engine (LSP)

- One `typescript-language-server --stdio` **per active worktree**, spawned via `Process` with pipes and speaking JSON-RPC (Content-Length framing).
- **Lifecycle is tied to the dish:** start when a delegation begins in that worktree, stop when the dish is **served** (merged). It's kept alive while idle because B's existing code still matters even when B isn't typing.
- **Query on demand:** servers block on stdin between requests, so they use no CPU. They're only queried when *another* agent changes a public symbol.
- **Keep indexes fresh:** send `didOpen` and `didChange` (or `workspace/didChangeWatchedFiles`) when a delegate edits in its worktree.
- **Query:** `textDocument/references` at the changed symbol's position, **in the other delegate's worktree copy** of that file.
- **Usage edges:** if symbol S (owned by feature X) references symbol T (owned by feature Y), then X *uses* Y. These edges drive the web view.
- **Optional:** hibernate idle servers under memory pressure (accept the cold-start delay).
- **Fallback when no LSP is available:** import-graph or text-search overlap (less precise).

### 4.9 Overlap detector

**Occupancy:** an agent is "on" a feature node when it edits symbols owned by that feature. This is derived from edits, symbols and ownership, never self-reported.

**Triggers (no debounce needed):**

1. **Delegation change** (`delegate`, `rescope`, `merge`, `cancel`, or an agent's edits moving into a different feature): full sweep of the affected nodes.
2. **Public-surface edit** (tree-sitter reports a `signature`, `added`, `removed` or export change): targeted sweep for that symbol.
3. Body-only edits inside the agent's own feature trigger **nothing**.

**Overlap conditions:**

- Two or more agents occupy the same feature node, **or**
- Agent A changes the public surface of a symbol owned by feature X, and LSP finds references to it in code that agent B has written or changed (or code in B's active scope).

**On overlap:**

1. Flag the node on the map.
2. Run a **Jev review sweep** on the involved changes. Question: "Do these changes conflict?" (yes/no plus confidence). The state includes both directives, the changed symbols, diff snippets and reference sites.
3. If the answer is yes, or confidence is low, **wake the orchestrator** by injecting a structured message into its pane:

```
[GATER] overlap on Auth
A (d-007 "add session expiry") changed getUser(): signature (id) -> (id, opts)
B (d-009 "dashboard user card") calls getUser at src/dashboard.ts:42 (old signature)
Jev: conflict=yes (0.88)
Uncertain ownership involved: src/users.ts#normalizeUser (0.61)
```

4. The orchestrator decides and sends `GATER/1 type: instruct` (or `rescope`) down to the right delegate or delegates.

**Timing tradeoff (accepted):** by the time the orchestrator reacts, a delegate may have already written conflicting code. Adaptive means "correct course early," not "prevent."

### 4.10 Lifecycle (the kitchen)

The states of each dish:

```
cooking  → delegate is working
pass     → delegate posted GATER-DONE; waiting for the orchestrator
finished → orchestrator finished/patched it (type: finish)
served   → merged
```

- The orchestrator **only edits code that is at the pass**, so it never touches code an active delegate is working on. That keeps its context clean.
- The orchestrator's own edits are also tracked by hooks and included in overlap detection.
- On `pass`, Gater gives the orchestrator the dish's **diff** plus the **done note**, so it can check them against the vision and catch hallucinations and context breaks.

**Finishing cadence: incremental integration on one branch, gated by dependencies.**

(Merge-sort stitching was considered and rejected. It assumes a fixed set of dishes, but plans change mid-flight. It forces pairs when dependencies are actually hubs, makes pairs wait on each other, and re-reviews the same code at every level.)

1. There is one long-lived branch, `gater/integration`.
2. When a dish reaches the pass, Gater checks whether it references the changed **public surface** of any dish that is **not yet merged**:
   - **No:** it merges now. Arrival order is fine.
   - **Yes:** it's held until that dependency merges, then rebased and merged. The map shows it as "waiting on d-00X."
3. **Cycles** (two dishes each using the other's changed symbols) are merged together as one unit. This is the only case where stitching two dishes at once is needed.
4. After each merge, the orchestrator reviews **only that dish's delta**, but against the fully integrated code, and patches it if needed (head chef finishing). Each dish is reviewed once, and every review sees the real current state.
5. **Tests run on `gater/integration` after every merge.** If they fail, the most recently merged dish caused it, so attribution comes for free.
6. Small orders use the same process. There's no special case.
7. A dish is **served** once it's merged into `gater/integration`. Its worktree's LSP stops at that point. Merging the integration branch into main is the human's call.

### 4.11 Map UI

**One data model, switchable views:**

- **Tree view (default):** orchestrator → features → dishes/agents. It mirrors the trickle-down command flow.
- **Web view:** feature nodes plus "uses" edges from LSP. This is where conflicts live.
- In tree view, a **flagged node** shows its dependency edges overlaid.
- **Timeline (later):** scrub through plan versions.

**Node card:**

- **Header:** feature name + status (cooking / pass / finished / served)
- **Directive statement:** what the orchestrator asked, and what the delegate is doing now (last tool action)
- **Agents on it**
- **Dropdown:** files → symbols (owned by this feature)
- **Flags:** overlap ⚠, uncertain classifications (dashed)

**File highlight view** (click a file under a node):

- **Solid highlight:** lines owned by this feature
- **Faint or underline:** lines that *use* another feature
- **Red:** lines in an active overlap
- Ranges are recomputed from tree-sitter at open time.

---

## 5. Repo layout

```
gater/
├─ Package.swift                 # GaterCore (library), gater-hook (executable)
├─ Sources/
│  ├─ GaterCore/                 # builds + tests on Linux AND macOS
│  │  ├─ EventBus/               # Unix socket server, event decoding
│  │  ├─ EventLog/               # JSONL append/replay
│  │  ├─ Protocol/               # GATER/1 parser/validator, GATER-DONE parser
│  │  ├─ Plan/                   # plan derivation + versioning
│  │  ├─ Symbols/                # tree-sitter wrapper, symbol diff
│  │  ├─ Ownership/              # Jev client + classifier
│  │  ├─ References/             # LSP client, per-worktree server manager
│  │  ├─ Overlap/                # triggers, detector, review, wake messages
│  │  └─ Lifecycle/
│  └─ gater-hook/                # hook CLI → socket; also PreToolUse format check
├─ Tests/GaterCoreTests/
├─ App/                          # Xcode project: macOS app
│  ├─ Terminal/                  # PTY, libghostty bridge, TerminalView (NSView)
│  ├─ Panes/                     # pane manager, worktree creation, env injection
│  ├─ Map/                       # tree view, web view, node card, file view
│  └─ GaterApp.swift
├─ Vendor/ghostty/               # libghostty-vt build output + headers + module.modulemap
├─ claude/
│  ├─ skills/gater-delegate/SKILL.md
│  ├─ settings.hooks.json        # hook config template
│  └─ git-hooks/prepare-commit-msg
└─ .gater/                       # runtime (per target repo): events.jsonl, plan.json, snapshots/
```

**Build split:** everything in `GaterCore` and `gater-hook` can be compiled and tested in a Linux sandbox. The `App/` target (AppKit, libghostty rendering) must be built in Xcode on the Mac.

---

## 6. Build phases & acceptance criteria

| # | Phase | Done when |
|---|---|---|
| 0 | **Setup** | Repo scaffolded; libghostty-vt builds with Zig; Swift can call one libghostty function. |
| 1 | **Terminal** | Single pane runs `zsh` and `claude` correctly (colors, cursor, resize, paste, ctrl keys). Then multiple panes, "new delegate" creates a worktree plus pane, and `inject(text:)` works. |
| 2 | **Event bus + hooks** | `gater-hook` forwards `PostToolUse` Edit/Write events from every pane into `events.jsonl` with the right `pane_id`. Cross-session tool name and hook behavior verified. |
| 3 | **Delegation protocol** | Skill loads only on delegation. The `PreToolUse` hook blocks malformed messages and Claude retries in the right format. Delegation events are logged. `plan.json` is derived and versioned. Git trailers are appended. |
| 4 | **Symbol engine** | TS symbols extracted with ranges. Edits produce correct `signature` vs `body` classification (unit tests). |
| 5 | **Jev ownership** | Symbols classified against the plan's feature list plus `unassigned`. Threshold logic works. Context limit measured. |
| 6 | **LSP references** | One tsserver per active worktree. `references` for a changed symbol is queried in another worktree and returns correct sites. Lifecycle start/stop tied to dishes. |
| 7 | **Overlap + wake** | The `getUser()` scenario end to end: A changes the signature, B's call site is found, Jev review runs, the orchestrator pane receives the `[GATER]` message, and the orchestrator sends `instruct`. |
| 8 | **Map UI** | Tree view with node cards is live from the log. Web view toggle. Flag overlays. File highlight view. |
| 9 | **Lifecycle + finishing** | GATER-DONE moves a dish to `pass`; the orchestrator receives the diff plus the note; `finish` and `served` (on merge) states work; LSP stops on served. |

**Golden end-to-end test** (use it for every phase from 7 on):

1. The orchestrator delegates "Auth: add session expiry" to A and "Dashboard: user card" to B.
2. A changes `getUser(id)` to `getUser(id, opts)`.
3. B calls `getUser(id)` in `dashboard.ts`.
4. Expected: overlap flagged on Auth/Dashboard → Jev says conflict → orchestrator woken → orchestrator instructs B (or A) → map shows the edge and the red lines.

---

## 7. Risks

- **Terminal scope creep.** Get "correct enough to run `claude`" first. Styling comes later.
- **Cross-session messaging limits.** It's one-way to cloud sessions, and hooks on that tool aren't verified yet. Fallback: Gater routes delegations itself by injecting into delegate panes.
- **Jev accuracy on code.** Benchmarks are vendor-run. Measure on real repos, and keep the threshold tunable.
- **LSP memory.** Each tsserver instance takes hundreds of MB on big repos. Hibernation is the escape hatch.
- **Orchestrator context bloat.** Keep wake messages terse and structured, and only wake it for overlaps.
- **Ownership churn.** Symbols can flip between features across re-sweeps. Consider requiring a confidence margin before reassigning.

---

## 8. Open decisions

1. **Finishing cadence (DECIDED):** incremental integration on one branch, gated by dependencies, with tests after every merge (see §4.10).
2. **Jev threshold (DECIDED):** 0.88 to start, then tune.
3. **Human typing into a delegate pane mid-task (DECIDED):** log it as a `human_intervention` event so traceback has no gaps.
4. **Delegates in cloud sessions (DECIDED):** V1 is local panes only; cloud delegates come in V2 once two-way messaging exists.

---

## 9. Deferred (V2+)

- **Platform-agnostic harness (the long-term direction).** Package the skill and hooks as a Claude Code plugin committed to the repo, so it runs in CLI, desktop and cloud sessions. Hooks post to an **HTTP collector** instead of the local socket. The terminal becomes one optional frontend. Expose the protocol over MCP for Codex. Cloud delegates are analyzed from pushed branches, since their sandboxes can't be reached.
  - **V1 constraint so this stays cheap later:** keep the event bus's transport behind an interface (`EventTransport`), with the Unix socket as the first implementation and HTTP added later. `gater-hook` should read the collector address from the env var `GATER_COLLECTOR`.

- Metal renderer, theming, polished UI
- Timeline scrubber
- Languages beyond TypeScript (config only: grammar, `tags.scm`, LSP command)
- Dragging plan edits in the UI (routed to the orchestrator)
- Cloud-session delegates
- Component-level grouping on the map
