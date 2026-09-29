#!/usr/bin/env python3
"""planmap: build the living map of this repo from its plan docs and its code.

Reads the plan docs named in g8r.json (PLAN.md) and measures
everything else from the repo: which files make up each component, which
components use which, which tests cover them and whether they pass, and how
the map grew commit by commit. Writes planmap/map.js for index.html.

    python3 planmap/build_map.py          # use the last test log, if any
    python3 planmap/build_map.py --test   # run `swift test` first

Prototype: symbols come from a regex scan of Swift. The in-app version would
use the tree-sitter engine in Sources/G8rSymbols.
"""
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CODE_EXT = {".swift", ".c", ".h", ".py", ".sh"}
TEST_LOG = os.path.join(HERE, "test.log")


def sh(args, cwd=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True).stdout


ROOT = sh(["git", "-C", HERE, "rev-parse", "--show-toplevel"]).strip()
SELF = os.path.relpath(HERE, ROOT) + "/"


def read(path):
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def is_code(path):
    return os.path.splitext(path)[1] in CODE_EXT


# --------------------------------------------------------------- the plans
# Plan docs are parsed as PLAN.md describes under "Plan doc format": a
# heading `id: Name` opens a component, and its bullets say what it needs,
# changes and where its code lives.

CONFIG = json.loads(read("g8r.json") or "{}")
PLAN_DOCS = CONFIG.get("plans") or ["PLAN.md"]
IGNORE = CONFIG.get("ignore", [])

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
COMPONENT = re.compile(r"^([a-z][a-z0-9-]*): (.+)$")
BULLET = re.compile(r"^- (needs|changes|code|done when):\s*(.*)$", re.I)


def glob_regex(pattern):
    out, i = "^", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + "$")


def matches(pattern, path):
    if any(c in pattern for c in "*?"):
        return bool(glob_regex(pattern).match(path))
    return path == pattern or (pattern.endswith("/") and path.startswith(pattern))


def parse_plan(doc):
    text = read(doc)
    if text is None:
        return None, [], []
    lines, fenced, heads = text.split("\n"), False, []
    for i, line in enumerate(lines):
        if line.startswith("```"):
            fenced = not fenced
        m = None if fenced else HEADING.match(line)
        if m:
            heads.append((i, len(m.group(1)), m.group(2)))
    title = next((t for _, level, t in heads if level == 1), doc)

    def body(index):
        start, level, _ = heads[index]
        end = next((i for i, l, _ in heads[index + 1:] if l <= level), len(lines))
        return "\n".join(lines[start + 1:end]).strip()

    components, retired, retired_level = [], [], None
    for index, (i, level, heading) in enumerate(heads):
        if retired_level is not None and level <= retired_level:
            retired_level = None
        if heading.lower() == "retired":
            retired_level = level
            continue
        if retired_level is not None:
            retired.append({"name": heading, "why": " ".join(body(index).split()), "doc": doc, "line": i + 1})
            continue
        m = COMPONENT.match(heading)
        if not m or not 2 <= level <= 4:
            continue
        text_body, fields, key = body(index), {}, None
        for line in text_body.split("\n"):
            b = BULLET.match(line)
            if b:
                key = b.group(1).lower()
                fields[key] = b.group(2)
            elif key and line.startswith(" ") and line.strip():
                fields[key] += " " + line.strip()
            else:
                key = None
        items = lambda k: [v.strip().strip("`") for v in fields.get(k, "").split(",") if v.strip()]
        first = " ".join(text_body.split("\n\n")[0].split())
        components.append({
            "id": m.group(1), "name": m.group(2), "plan": doc, "doc": doc, "ref": m.group(1),
            "summary": re.split(r"(?<=[.!?])\s", first)[0],
            "paths": items("code"), "needs": items("needs"), "changes": items("changes"),
            "doneWhen": fields.get("done when"),
            "section": {"doc": doc, "line": i + 1, "heading": heading,
                        "text": text_body[:1600].rstrip() + ("\n…" if len(text_body) > 1600 else "")},
        })
    return title, components, retired


