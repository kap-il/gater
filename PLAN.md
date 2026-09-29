# g8r: the living map

g8r draws a codebase as a chart of the components its plans describe. Each
node opens its plan, its files and what it depends on. A node that isn't
built yet can be built from the chart, in a fresh agent session of its own.

This file is the plan. g8r reads it: every section whose heading looks like
`id: Name` is a node on the map.

## Why this, when Kiro and Task Master exist

Checked 2026-09-29 against Kiro's docs and Task Master's README.

| | Kiro | Task Master | g8r |
|---|---|---|---|
| Unit | task | task | component |
| Lifetime | until the spec ships | until the PRD ships | as long as the code exists |
| Needs a plan to show anything | yes | yes | no |
| Dependency order | yes, runs tasks in waves | yes, `next_task` | yes |
| Status comes from | the agent marking a task | `set_task_status` | files, symbols and test runs |
| Edges come from | the task list | the task list | the plan and the code, compared |
| Node to files, file to node | no | no | yes |
| Where it runs | inside Kiro | any editor, via MCP | beside stock Claude Code |

They manage the to-do list. g8r keeps the map.

## Principles

1. **The map outlives the plan.** Components persist. A plan is an overlay
   that adds components or changes existing ones.
2. **Measured, not reported.** Status, files and edges come from the code,
   git and test runs. Nothing is a checkbox.
3. **Works on day one.** An existing codebase gets a map before any plan
   exists. Code no plan mentions shows up as unplanned.
4. **Both directions.** A node opens its files and symbols. A file names the
   node it belongs to.
5. **Plan and code must agree.** Where they differ, the difference is drawn.
6. **Stock Claude Code.** Building a node starts a normal session in a
   worktree. g8r composes the prompt and watches the result.
7. **One session per component.** A session starts when a node is built and
   ends when that node's checks pass. The next node gets a fresh session.
   Nothing carries over except the code and the plan.

## How it fits together

```
plan docs ──► plandoc ──► PlanGraph ─┐
                                     ├─► codemap ──► LivingMap ──► stages ──► viewer
code ──► symbol engine ──► FileScan ─┘                 (JSON)      drift      (chart)
git history ──────────────────────────────────────────────────────► timeline      │
test runs ────────────────────────────────────────────────────────► evidence      │
build sessions ◄── clickbuild ◄──────────────── click "Build this" ◄──────────────┘
      │
      └─► worktree ../<repo>-<id> on g8r/<id> ──► checks pass ──► merged into
          g8r/integration ──► pane closed, worktree removed
```

Two roots matter:

- **Plan root:** the repo the user opened. Plan docs and `g8r.json` are read
  from here, including edits that aren't committed yet.
- **Code root:** where the code is measured. It is the integration worktree
  `../<repo>-integration` once that exists, and the plan root until then.
  Built components land on `g8r/integration`, so that is where the map has
  to look. Merging `g8r/integration` into your own branch stays your call.

## Contracts

Everything in this section is shared between components. A component may
add to a contract. It may not change what another component relies on.

### Plan doc format

A plan doc is markdown. A **component section** is a heading of level 2 to 4
whose text is `<id>: <Name>`, where `<id>` matches `[a-z][a-z0-9-]*`. The
section runs to the next heading of the same or a higher level. Headings
inside code fences don't count.

Inside a section, these bullets are read. Keys are case-insensitive, values
are comma-separated, backticks are stripped, and an indented line continues
the bullet above it:

| Bullet | Meaning |
|---|---|
| `- Needs:` | ids this component can't be built without |
| `- Changes:` | ids of existing components it modifies |
| `- Code:` | where its code lives: files, directories ending in `/`, or globs |
| `- Done when:` | prose; shown to people and given to the build session |

The summary is the first sentence of the section's first paragraph.

Under any heading named `Retired`, each sub-heading names a retired
component and its body says why.

Everything else in the doc is prose for people. There is no status field:
status is measured.

A doc with no component sections is free-form. Its components are extracted
by Claude (`claude -p`) into the same shape and cached by the hash of the
doc's text.

### g8r.json

Optional, at the plan root, tracked. `.g8r/config.json` (local, untracked)
overrides it key by key, and environment variables override both.

