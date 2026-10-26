#!/usr/bin/env python3
"""Check a PR body against the pr-description format. Exit 1 and list every problem.

Usage: check_pr_body.py BODY.md

The code itself lives on the PR's review page (scripts/build_review_page.py); in the body,
## Code flow is the file counts and a link to that page.
"""
import argparse
import re
import sys

SECTIONS = [
    "What lands", "How it is built", "Code flow",
    "Migration", "After deploying", "Testing",
]
MAY_BE_NONE = {"Migration", "After deploying"}
ATTRIBUTION = "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
PLACEHOLDER = re.compile(r"\b(TODO|TBD|FIXME|XXX)\b|lorem ipsum|<fill", re.I)
ARTIFACT = re.compile(r"https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9-]+")
COUNTS = re.compile(r"^\d+ files?: .*\(\+\d+ −\d+\)", re.M)
FENCE = re.compile(r"^```(\w*)\s*\n(.*?)^```\s*$", re.S | re.M)


def strip_fences(text):
    return FENCE.sub("", text)


def split_sections(body):
    """Return (intro, [(heading, level, text)]) ignoring headings inside code fences."""
    lines, in_fence, heads = body.splitlines(), False, []
    for i, line in enumerate(lines):
        if line.startswith("```"):
            in_fence = not in_fence
        elif not in_fence and (m := re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)):
            heads.append((i, len(m.group(1)), m.group(2)))
    intro = "\n".join(lines[: heads[0][0]] if heads else lines)
    out = []
    for k, (i, level, title) in enumerate(heads):
        end = heads[k + 1][0] if k + 1 < len(heads) else len(lines)
        out.append((title, level, "\n".join(lines[i + 1 : end]).strip()))
    return intro.strip(), out


def has_list(text, numbered=False):
    pat = r"^\d+\.\s+\S" if numbered else r"^(\s*)([-*]|\d+\.)\s+\S"
    return re.search(pat, strip_fences(text), re.M) is not None



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("body")
    a = ap.parse_args()
    body = open(a.body, encoding="utf-8").read()
    problems = []

    if body.count("```") % 2:
        problems.append("Unbalanced ``` code fences.")
    nonblank = [l for l in body.splitlines() if l.strip()]
    if not nonblank or nonblank[-1].strip() != ATTRIBUTION:
        problems.append(f"The last line must be exactly: {ATTRIBUTION}")
    if body.count("Generated with [Claude Code]") > 1:
        problems.append("The attribution line appears more than once.")
    body_wo_attr = body.replace(ATTRIBUTION, "")
    if m := PLACEHOLDER.search(strip_fences(body_wo_attr)):
        problems.append(f"Placeholder text left in: {m.group(0)!r}.")

    intro, sections = split_sections(body_wo_attr)
    intro_text = strip_fences(intro)
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", intro_text) if s.strip()]
    if not intro_text:
        problems.append("Start with a 1–3 sentence summary before the first heading.")
    elif "\n\n" in intro_text or re.search(r"^\s*([-*]|\d+\.)\s", intro_text, re.M):
        problems.append("The opening summary must be one plain paragraph, no list.")
    elif len(sentences) > 3:
        problems.append(f"The opening summary has {len(sentences)} sentences; keep it to 3 or fewer.")

    bad_level = [t for t, lvl, _ in sections if lvl != 2]
    for t in bad_level:
        problems.append(f"Heading {t!r} isn't `##`. Only the fixed `##` sections are allowed; use bold text or sub-bullets inside them.")
    titles = [t for t, lvl, _ in sections if lvl == 2]
    if titles != SECTIONS:
        extra = [t for t in titles if t not in SECTIONS]
        missing = [t for t in SECTIONS if t not in titles]
        if extra:
            problems.append(f"Unexpected sections: {extra}. Fold them into the fixed sections.")
        if missing:
            problems.append(f"Missing sections: {missing}.")
        if not extra and not missing:
            problems.append(f"Sections out of order. Expected: {SECTIONS}.")
        dupes = {t for t in titles if titles.count(t) > 1}
        if dupes:
            problems.append(f"Duplicated sections: {sorted(dupes)}.")

    text = {t: s for t, lvl, s in sections if lvl == 2}
    for t in SECTIONS:
        s = text.get(t)
        if s is None:
            continue
        if not s:
            problems.append(f"{t}: empty. Write `None.` only where that's allowed ({', '.join(sorted(MAY_BE_NONE))}).")
            continue
        if s == "None.":
            if t not in MAY_BE_NONE:
                problems.append(f"{t}: `None.` isn't allowed here.")
            continue
        if t in ("What lands", "How it is built", "Testing") and not has_list(s):
            problems.append(f"{t}: write it as a bullet list.")
        if t == "After deploying" and not has_list(s, numbered=True):
            problems.append("After deploying: write the steps as a numbered list, or `None.`.")
        if t == "Migration" and "`" not in s:
            problems.append("Migration: name each migration in backticks, or write `None.`.")
        if t == "Code flow":
            if not ARTIFACT.search(s):
                problems.append("Code flow: link to the PR's review page (a claude.ai artifact).")
            if "```" in s or "<details" in s or re.search(r"^\|", s, re.M):
                problems.append("Code flow: keep diagrams, tables and diffs on the review page, not in the body.")
            if len([l for l in s.splitlines() if l.strip()]) > 3:
                problems.append("Code flow: keep it to the counts line and one sentence with the link.")
            if not COUNTS.search(s):
                problems.append("Code flow: start with the counts line from `group_changes.py --summary`.")

    if problems:
        print(f"{len(problems)} problem(s) in {a.body}:")
        for p in problems:
            print(f"- {p}")
        sys.exit(1)
    print(f"OK: {a.body} follows the format.")


if __name__ == "__main__":
    main()
