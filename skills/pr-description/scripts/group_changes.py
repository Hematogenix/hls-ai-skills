#!/usr/bin/env python3
"""Print the "## Changes" section of a PR body: changed files grouped, with line counts.

Usage: group_changes.py [--base REF] [--head REF] [--summary]

Core and Migrations render open; Tests, Docs, Config & CI and Generated render
collapsed, so they stay one click away without crowding the changes that matter.
Core rows end in an empty Note cell for the writer to fill. A folder with more than
--collapse changed files in one group shows as a single `folder/` row.
"""
import argparse
import re
import subprocess
import sys
from pathlib import PurePosixPath

# Order is the order the groups appear in the PR body.
GROUPS = ["Core", "Migrations", "Tests", "Docs", "Config & CI", "Generated"]
OPEN = {"Core", "Migrations"}

GENERATED_NAMES = {
    "poetry.lock", "uv.lock", "Pipfile.lock", "package-lock.json", "yarn.lock",
    "pnpm-lock.yaml", "Cargo.lock", "go.sum",
}
CONFIG_NAMES = {
    "pyproject.toml", "setup.cfg", "setup.py", "tox.ini", "ruff.toml", ".flake8",
    "package.json", "tsconfig.json", ".pre-commit-config.yaml", ".gitignore",
    ".dockerignore", ".editorconfig", "Makefile", "renovate.json", "CODEOWNERS",
}


def classify(path: str) -> str:
    p = PurePosixPath(path)
    parts = [x.lower() for x in p.parts]
    name = p.name.lower()
    if p.name in GENERATED_NAMES or ".min." in name or "/__snapshots__/" in f"/{path}/":
        return "Generated"
    if (
        any(x in ("tests", "test", "__tests__", "testdata", "fixtures") for x in parts[:-1])
        or name.startswith("test_")
        or re.search(r"(_test|\.test|\.spec)\.[a-z]+$", name)
        or name == "conftest.py"
    ):
        return "Tests"
    if any(x in ("migrate", "migrations", "alembic") for x in parts[:-1]):
        return "Migrations"
    if (
        parts[0] in ("docs", "doc", "wiki")
        or name.endswith((".md", ".rst", ".adoc"))
        or name.startswith(("readme", "changelog", "license"))
    ):
        return "Docs"
    if parts[0] in (".github", ".circleci", ".gitlab") or p.name in CONFIG_NAMES or re.match(
        r"requirements.*\.txt$", name
    ):
        return "Config & CI"
    return "Core"


def numstat(base: str, head: str):
    out = subprocess.run(
        ["git", "diff", "--numstat", "-z", "-M", f"{base}...{head}"],
        check=True, capture_output=True,
    ).stdout.decode()
    fields = out.split("\0")
    i, rows = 0, []
    while i < len(fields):
        rec = fields[i]
        i += 1
        if not rec:
            continue
        added, deleted, path = rec.split("\t", 2)
        old = None
        if path == "":  # rename: the old and new paths follow as their own fields
            old, path = fields[i], fields[i + 1]
            i += 2
        binary = added == "-"
        rows.append({
            "path": path, "old": old, "binary": binary,
            "add": 0 if binary else int(added), "del": 0 if binary else int(deleted),
        })
    return rows


def fold_folders(files, limit):
    """Replace a folder's rows with one `folder/` row when it holds more than `limit` files."""
    by_dir = {}
    for r in files:
        by_dir.setdefault(str(PurePosixPath(r["path"]).parent), []).append(r)
    out = []
    for d, rs in by_dir.items():
        if len(rs) > limit and d != ".":
            out.append({
                "path": f"{d}/", "old": None, "binary": False, "count": len(rs),
                "add": sum(r["add"] for r in rs), "del": sum(r["del"] for r in rs),
            })
        else:
            out.extend(rs)
    return sorted(out, key=lambda r: r["path"])


def default_base() -> str:
    for ref in ("origin/development", "origin/main", "origin/master"):
        if subprocess.run(["git", "rev-parse", "-q", "--verify", ref],
                          capture_output=True).returncode == 0:
            return ref
    sys.exit("No --base given and no origin/development, origin/main or origin/master.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", help="PR target branch (default: origin/development, then main)")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--collapse", type=int, default=4,
                    help="fold a folder's files into one row when it has more than this many")
    ap.add_argument("--summary", action="store_true",
                    help="print only the one-line counts used in the PR body's ## Changes")
    a = ap.parse_args()
    base = a.base or default_base()

    rows = numstat(base, a.head)
    if not rows:
        sys.exit(f"No changes between {base} and {a.head}.")
    grouped = {g: [] for g in GROUPS}
    for r in rows:
        grouped[classify(r["path"])].append(r)

    if a.summary:
        parts = [
            f"{g} {len(fs)} (+{sum(r['add'] for r in fs)} −{sum(r['del'] for r in fs)})"
            for g, fs in grouped.items() if fs
        ]
        print(f"{len(rows)} files: " + " · ".join(parts) + ".")
        return

    print("## Changes\n")
    for g in GROUPS:
        if not grouped[g]:
            continue
        add = sum(r["add"] for r in grouped[g])
        dele = sum(r["del"] for r in grouped[g])
        n = len(grouped[g])
        files = fold_folders(sorted(grouped[g], key=lambda r: r["path"]), a.collapse)
        attr = " open" if g in OPEN else ""
        print(f"<details{attr}>")
        print(f"<summary><b>{g}</b> · {n} file{'s' if n != 1 else ''} · +{add} −{dele}</summary>\n")
        if g == "Core":
            print("| File | + | − | Note |\n|---|---:|---:|---|")
        else:
            print("| File | + | − |\n|---|---:|---:|")
        for r in files:
            name = f"`{r['path']}`"
            if r.get("count"):
                name += f" ({r['count']} files)"
            if r["old"]:
                name += f" (from `{r['old']}`)"
            plus, minus = ("bin", "bin") if r["binary"] else (r["add"], r["del"])
            note = " |" if g == "Core" else ""
            print(f"| {name} | {plus} | {minus} |{note}")
        print("\n</details>\n")


if __name__ == "__main__":
    main()