```json
{
  "plans": ["PLAN.md"],
  "build_command": "swift build",
  "test_command": "swift test",
  "worktree_setup": "ln -sfn \"$G8R_PLAN_ROOT/Vendor/x.xcframework\" Vendor/x.xcframework",
  "ignore": ["Vendor/**", "planmap/**"]
}
```

| Key | Default | Env override |
|---|---|---|
| `plans` | `PLAN.md`, then `plans/*.md`, then `docs/plans/*.md`, whichever exist | |
| `build_command` | none | `G8R_BUILD_COMMAND` |
| `test_command` | none | `G8R_TEST_COMMAND` |
| `worktree_setup` | none; run in each new worktree, with `G8R_PLAN_ROOT` set, to put back what git doesn't carry, such as build output | |
| `ignore` | none; globs of paths the map leaves out | |

### The map

`LivingMap` is the one thing the viewer reads. It is `Codable`, and its JSON
uses exactly these keys. Optional keys are left out when absent.

```json
{
  "repo": "g8r",
  "head": "e7d865b",
  "generated": "2026-09-29T19:46:00Z",
  "docs": [{"path": "PLAN.md", "title": "g8r: the living map"}],
  "nodes": [{
    "id": "codemap",
    "name": "Code map",
    "summary": "Assigns every file and symbol to a component.",
    "status": "planned",
    "doc": "PLAN.md",
    "needs": ["plandoc", "symbols"],
    "changes": [],
    "paths": ["Sources/G8rCore/CodeMap/"],
    "loc": 0,
    "files": [{"path": "a/b.swift", "loc": 120,
               "symbols": [{"kind": "class", "name": "EventLog"}]}],
    "section": {"doc": "PLAN.md", "line": 210, "heading": "codemap: Code map", "text": "…"},
    "doneWhen": "every tracked source file has exactly one owner …",
    "tests": {"files": ["Tests/…"], "count": 9, "passed": 9, "failed": 0},
    "git": {"commits": 3,
            "first": {"sha": "abc1234", "t": 1790000000, "subject": "…"},
            "last":  {"sha": "def5678", "t": 1790000900, "subject": "…"}},
    "wave": 2,
    "blockedBy": ["plandoc"],
    "blast": ["panes"],
    "prompt": "You are building …",
    "building": false,
    "notes": ["Assumed the event log is append-only."]
  }],
  "edges": [{"from": "codemap", "to": "symbols", "declared": true, "measured": false,
             "symbols": ["SymbolExtractor"], "refs": 4,
             "kind": "planned", "implied": false}],
  "retired": [{"name": "Overlap detector", "why": "…", "doc": "PLAN.md", "line": 500}],
  "timeline": [{"sha": "abc1234", "t": 1790000000, "subject": "…", "loc": {"codemap": 120}}],
  "tests": {"ranAt": "2026-09-29T19:46:00Z", "command": "swift test",
            "passed": 99, "failed": 0, "exit": 0},
  "problems": ["codemap needs an unknown component: foo"]
}
```

| Field | Set by | Notes |
|---|---|---|
| `nodes[].status` | codemap, then evidence | codemap sets `planned`, `built` or `unplanned`. evidence turns `built` into `proven`, `unproven` or `failing`. clickbuild sets `building` while a session is open |
| `nodes[].id` for code no plan mentions | codemap | `unplanned:<directory>`, named after the file stems in it |
| `nodes[].files`, `loc`, `tests.files`, `tests.count` | codemap | |
| `nodes[].tests.passed`, `failed`, top-level `tests` | evidence | |
| `nodes[].git`, `timeline` | timeline | |
| `nodes[].wave`, `blockedBy`, `blast` | codemap | planned nodes only. `wave` is 1 for nodes whose needs are all built |
| `nodes[].prompt`, `notes`, `building` | clickbuild | |
| `edges[].declared`, `measured`, `symbols`, `refs` | codemap | an edge runs from the component that needs to the one needed |
| `edges[].kind`, `implied` | drift | the viewer must cope with `kind` missing |

The viewer must render a map that has only the codemap fields. Every later
stage adds detail; none is required to draw the chart.

### Stages

After codemap measures the base map, stages add to it in order.

