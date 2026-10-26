#!/usr/bin/env python3
"""Build the PR's review page: a pan-and-zoom canvas of the code the PR changes.

Usage: build_review_page.py SPEC.json OUT.html [--base REF] [--head REF]

Each box in the spec is a range of lines in one file; arrows say what calls what. Opening a box
shows its diff with surrounding context. Each box's tests sit collapsed beside it. Every Core
file must be a box and every test file must sit beside the box it checks; migrations, docs,
config and generated files go in the page's Other files panel. Every line on the page
is read from git, so it can't drift from the branch. See SKILL.md for the spec format.
"""
import argparse
import html
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from group_changes import GROUPS, classify, default_base, numstat  # noqa: E402

TEMPLATE = Path(__file__).parent.parent / "assets" / "review_page.html"
MAX_BOX_LINES = 200  # a box's line range; split a longer range into two boxes
MAX_FILE_ROWS = 1500  # Other files diffs; past this the page links to GitHub
NO_DIFF_GROUPS = {"Generated"}


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          errors="replace").stdout


def file_at(ref, path):
    try:
        return git("show", f"{ref}:{path}").splitlines()
    except subprocess.CalledProcessError:
        return None


def parse_diff(text):
    """Unified diff -> rows of [kind, old_no, new_no, text]; kind is ' ', '+', '-' or '@'."""
    rows, old, new = [], 0, 0
    for line in text.splitlines():
        if line.startswith("@@"):
            m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            old, new = int(m.group(1)), int(m.group(2))
            rows.append(["@", None, None, line])
        elif not rows or line.startswith("\\"):
            continue
        elif line.startswith("+"):
            rows.append(["+", None, new, line[1:]])
            new += 1
        elif line.startswith("-"):
            rows.append(["-", old, None, line[1:]])
            old += 1
        else:
            rows.append([" ", old, new, line[1:]])
            old += 1
            new += 1
    return rows


class Repo:
    def __init__(self, base, head):
        self.base, self.head = base, head
        self.changed = {f["path"]: f for f in numstat(base, head)}
        self._full = {}

    def full_rows(self, path):
        """The whole file at head as diff rows: changed lines marked, every other line as context."""
        if path not in self._full:
            f = self.changed.get(path)
            if f and not f["binary"]:
                paths = [f["old"], path] if f["old"] else [path]
                rows = [r for r in parse_diff(git("diff", "-U100000", "-M", f"{self.base}...{self.head}",
                                                  "--", *paths)) if r[0] != "@"]
            else:
                lines = file_at(self.head, path) or []
                rows = [[" ", n, n, t] for n, t in enumerate(lines, 1)]
            self._full[path] = rows
        return self._full[path]

    def length(self, path):
        lines = file_at(self.head, path)
        return None if lines is None else len(lines)

    def slice(self, path, start, end):
        """Rows whose head line is in [start, end], plus the deletions that sit between them."""
        rows, out, pending = self.full_rows(path), [], []
        for r in rows:
            if r[0] == "-":
                pending.append(r)
                continue
            if start <= r[2] <= end:
                out.extend(pending)
                out.append(r)
            pending = []
        return out