PLAN = {"name": CONFIG.get("name"), "plans": []}
comps = {}
for doc in PLAN_DOCS:
    title, components, retired = parse_plan(doc)
    if title is None:
        continue
    PLAN["plans"].append({"id": doc, "title": title, "doc": doc, "retired": retired})
    for c in components:
        comps[c["id"]] = c


def owner_of(path):
    """The component whose plan names this path; the most specific wins."""
    best, best_len = None, -1
    for c in comps.values():
        for p in c["paths"]:
            if matches(p, path) and len(p) > best_len:
                best, best_len = c["id"], len(p)
    return best


# --------------------------------------------------------------- the files

# Tracked files plus new ones not yet added; ignored files stay out.
tracked = [p for p in sh(["git", "-C", ROOT, "ls-files", "-co", "--exclude-standard"]).split("\n")
           if p and not p.startswith(SELF) and os.path.exists(os.path.join(ROOT, p))
           and not any(matches(g, p) for g in IGNORE)]
source = [p for p in tracked if not p.startswith("Tests/")]
tests = [p for p in tracked if p.startswith("Tests/") and p.endswith(".swift")]

# Code no plan mentions becomes an unplanned component, one per directory.
orphans = defaultdict(list)
for p in source:
    if is_code(p) and owner_of(p) is None:
        orphans[os.path.dirname(p)].append(p)
for directory, paths in sorted(orphans.items()):
    stems = [os.path.splitext(os.path.basename(p))[0] for p in paths]
    cid = "unplanned:" + directory
    comps[cid] = {
        "id": cid, "name": ", ".join(stems), "plan": None, "doc": None, "ref": "no plan",
        "summary": "Code in " + directory + "/ that no plan doc mentions.",
        "paths": paths, "needs": [], "section": None,
    }

files_of = defaultdict(list)
for p in source:
    o = owner_of(p)
    if o:
        files_of[o].append(p)

# -------------------------------------------------------------- the symbols

TYPE_RE = re.compile(
    r"^(?:(?:public|private|fileprivate|internal|open|final|indirect)\s+)*"
    r"(struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)", re.M)
IDENT_RE = re.compile(r"\b[A-Z]\w*\b")