```swift
public struct MapContext {
    public var planRoot: String
    public var codeRoot: String
    public var config: G8rConfig
    public var graph: PlanGraph
    /// Code-root-relative paths of every file on the map.
    public var files: [String]
    /// What the symbol engine found in each file it understands.
    public var scans: [String: FileScan]
}

public protocol MapStage {
    func apply(to map: inout LivingMap, context: MapContext) throws
}
```

The standard list lives in one place, `Sources/G8rSymbols/StandardMap.swift`.
A component that adds a stage does **not** edit that file. The orchestrator
adds the stage to the list when the component is merged.

### Running commands

Every component starts programs through a `CommandRunner`, so a test can
swap in a stub and never start a process.

```swift
// Sources/G8rCore/Config/ProcessRunner.swift
public enum ProcessRunner {
    /// Runs in `directory` through a login shell, so programs on the user's
    /// PATH are found even when the app was opened from Finder. Output and
    /// errors come back as one string.
    public static func runner(in directory: String, timeout: TimeInterval = 600) -> CommandRunner
}
```

### Events

New kinds in `.g8r/events.jsonl`, beside `pane_opened`, `pane_closed`,
`edit`, `command`, `stop`, `raw` and `human_intervention`:

| Kind | Fields | Written by |
|---|---|---|
| `build_started` | `component`, `pane`, `worktree`, `branch`, `base` | clickbuild |
| `build_checked` | `component`, `passed`, `round`, `tail` | clickbuild |
| `build_merged` | `component`, `commit` | clickbuild |
| `build_needs_human` | `component`, `reason` | clickbuild |
| `tests_ran` | `passed`, `failed`, `exit`, `command` | evidence |

Hook events from a build session carry `component` as well as `pane`.

### Bridge

The chart runs in a `WKWebView`. It also has to work as a plain page in a
browser, where the bridge is missing and clicks fall back to showing text.

| Direction | Message | Meaning |
|---|---|---|
| page → app | `{type: "ready"}` | the page loaded; send the map |
| page → app | `{type: "build", component}` | build this node |
| page → app | `{type: "openFile", component, path}` | show this file |
| page → app | `{type: "runTests"}` | run the tests, then refresh |
| page → app | `{type: "refresh"}` | measure again |
| app → page | `window.g8r.setMap(map)` | draw this map, keeping the selection |
| app → page | `window.g8r.setBusy(text or null)` | show or clear a status line |

Page to app messages go through `window.webkit.messageHandlers.g8r`.

## Built

These exist and work. Their sections say what they are and where they live,
so the map can place their code.

### setup: Build & packaging

The Swift package, the pinned Ghostty submodule, and the script that builds
libghostty-vt with Zig into an xcframework.

- Code: `Package.swift`, `Package.resolved`, `scripts/`, `Vendor/`, `.gitmodules`

### terminal: Terminal

A native terminal on libghostty-vt: PTY, feed loop, CoreText rendering,
selection, scrollback, mouse reporting, and `inject(text:)`.

- Needs: setup
- Code: `Sources/G8rTerminal/`, `Sources/G8rPTY/`, `App/Terminal/`

### worktrees: Worktrees

One git worktree and branch per session: `../<repo>-<name>` on
`g8r/<name>`. Creates, finds, lists and removes them. Never forces a removal
over uncommitted work.

- Code: `Sources/G8rCore/Worktrees/`

### eventlog: Event log

Append-only JSONL at `.g8r/events.jsonl`, plus `JSONValue` and `G8rEvent`,
the vocabulary everything else speaks.

- Code: `Sources/G8rCore/EventLog/`

### eventbus: Event bus

A Unix socket that receives events from hooks and appends them to the log.
Also answers requests.

- Needs: eventlog
- Code: `Sources/G8rCore/EventBus/`

### hooks: Hook bridge

The `g8r-hook` CLI and the installer that writes g8r's hooks into a
worktree's Claude Code settings. Observes edits, commands and stops. Blocks
nothing.

- Needs: eventbus, eventlog, worktrees
- Code: `Sources/g8r-hook/`, `Sources/G8rCore/Hooks/HookProcessor.swift`,
  `Sources/G8rCore/Hooks/HookInstaller.swift`

### trust: Worktree trust

Marks worktrees g8r creates as trusted in Claude Code, only when the repo is
already trusted and the user turned the setting on. Without it every new
session stops at the trust prompt.