def code_ref(repo, item, where, problems, limit=MAX_BOX_LINES):
    """Validate a {file, lines} reference and return its rows."""
    path = item.get("file")
    n = repo.length(path)
    if n is None:
        problems.append(f"{where}: `{path}` doesn't exist at {repo.head}.")
        return None
    start, end = item.get("lines") or [1, n]
    if not (1 <= start <= end <= n):
        problems.append(f"{where}: lines {start}–{end} are outside `{path}` (1–{n}).")
        return None
    if limit and end - start + 1 > limit:
        problems.append(f"{where}: {end - start + 1} lines; keep a box to {limit} or split it.")
    return {"file": path, "start": start, "end": end, "rows": repo.slice(path, start, end)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("out")
    ap.add_argument("--base")
    ap.add_argument("--head", default="HEAD")
    a = ap.parse_args()
    base = a.base or default_base()
    spec = json.loads(Path(a.spec).read_text())
    problems = []
    for key in ("title", "repo", "summary", "nodes", "edges"):
        if not spec.get(key):
            problems.append(f"spec: `{key}` is missing or empty.")
    if problems:
        sys.exit("Spec problems:\n- " + "\n- ".join(problems))

    repo = Repo(base, a.head)
    notes = spec.get("notes", {})
    ids, nodes, in_flow = set(), [], set()
    for i, n in enumerate(spec["nodes"]):
        nid = n.get("id")
        where = f"nodes[{nid or i}]"
        if not nid or not re.fullmatch(r"[A-Za-z0-9_-]+", nid):
            problems.append(f"{where}: give it an `id` of letters, digits, - or _.")
            continue
        if nid in ids:
            problems.append(f"{where}: duplicate id.")
        ids.add(nid)
        node = {"id": nid, "title": n.get("title", ""), "note": n.get("note", ""), "code": None, "tests": [],
                "open": bool(n.get("open"))}
        if not node["title"]:
            problems.append(f"{where}: needs a `title`.")
        if n.get("file"):
            node["code"] = code_ref(repo, n, where, problems)
            in_flow.add(n["file"])
        for j, t in enumerate(n.get("tests") or []):
            t = {"file": t} if isinstance(t, str) else t
            ref = code_ref(repo, t, f"{where}.tests[{j}]", problems, limit=None)
            if ref:
                ref["label"] = t.get("label") or Path(t["file"]).name
                node["tests"].append(ref)
                in_flow.add(t["file"])
        nodes.append(node)
    edges = []
    for k, e in enumerate(spec["edges"]):
        for end in ("from", "to"):
            if e.get(end) not in ids:
                problems.append(f"edges[{k}]: `{end}` = `{e.get(end)}` isn't a node id.")
        if not (e.get("description") or "").strip():
            problems.append(f"edges[{k}] {e.get('from')} → {e.get('to')}: add a `description` of what passes along it.")
        edges.append({"from": e.get("from"), "to": e.get("to"), "label": e.get("label", ""),
                      "description": e.get("description", "")})
    linked = {e["from"] for e in edges} | {e["to"] for e in edges}
    for nid in ids - linked:
        if len(ids) > 1:
            problems.append(f"nodes[{nid}]: no arrow in or out; connect it or drop it.")

    others = []
    for path, f in sorted(repo.changed.items(), key=lambda kv: (GROUPS.index(classify(kv[0])), kv[0])):
        if path in in_flow:
            continue
        group = classify(path)
        if group == "Core":
            problems.append(f"Core file `{path}` isn't on the diagram; give it a box.")
        if group == "Tests":
            problems.append(f"Test file `{path}` isn't beside any box; add it to the `tests` of the box it checks.")
        rows, truncated = [], False
        if not f["binary"] and group not in NO_DIFF_GROUPS:
            paths = [f["old"], path] if f["old"] else [path]
            rows = parse_diff(git("diff", "-U3", "-M", f"{base}...{a.head}", "--", *paths))
            if len(rows) > MAX_FILE_ROWS:
                rows, truncated = rows[:MAX_FILE_ROWS], True
        others.append({"path": path, "old": f["old"], "group": group, "add": f["add"], "del": f["del"],
                       "binary": f["binary"], "rows": rows, "truncated": truncated,
                       "note": notes.get(path, "")})
    if problems:
        sys.exit("Spec problems:\n- " + "\n- ".join(problems))

    totals = {}
    for path, f in repo.changed.items():
        g = totals.setdefault(classify(path), [0, 0, 0])
        g[0] += 1
        g[1] += f["add"]
        g[2] += f["del"]
    data = {
        "title": spec["title"], "repo": spec["repo"], "pr": spec.get("pr"), "summary": spec["summary"],
        "rankdir": spec.get("rankdir", "TB"), "base": base, "head": a.head,
        "head_sha": git("rev-parse", a.head).strip(), "nodes": nodes, "edges": edges, "others": others,
        "totals": [[g, *totals[g]] for g in GROUPS if g in totals],
    }
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    page = TEMPLATE.read_text()
    page = page.replace("__TITLE__", html.escape(spec.get("page_title") or f"PR {spec.get('pr', '')} review".strip()))
    page = page.replace("__DATA__", payload)
    Path(a.out).write_text(page)
    print(f"Wrote {a.out}: {len(nodes)} boxes, {len(edges)} arrows, "
          f"{sum(len(n['tests']) for n in nodes)} tests beside boxes, {len(others)} other files.")


if __name__ == "__main__":
    main()