def strip_noise(src):
    """Drops strings and comments, so prose never counts as a use."""
    src = re.sub(r'"""(?:.|\n)*?"""', '""', src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return re.sub(r"//[^\n]*", " ", src)


declared_in = defaultdict(set)   # type name -> components declaring it
file_symbols = {}                # path -> [{kind, name}]
for cid, paths in files_of.items():
    for p in paths:
        src = read(p) if p.endswith(".swift") else None
        if src is None:
            continue
        found = [{"kind": k, "name": n} for k, n in TYPE_RE.findall(src)]
        file_symbols[p] = found
        for s in found:
            declared_in[s["name"]].add(cid)

# A name declared by two components can't say who is being used.
type_owner = {n: next(iter(o)) for n, o in declared_in.items() if len(o) == 1}


def uses_in(path):
    """owner component -> Counter of its type names used in this file."""
    src = read(path)
    used = defaultdict(Counter)
    if src is None or not path.endswith(".swift"):
        return used
    for ident in IDENT_RE.findall(strip_noise(src)):
        owner = type_owner.get(ident)
        if owner:
            used[owner][ident] += 1
    return used


uses = defaultdict(lambda: defaultdict(Counter))   # user -> owner -> names
for cid, paths in files_of.items():
    for p in paths:
        for owner, names in uses_in(p).items():
            if owner != cid:
                uses[cid][owner].update(names)

# ---------------------------------------------------------------- the tests

stem_owner = {os.path.splitext(os.path.basename(p))[0]: c
              for c, paths in files_of.items() for p in paths}


def test_owner(name, path):
    """Which component a test class covers: by file stem, then by type
    name, then by whichever component's types it uses most."""
    subject = re.sub(r"Tests?$", "", name)
    if subject in stem_owner:
        return stem_owner[subject]
    if subject in type_owner:
        return type_owner[subject]
    totals = Counter({o: sum(n.values()) for o, n in uses_in(path).items()})
    return totals.most_common(1)[0][0] if totals else None


if "--test" in sys.argv:
    print("running swift test …", file=sys.stderr)
    out = subprocess.run(["swift", "test"], cwd=ROOT, capture_output=True, text=True)
    with open(TEST_LOG, "w", encoding="utf-8") as f:
        f.write(out.stdout + out.stderr)

results = {}   # test class -> Counter(passed=, failed=)
log_time = None
if os.path.exists(TEST_LOG):
    log_time = os.path.getmtime(TEST_LOG)
    with open(TEST_LOG, encoding="utf-8") as f:
        for m in re.finditer(r"Test Case '-\[\w+\.(\w+) \w+\]' (passed|failed)", f.read()):
            results.setdefault(m.group(1), Counter())[m.group(2)] += 1

tests_of = defaultdict(lambda: {"files": [], "count": 0, "passed": 0, "failed": 0})
for p in tests:
    src = read(p) or ""
    classes = re.findall(r"class\s+(\w+)\s*:\s*XCTestCase", src)
    for cls in classes:
        owner = test_owner(cls, p)
        if owner is None:
            continue
        body = src.split("class " + cls, 1)[1]
        nxt = re.search(r"\n(?:final\s+)?class\s+\w+\s*:\s*XCTestCase", body)
        count = len(re.findall(r"\bfunc\s+test\w*\s*\(", body[:nxt.start()] if nxt else body))
        t = tests_of[owner]
        if p not in t["files"]:
            t["files"].append(p)
        t["count"] += count
        t["passed"] += results.get(cls, {}).get("passed", 0)
        t["failed"] += results.get(cls, {}).get("failed", 0)

# ------------------------------------------------------------------ history

history, loc_now = [], Counter()
file_loc = Counter()
touched = defaultdict(list)   # component -> [(sha, time, subject)]
log = sh(["git", "-C", ROOT, "log", "--reverse", "--no-renames", "--numstat",
          "--format=@%h|%at|%s"])
commit = None
for line in log.split("\n") + ["@end|0|"]:
    if line.startswith("@"):
        if commit:
            per = Counter()
            for p, n in file_loc.items():
                o = owner_of(p) if n > 0 else None
                if o is None and n > 0 and os.path.dirname(p) in orphans:
                    o = "unplanned:" + os.path.dirname(p)
                if o:
                    per[o] += n
            history.append(dict(commit, loc=dict(per)))
        sha, at, subject = line[1:].split("|", 2)
        commit = {"sha": sha, "t": int(at), "subject": subject}
        seen = set()
        continue
    parts = line.split("\t")
    if len(parts) != 3 or parts[0] == "-":
        continue
    path = parts[2]
    if path.startswith(("Tests/", SELF)) or not is_code(path):
        continue
    if not os.path.exists(os.path.join(ROOT, path)):
        continue        # removed since: it isn't part of today's map
    file_loc[path] += int(parts[0]) - int(parts[1])
    o = owner_of(path)
    if o is None and os.path.dirname(path) in orphans:
        o = "unplanned:" + os.path.dirname(path)
    if o and o not in seen:
        seen.add(o)
        touched[o].append((commit["sha"], commit["t"], commit["subject"]))

# ------------------------------------------------------------- the prompts


def signature(decl):
    """The declaration up to the brace that opens its body."""
    depth = 0
    for i, ch in enumerate(decl):
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "{" and depth == 0:
            return decl[:i].rstrip()
    return decl.rstrip()


def interface(cid, cap=22):
    """The component's public surface, as declaration lines."""
    types, funcs, rest = [], [], []
    for p in files_of.get(cid, []):
        src = read(p)
        if src is None or not p.endswith(".swift"):
            continue
        lines, i = src.split("\n"), -1
        while i + 1 < len(lines):
            i += 1
            s = lines[i].strip()
            if not s.startswith(("public ", "open ")):
                continue
            while s.count("(") > s.count(")") and i + 1 < len(lines):
                i += 1
                s += " " + lines[i].strip()
            s = signature(s)
            if re.search(r"\b(struct|class|enum|protocol|actor|typealias)\b", s):
                types.append(s)
            elif re.search(r"\b(func|init)\b", s):
                funcs.append(s)
            elif re.search(r"\b(var|let)\b", s) and "static" in s:
                rest.append(s)
    if not types and not funcs:   # app targets aren't public
        for p in files_of.get(cid, []):
            for s in file_symbols.get(p, []):
                types.append(s["kind"] + " " + s["name"])
    lines = types + funcs + rest
    more = len(lines) - cap
    return lines[:cap] + (["… and %d more" % more] if more > 0 else [])


def built(cid):
    return any(is_code(p) for p in files_of.get(cid, []))


def prompt_for(c, head):
    parts = ['You are building "%s" for G8r.' % c["name"], ""]
    sec = c.get("section")
    if sec:
        parts += ["## What to build", sec["text"], ""]
    parts += ["## Where it goes"] + ["- " + p for p in c["paths"]] + [""]
    needs = [n for n in c.get("needs", []) if built(n)]
    if needs:
        parts += ["## Interfaces you depend on (read from the code at %s)" % head, ""]
        for n in needs:
            parts.append("### %s (%s)" % (comps[n]["name"], ", ".join(comps[n]["paths"][:2])))
            parts += interface(n) + [""]
    changes = c.get("changes", [])
    if changes:
        names = ", ".join(comps[x]["name"] for x in changes)
        affected = sorted({comps[u]["name"] for x in changes for u in uses if x in uses[u]
                           and u not in changes})
        parts.append("## You will change: " + names)
        if affected:
            parts.append("Used by: " + ", ".join(affected) +
                         ". Keep the public surface stable or update their call sites.")
    return "\n".join(parts).strip()


# ------------------------------------------------------------------ the map

head = sh(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"]).strip()

nodes = []
for cid, c in comps.items():
    paths = files_of.get(cid, [])
    code = [p for p in paths if is_code(p)]
    loc = sum(len((read(p) or "").split("\n")) for p in code)
    t = tests_of.get(cid)
    if built(cid):
        if c["plan"] is None:
            status = "unplanned"
        elif t and t["passed"] and not t["failed"]:
            status = "proven"
        elif t and t["failed"]:
            status = "failing"
        else:
            status = "unproven"
    else:
        status = "planned"
    commits = touched.get(cid, [])
    node = {
        "id": cid, "name": c["name"], "plan": c["plan"], "ref": c.get("ref"),
        "summary": c.get("summary"), "status": status,
        "needs": c.get("needs", []), "changes": c.get("changes", []),
        "paths": c["paths"], "loc": loc,
        "files": [{"path": p, "loc": len((read(p) or "").split("\n")) if is_code(p) else 0,
                   "symbols": file_symbols.get(p, [])} for p in sorted(paths)],
        "tests": t,
        "section": c.get("section"),
        "doneWhen": c.get("doneWhen"),
        "git": {"commits": len(commits),
                "first": dict(zip(("sha", "t", "subject"), commits[0])) if commits else None,
                "last": dict(zip(("sha", "t", "subject"), commits[-1])) if commits else None},
    }
    if status == "planned":
        node["blockedBy"] = [n for n in node["needs"] if not built(n)]
        node["blast"] = sorted({u for x in node["changes"] for u in uses
                                if x in uses[u] and u not in node["changes"]})
        node["prompt"] = prompt_for(c, head)
        node["command"] = "claude --worktree %s --name delegate-%s" % (cid, cid)
    nodes.append(node)

# Build order for what isn't built yet: a wave is everything whose needs are
# already built or sit in an earlier wave.
wave, placed = 1, {n["id"] for n in nodes if n["status"] != "planned"}
pending = [n for n in nodes if n["status"] == "planned"]
while pending:
    ready = [n for n in pending if all(x in placed for x in n["needs"])]
    if not ready:          # a cycle in the plan: show it rather than hang
        for n in pending:
            n["wave"] = None
        break
    for n in ready:
        n["wave"] = wave
    placed |= {n["id"] for n in ready}
    pending = [n for n in pending if n["id"] not in placed]
    wave += 1

edges = {}
for cid, c in comps.items():
    for need in c.get("needs", []):
        if need in comps:
            edges[(cid, need)] = {"from": cid, "to": need, "declared": True, "measured": False,
                                  "symbols": [], "refs": 0}
for user, owners in uses.items():
    for owner, names in owners.items():
        e = edges.setdefault((user, owner), {"from": user, "to": owner, "declared": False,
                                             "measured": False, "symbols": [], "refs": 0})
        e["measured"] = True
        e["symbols"] = [n for n, _ in names.most_common(8)]
        e["refs"] = sum(names.values())
declared_needs = {cid: [n for n in c.get("needs", []) if n in comps] for cid, c in comps.items()}


def reaches(a, skip=None):
    """Everything a's plan leads to, optionally without the direct edge to `skip`."""
    seen, stack = set(), [n for n in declared_needs[a] if n != skip]
    while stack:
        x = stack.pop()
        if x not in seen:
            seen.add(x)
            stack.extend(declared_needs[x])
    return seen


for e in edges.values():
    a, b = e["from"], e["to"]
    # Declared, but the plan also gets there by a longer route: a chart can
    # leave it out without losing the build order.
    e["implied"] = e["declared"] and b in reaches(a, skip=b)
    if not (built(a) and built(b)):
        e["kind"] = "planned"
    elif e["declared"] and e["measured"]:
        e["kind"] = "confirmed"
    elif e["declared"]:
        e["kind"] = "unrealized"
    elif b in reaches(a):
        e["kind"] = "indirect"      # the plan implies it; the code uses it directly
    else:
        e["kind"] = "undeclared"

result = {
    "repo": PLAN.get("name") or "g8r",
    "head": head,
    "generated": time.strftime("%Y-%m-%d %H:%M"),
    "plans": [{"id": p["id"], "title": p["title"], "doc": p["doc"]} for p in PLAN["plans"]],
    "retired": [dict(r, plan=p["title"], ref="") for p in PLAN["plans"] for r in p.get("retired", [])],
    "nodes": nodes,
    "edges": sorted(edges.values(), key=lambda e: (e["from"], e["to"])),
    "timeline": history,
    "tests": {"ran": log_time is not None,
              "at": time.strftime("%Y-%m-%d %H:%M", time.localtime(log_time)) if log_time else None,
              "passed": sum(r["passed"] for r in results.values()),
              "failed": sum(r["failed"] for r in results.values())},
}

with open(os.path.join(HERE, "map.js"), "w", encoding="utf-8") as f:
    f.write("window.PLANMAP = " + json.dumps(result, indent=1) + ";\n")

by_kind = Counter(e["kind"] for e in result["edges"])
by_status = Counter(n["status"] for n in nodes)
print("%d components: %s" % (len(nodes), ", ".join("%d %s" % (v, k) for k, v in by_status.most_common())))
print("%d edges: %s" % (len(edges), ", ".join("%d %s" % (v, k) for k, v in by_kind.most_common())))
print("%d commits, tests: %s" % (len(history), "%(passed)d passed, %(failed)d failed" % result["tests"]
                                 if result["tests"]["ran"] else "no test log (run with --test)"))