- Needs: eventlog
- Code: `Sources/G8rCore/Hooks/ClaudeTrust.swift`

### globs: Path globs

Matches paths against patterns like `src/auth/**`. Plan docs use these to say
where a component's code lives.

- Code: `Sources/G8rCore/Paths/`

### symbols: Symbol engine

tree-sitter symbols per file, with signature and body hashes, and diffs
classified as added, removed, signature or body. TypeScript, TSX and
JavaScript.

- Needs: eventlog, worktrees
- Code: `Sources/G8rSymbols/CodeSymbol.swift`,
  `Sources/G8rSymbols/SymbolExtractor.swift`,
  `Sources/G8rSymbols/SymbolDiff.swift`, `Sources/G8rSymbols/SymbolEngine.swift`

### references: Reference engine

One language server per worktree, asked who uses a symbol. Not used by the
map; kept for precise answers later.

- Needs: symbols, eventlog
- Code: `Sources/G8rCore/References/`, `Sources/G8rSymbols/ReferenceEngine.swift`

### integration: Integration

Dependency-ordered merges into `g8r/integration`, in a worktree of its own,
with a test run after each merge.

- Needs: worktrees
- Code: `Sources/G8rCore/Lifecycle/`

### panes: Panes & layout

Session and shell panes, the window, and the live event feed.

- Needs: terminal, worktrees, hooks, trust, eventlog
- Code: `App/Panes/`

### app: App shell

Picks the repo, opens the log, starts the bus, opens the window.

- Needs: panes, eventbus, eventlog, worktrees
- Code: `App/G8rApp.swift`

## To build

Every component below follows the same rules:

- It comes with tests, and `swift build` and `swift test` pass with it in.
- Logic lives in `G8rCore` or `G8rSymbols`, where it can be tested. Files in
  `App/` stay thin.
- `G8rCore` must not import `G8rSymbols` or AppKit.
- It matches the style of the code around it.

### plandoc: Plan doc reader

Reads plan docs into a plan graph: the components, what each needs, what
each changes, and where its code lives.

Two readers produce the same shape. The parser handles docs written in the
plan doc format and involves no model. The extractor handles free-form docs
by asking Claude, and caches the answer by the hash of the doc's text, so a
doc is only read by a model when it changes.

```swift
// Sources/G8rCore/PlanDoc/
public struct PlanComponent: Codable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var doc: String        // plan-root-relative path of the plan doc
    public var line: Int          // 1-based line of the heading
    public var heading: String
    public var text: String       // the section's body, verbatim
    public var paths: [String]
    public var needs: [String]
    public var changes: [String]
    public var doneWhen: String?
}
public struct RetiredComponent: Codable, Equatable {
    public var name: String
    public var why: String
    public var doc: String
    public var line: Int
}
public struct PlanDocInfo: Codable, Equatable { public var path: String; public var title: String }
public struct PlanGraph: Codable, Equatable {
    public var docs: [PlanDocInfo]
    public var components: [PlanComponent]
    public var retired: [RetiredComponent]
    /// Duplicate ids, needs or changes that name nothing, cycles in needs.
    public var problems: [String]
    public func component(_ id: String) -> PlanComponent?
}

public enum PlanDocParser {
    public static func parse(text: String, doc: String)
        -> (title: String, components: [PlanComponent], retired: [RetiredComponent])
}

/// Runs a program and returns what it printed. Injected so tests never
/// start a real process.
public typealias CommandRunner =
    (_ executable: String, _ arguments: [String], _ stdin: String?) throws -> (status: Int32, output: String)

public struct PlanDocExtractor {
    public init(cacheDirectory: URL, run: @escaping CommandRunner)
    public func extract(text: String, doc: String) throws -> [PlanComponent]
}

public enum PlanLoader {
    public static func load(planRoot: String, config: G8rConfig,
                            extractor: PlanDocExtractor?) -> PlanGraph
}

// Sources/G8rCore/Config/G8rConfig.swift, moved out of Integrator.swift
public struct G8rConfig: Equatable {
    public var plans: [String]
    public var buildCommand: String?
    public var testCommand: String?
    public var worktreeSetup: String?
    public var ignore: [String]
    public static func load(repoRoot: String,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> G8rConfig
}
```

The extractor runs `claude -p` with `--output-format json` and a JSON schema
for the component list. Its cache is `<plan root>/.g8r/plans/<sha256>.json`.
A loader given no extractor skips free-form docs and says so in `problems`.

- Needs: globs
- Changes: integration
- Code: `Sources/G8rCore/PlanDoc/`, `Sources/G8rCore/Config/`
- Done when: parsing this file yields every component under Built and To
  build with the needs written here, and every entry under Retired. A doc
  with no component sections goes to the extractor, and a second load of
  the same text runs no command. Duplicate ids, unknown ids and cycles each
  produce a problem. `g8r.json`, `.g8r/config.json` and the environment
  override each other in that order.

### swiftsymbols: Swift symbols

Teaches the symbol engine Swift, so g8r can map its own source, and adds the
one thing the map needs that the engine didn't have: which names a file
uses.

The engine's languages become a table, one entry per language, holding the
grammar, the symbol query, the node types that are identifiers, and the rule
for what counts as exported. TypeScript, TSX and JavaScript move into the
table unchanged.

```swift
// Sources/G8rSymbols/
extension SymbolExtractor {
    /// How often each identifier appears in the file, outside comments and
    /// string literals. Empty for a language the engine doesn't know.
    public static func uses(source: String, path: String) -> [String: Int]
}
```

Swift symbols map onto the kinds that exist:

| Swift | Kind | Qualified by |
|---|---|---|
| `class`, `struct`, `actor` | `class` | enclosing types |
| `protocol` | `interface` | enclosing types |
| `enum` | `enum` | enclosing types |
| `typealias` | `type` | enclosing types |
| `func` at the top level | `function` | |
| `func`, `init` in a type or extension | `method` | the type |
| `var`, `let` at the top level | `variable` | |
| `var`, `let` in a type or extension | `property` | the type |

A symbol is exported when it is `public` or `open`. Members of an extension
are qualified by the type the extension extends. Signature and body hashes
mean what they mean for TypeScript.

The grammar is `alex-pinkus/tree-sitter-swift`, pinned to the generated
sources (tag `0.7.3-with-generated-files`, revision `31d17fe`).

- Needs: symbols
- Changes: symbols
- Code: `Sources/G8rSymbols/Languages/`
- Done when: `SymbolExtractor.supports(path:)` accepts `.swift`. Every
  top-level type declared in `Sources/G8rCore` is found with the right kind.
  `uses` counts a type named in code and ignores the same name in a comment
  or a string. Every TypeScript test still passes.

### codemap: Code map

Measures the base map: which files make up each component, which components
use which, which tests cover them, and what can be built next.

**Files.** The files are everything git tracks or would track in the code
root (`git ls-files -co --exclude-standard`), minus the `ignore` globs. A
file belongs to the component whose `Code:` entry matches it; the longest
match wins. An entry ending in `/` names a directory and matches everything
under it. `Glob.matches` doesn't read it that way today, so codemap fixes
`Glob`. Code no entry matches is grouped by directory into nodes with
the id `unplanned:<directory>`. Files that aren't code and match nothing are
left off the map.

**Symbols.** Each code file the engine understands is scanned once.

```swift
// Sources/G8rCore/CodeMap/
public struct Declaration: Codable, Equatable {
    public var name: String            // qualified: "EventBus.start"
    public var kind: String
    public var exported: Bool
    public var topLevel: Bool
    public var signature: String       // one line, no body
}
public struct FileScan: Codable, Equatable {
    public var declarations: [Declaration]
    public var uses: [String: Int]
}
public protocol SymbolScanning {
    func scan(source: String, path: String) -> FileScan?
}

// Sources/G8rSymbols/TreeSitterScanner.swift
public struct TreeSitterScanner: SymbolScanning { public init() }
```

**Edges.** Component A uses component B when a file of A uses a name that is
declared at the top level by B and by no other component. Names under three
characters are ignored. A component never uses itself. An edge carries the
names, most used first, and the total count.

**Tests.** A test file is code under `Tests/`, `tests/` or `__tests__/`, or
named `*Tests.swift`, `*.test.*`, `*.spec.*`, `*_test.*` or `test_*.py`.
Test files are not part of a component's `files` or `loc`. A test file is
attributed to a component, in this order: a `Code:` entry names it; its
subject (the stem without the test suffix) is the stem of a source file or a
top-level name of exactly one component; the component whose names it uses
most. `tests.count` counts test functions.

**Build order.** A planned node's `wave` is 1 when everything it needs is
built, otherwise one more than the highest wave it needs. `blockedBy` lists
the needs that aren't built. `blast` lists the components that use what it
changes.

```swift
public enum LivingMapBuilder {
    public static func build(planRoot: String, codeRoot: String,
                             scanner: SymbolScanning, stages: [MapStage],
                             extractor: PlanDocExtractor?) throws -> LivingMap
}

// Sources/G8rSymbols/StandardMap.swift
public enum StandardMap {
    public static var stages: [MapStage] { [] }
    public static func build(planRoot: String, codeRoot: String? = nil,
                             extract: Bool = false) throws -> LivingMap
}
```

`StandardMap.build` picks the code root: the integration worktree when it
exists, the plan root otherwise.

Asking a model is slow and costs money, so it only happens when `extract`
is true. Otherwise a free-form doc is read from the cache, and a doc that
isn't cached is reported in `problems`. The app passes true when a plan doc
changes on disk or the user asks, never on a routine redraw.

The plan graph is taken as it comes: a need or change that names no
component makes no edge, and a cycle in needs gives its members no wave
instead of looping.

The `g8r-map` executable prints the map for a repo as JSON:
`swift run g8r-map [repo]`.

- Needs: plandoc, symbols, swiftsymbols, globs, worktrees
- Changes: globs
- Code: `Sources/G8rCore/CodeMap/`, `Sources/G8rCore/Config/ProcessRunner.swift`,
  `Sources/G8rSymbols/TreeSitterScanner.swift`,
  `Sources/G8rSymbols/StandardMap.swift`, `Sources/g8r-map/`
- Done when: on a fixture repo, the longest `Code:` match wins, globs match,
  ignored paths are absent and leftover code is grouped by directory. A name
  declared by two components makes no edge. Test attribution follows the
  three rules in order. Waves, `blockedBy` and `blast` are right for a plan
  three levels deep. A cycle in the plan ends with no wave for its members.
  `Glob.matches("a/b/", "a/b/c.swift")` is true. On this repo
  `swift run g8r-map` prints valid JSON in which every tracked source file
  appears in exactly one node, and no node under Built is `planned`.

### drift: Drift edges

Compares the edges the plan declares with the edges the code has, and says
which is which.

| Kind | Declared | Measured | Also |
|---|---|---|---|
| `planned` | either | either | one end isn't built |
| `confirmed` | yes | yes | |
| `unrealized` | yes | no | |
| `indirect` | no | yes | the plan reaches it through other components |
| `undeclared` | no | yes | the plan doesn't reach it at all |

A declared edge is `implied` when the plan also gets there by a longer
route, so a chart can leave it out without losing the build order.

```swift
// Sources/G8rCore/CodeMap/Drift.swift
public struct Drift: MapStage { public init() }
```

- Needs: codemap, plandoc
- Code: `Sources/G8rCore/CodeMap/Drift.swift`
- Done when: each row of the table has a test. An edge from A to C is
  implied when the plan has A to B and B to C. An edge measured from A to C
  with only A to B and B to C declared is `indirect`.

### timeline: Timeline

Replays git history as the map's growth: for each commit, how many lines
each component had.

Only files that exist today count, so a component that was deleted never
appears. Renames are read as a removal and an addition. Test files and
ignored paths are left out, the same way the map leaves them out. Each node
also gets its commit count and its first and last commit.

```swift
// Sources/G8rCore/CodeMap/Timeline.swift
public struct Timeline: MapStage { public init() }
```

- Needs: codemap
- Code: `Sources/G8rCore/CodeMap/Timeline.swift`
- Done when: on a fixture repo with three commits, the first point has only
  the first component, the last point matches each node's `loc`, and a file
  deleted in the second commit counts nowhere. A repo with no commits gives
  an empty timeline, not an error.

### evidence: Evidence status

Decides a node's status from what can be checked, never from what was
reported.

| Status | When |
|---|---|
| `planned` | the component has no code |
| `building` | a build session for it is open |
| `unproven` | it has code, and either no tests or no test run covers them |
| `proven` | it has tests, and all of them passed in the last run |
| `failing` | any of its tests failed in the last run |
| `unplanned` | it has code and no plan mentions it |

A test run executes `test_command` in the code root and keeps two files in
the plan root: `.g8r/test.log`, the raw output, and `.g8r/tests.json`, the
report. The report lists each test case with its suite and whether it
passed. Two output formats are read: XCTest (`Test Case '-[M.Suite name]'
passed`) and swift-testing. When neither matches, only the exit status is
known: zero proves every component that has tests, and non-zero fails them.

A test case belongs to the test file that declares its suite, and through
the file to a component.

```swift
// Sources/G8rCore/Evidence/
public struct TestCaseResult: Codable, Equatable {
    public var suite: String
    public var name: String
    public var passed: Bool
}
public struct TestReport: Codable, Equatable {
    public var ranAt: String
    public var command: String
    public var exit: Int32
    public var cases: [TestCaseResult]
    public static func parse(output: String, command: String, exit: Int32, ranAt: Date) -> TestReport
}
public enum TestRunner {
    /// Runs the command, writes the log and the report, returns the report.
    public static func run(command: String, codeRoot: String, planRoot: String,
                           timeout: TimeInterval) -> TestReport
    public static func lastReport(planRoot: String) -> TestReport?
}
public struct Evidence: MapStage { public init() }
```

`Integrator.runTests` keeps its signature and uses `TestRunner` underneath.

- Needs: codemap, integration
- Changes: integration
- Code: `Sources/G8rCore/Evidence/`
- Done when: both output formats parse from sample logs. Each row of the
  status table has a test. Removing a component's test file turns its node
  from `proven` to `unproven` with no change to the plan. With no report,
  every built node is `unproven`.

### graphview: Graph view

Puts the chart in the app and makes it live.

The viewer is one self-contained page with no network requests. It lives in
`G8rCore` as a resource, so the app and the command line share it.

```swift
// Sources/G8rCore/CodeMap/MapViewer.swift
public enum MapViewer {
    /// A page that draws this map when opened in a browser.
    public static func page(for map: LivingMap) throws -> String
    /// The page with no map in it, for the app to load and then feed.
    public static func shell() throws -> String
}
```

In the app, the map is the first tab of the main area, ahead of the
orchestrator. `MapViewController` hosts the `WKWebView`, answers the bridge
messages, and redraws when any of these happen: the app starts, a plan doc
or `g8r.json` changes on disk, hook events arrive (at most once a second), a
test run ends, or the page asks. The map is measured off the main thread.

```swift
// App/Map/
final class MapViewController: NSViewController {
    init(planRoot: String)
    var onBuild: ((_ component: String) -> Void)?
    var onRunTests: (() -> Void)?
    func refresh()
    func setBusy(_ text: String?)
}
```

Clicking a file opens it in a window, with the lines of the component's
symbols tinted.

The viewer starts from `planmap/index.html`, moved and changed to read the
map contract above. It keeps what the prototype does: layered layout,
hover and selection, the detail panel, edge kinds that can be switched off,
"every edge", the replay slider, the retired list. It adds a header button
to run the tests and a line for problems in the plan. Below 900 points wide
the panel goes under the chart.

`G8R_SNAPSHOT_MAP=<png>` writes a picture of the map view two seconds after
launch, the way `G8R_SNAPSHOT` does for the window.

- Needs: codemap, panes, app
- Changes: panes, app
- Code: `App/Map/`, `Sources/G8rCore/CodeMap/Viewer/`,
  `Sources/G8rCore/CodeMap/MapViewer.swift`
- Done when: `MapViewer.page` returns a page that contains the map and no
  `http` URL to load. Opened in a browser with this repo's map it draws one
  box per node and shows no console error. It draws a map that has only
  codemap's fields. The app launches with the map as its first tab, and
  `G8R_SNAPSHOT_MAP` writes a picture that shows it.

### clickbuild: Click to build

Building a node starts a session that belongs to that node and ends with it.

**Start.** The node must be planned and have nothing in `blockedBy`. g8r
creates `../<repo>-<id>` on `g8r/<id>`, branching from `g8r/integration`
when it exists and from the plan root's `HEAD` otherwise. It runs
`worktree_setup` there, trusts the worktree if the setting is on, installs
the hooks, and opens a pane running
`claude --name build-<id>` with the prompt as its first message. The pane's
environment carries `G8R_PANE_ID=build-<id>` and `G8R_COMPONENT=<id>`.

**Prompt.** Composed from the plan, never written by hand:

1. the component's section, verbatim
2. where its code goes
3. its done-when
4. for each component it needs, the signatures that component exports, read
   from the code at the base commit
5. what it changes, and who uses that
6. the rules: stay in this worktree; commit to this branch; give each commit
   the trailer `G8r-Component: <id>`; list what was assumed in the commit
   body on lines starting `Assumed:`; stop when the done-when holds

**End.** When the session goes idle, g8r checks the worktree: nothing is
uncommitted, `build_command` succeeds, `test_command` succeeds. If the
checks pass, g8r merges the branch into `g8r/integration`, closes the pane
and removes the worktree; the branch is kept. If they fail, g8r types the
failure into the session and waits for it to go idle again. After three
failed rounds it stops typing and leaves the session open for a person.

**Notes.** What sessions assumed is read back from the commits that carry
the component's trailer, and shown on the node.

```swift
// Sources/G8rCore/Build/
public enum PromptComposer {
    public static func prompt(for id: String, in map: LivingMap,
                              interfaces: [String: [String]], base: String) -> String
}
public struct BuildSession: Equatable {
    public enum State: Equatable {
        case working, checking(round: Int), merged(commit: String), needsHuman(reason: String)
    }
    public enum Input: Equatable {
        case wentIdle
        case checked(passed: Bool, tail: String)
        case merged(commit: String)
        case mergeFailed(reason: String)
    }
    public enum Action: Equatable {
        case runChecks(round: Int)
        case merge
        case tell(text: String)
        case close
        case none
    }
    public let component: String
    public private(set) var state: State
    public static let maxRounds = 3
    public init(component: String)
    public mutating func handle(_ input: Input) -> Action
}
public enum BuildChecks {
    public struct Result: Equatable { public var passed: Bool; public var tail: String }
    public static func run(worktree: String, config: G8rConfig, run: CommandRunner) -> Result
}
public struct BuildNotes: MapStage { public init() }

// Sources/G8rCore/Worktrees/GitWorktree.swift gains
public static func ensure(delegate name: String, repoRoot: String, base: String?) throws -> String

// App/Panes/BuildLauncher.swift
final class BuildLauncher {
    init(paneManager: PaneManager, planRoot: String, record: @escaping (G8rEvent) -> Void)
    func build(_ component: String, in map: LivingMap) throws
    func handle(_ event: G8rEvent)
}
```

`BuildNotes` sets `prompt` on planned nodes, `notes` on nodes that have
them, and `building` on nodes with an open session. Open sessions are read
from the event log: a `build_started` with no `build_merged` or
`pane_closed` after it.

- Needs: graphview, evidence, plandoc, codemap, panes, worktrees, hooks,
  trust, integration, eventlog
- Changes: panes, worktrees, hooks, app
- Code: `Sources/G8rCore/Build/`, `App/Panes/BuildLauncher.swift`
- Done when: the prompt for a planned node contains its section, its
  done-when, a signature from each component it needs, and the six rules.
  `BuildSession` has a test for every transition, including the third
  failed round. With `G8R_AGENT_COMMAND` set to a script that writes a
  file, commits it with the trailer and exits, building a node ends with
  the commit on `g8r/integration`, the pane closed and the worktree gone.
  A node with something in `blockedBy` refuses to build.

## Retired

### Delegation protocol

No orchestrator hands out work any more. A click on the map starts the
session. Gone with it: the GATER/1 format, the delegation skill, commit
trailers keyed by dish.

### Plan store

Plans now come from plan docs, not from delegation messages.

### Ownership classifier

A file's owner is the component whose plan names it. No Jev.

### Overlap detector

Collision detection between agents was dropped as a direction. What a
change would touch is shown before it is built instead.

### Map UI

The tree, web and file views were built around features and dishes. The
graph view replaces them.

### Lifecycle messages

Reports typed into the orchestrator. The kitchen states went with the plan
store.

## Out of scope

- Languages beyond Swift, TypeScript, TSX and JavaScript.
- Landing `g8r/integration` on your own branch. That stays your call.
- Cloud sessions.
- Editing the plan from the chart.
