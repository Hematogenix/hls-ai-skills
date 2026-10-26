---
name: pr-description
description: Write or rewrite a GitHub pull request description in the team's fixed format, and build the PR's review page, a claude.ai artifact that is a pan-and-zoom flowchart of the PR's actual code: each box is a block of code that expands into its diff, arrows follow the calls, tests sit collapsed beside the box they test, and other changed files sit in a side panel. Use this whenever a PR is being opened, its body drafted, updated or fixed, or the user asks for a PR description, PR body, PR summary, review page or "write up the PR", even if they don't say "skill" or name the format. Also use it before any `gh pr create` or `gh pr edit --body`.
---

# PR descriptions and review pages

Needs Claude Code with the Artifact tool (to publish the page to claude.ai), plus `python3`, `git` and `gh`. The scripts use only the Python standard library.

A PR gets two things:

1. **The body**, in a fixed shape so reviewers always know where to look. Earlier PRs drifted: sections were renamed, merged, skipped or reordered. So the shape is strict, and `scripts/check_pr_body.py` enforces it.
2. **A review page**, a private claude.ai artifact the body links to. It is a flowchart made of the PR's real code, so a reviewer can follow the code instead of reading about it:
   - each box is a block of lines in one file, collapsed to a title, a one-line note and its +/− counts;
   - clicking a box opens its diff with surrounding context, and long unchanged stretches stay folded until clicked;
   - arrows follow the calls, labeled with the call itself (`run_model(layer=TEMP)`). Each arrow also has a one- or two-sentence description of what passes along it, shown when **Show descriptions** is checked;
   - every test file sits beside the box of code it checks. A **Show tests** checkbox at the top shows or hides all the test lanes, and each test stays collapsed until clicked. While tests are hidden, a box shows how many it has;
   - every Core file is a box on the diagram; the **Other files** panel holds only migrations, docs, config and generated files;
   - the canvas pans and zooms (drag, Ctrl/pinch to zoom, Fit), and opening a box keeps it where it was on screen.

`scripts/build_review_page.py` reads every line from git, so the page can't drift from the branch.

A complete worked example comes from Hematogenix/datahub-airflow#362:
- `references/example.md`: the body;
- `references/example_spec.json`: the page spec;
- the published page: https://claude.ai/artifact/8joRktEWxdo4jWnQCS7MS7 (private to its author; ask them to share it if you want to see it).

Read the example body and spec before writing your first ones.

## The body's shape

The sections below come in this order, with these exact `##` titles. No other headings, at any level.

```
<summary paragraph, no heading>
## What lands
## How it is built
## Code flow
## Migration
## After deploying
## Testing
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

**Summary paragraph.** 1–3 plain sentences: what the PR adds or fixes and why, in words a teammate outside the work understands. No heading and no list.

**What lands.** A bullet list of what exists after merge that didn't before, or what behaves differently.
- Bold the name of each user-visible thing: tables, columns, DAGs, endpoints, pages, settings, CLI flags.
- Use sub-bullets for its columns or behavior.
- Console pages, docs and prompts each get their own bullet here, not their own section.

**How it is built.** A bullet list of the design:
- where the code lives;
- how it differs from the existing thing it resembles;
- what it deliberately doesn't do, and what enforces that.

If a change to shared code affects paths beyond this feature, call it out in its own bullet. Reviewers most need to see that.

**Code flow.** Two lines:
1. the counts line printed by `scripts/group_changes.py --summary`;
2. one sentence saying what path the page follows, ending in the link to the page.

No diagrams, code or tables in the body.

**Migration.** Name each migration in backticks. Say whether it must run after another PR's migration. Otherwise write `None.`

**After deploying.** A numbered list of manual steps an operator must run once (backfills, triggers, unpausing, settings), with exact parameters. Otherwise write `None.`

**Testing.** A bullet list of what you actually ran and what it showed, with counts where there are any ("Console tests pass (862)").
- Name the new tests or scenarios, and what cases they cover.
- If something wasn't run, say so: "Live suite not run: needs the cluster".
- Never list a check you didn't run. Reviewers rely on this section to decide what to re-check.

## Steps

1. **Find the base.** It's the branch the PR targets. Follow the repo's own instructions (CLAUDE.md, CONTRIBUTING) when they name one; the DataHub repos (datahub-airflow, datahub-deployment), for example, target `development`. Otherwise use the default branch: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. Run `git fetch origin` so `origin/<base>` is current. If the PR already exists, read its body with `gh pr view <n> --json body,baseRefName`:
   - keep facts from it that aren't in the code, such as test results and deploy notes;
   - reuse the artifact URL it links, so the review page keeps its address.
2. **Read the change.** Run `git log --oneline origin/<base>..HEAD` and `git diff origin/<base>...HEAD`. Read the Core files' diffs in full. Skim tests to learn which cases they cover. The page links to GitHub at the head commit, so push the branch before building the page, or those links won't resolve.
3. **Write the page spec** (format below) to the scratchpad as `spec.json`.
4. **Build the page.** Run `python3 <skill-dir>/scripts/build_review_page.py spec.json <name>-review.html --base origin/<base>`. It refuses a spec that has problems, such as:
   - a line range outside its file, or a box longer than 200 lines;
   - an arrow to an unknown box, an arrow with no `description`, or a box with no arrows;
   - a Core file with no box on the diagram;
   - a test file that isn't beside any box.

   Fix the spec and rebuild until it prints `Wrote ...`.
5. **Publish the page** with the Artifact tool. `file_path` is the built HTML; `icon` is `code` on the first publish only.
   - On a rebuild in the same session, publish the same `file_path`.
   - If the PR body already links a page from an earlier session, pass that link as `url`, so the PR's link keeps working.
6. **Write the body** to the scratchpad as `pr_body.md`, with the artifact URL in Code flow. Run `python3 <skill-dir>/scripts/check_pr_body.py pr_body.md`. Fix every problem it lists and rerun until it prints `OK`. Don't work around a check, for example by renaming a section to dodge it. If a check is wrong for a real case, tell the user.
7. **Publish only when asked.** Opening or editing a PR is visible to others. If the user asked you to open or update the PR:
   - open it with `gh pr create --base <base> --title "<title>" --body-file pr_body.md`;
   - update it with `gh pr edit <n> --body-file pr_body.md`;
   - if `gh pr edit` fails on a "projects classic" GraphQL error, use `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -F body=@pr_body.md`.

   Otherwise, show the body and the page link.
8. **Tell the user about sharing.** The page is private to them until they share it from its Share menu. Reviewers can't open the link until they do.

The title is a short sentence in the imperative, under ~70 characters, with no prefix tags unless the repo uses them.

## The page spec

```json
{
  "title": "PR title",
  "page_title": "Short Page Name",          // browser tab and gallery name, 2–4 words
  "repo": "Owner/name",
  "pr": 362,                                 // omit before the PR exists
  "summary": "The body's summary paragraph.",
  "rankdir": "TB",                           // TB top-to-bottom (default) or LR
  "nodes": [
    {"id": "spine", "title": "040 spine: left joins replace the gate",
     "note": "One sentence a reviewer needs before opening it.",
     "file": "path/at/head.sql", "lines": [1, 81],
     "tests": [{"file": "tests/test_x.py", "lines": [95, 108], "label": "test_x.py: the case"}],
     "open": false}                          // true to open it on load; use for the entry point only
  ],
  "edges": [{"from": "dags", "to": "build", "label": "temp_dag(\"hdx\", …)",
             "description": "One or two sentences: what passes from one box to the next, and why."}],
  "notes": {"migrate/x/000055_y.up.sql": "Optional note for a file in Other files"}
}
```

**Choosing the boxes.** The flow is the path a reviewer follows to understand the PR, from the trigger (DAG, route, CLI, cron) to what it produces (tables, pages, responses).
- A box is the lines that do one step: a function, a SQL step, a macro, a route handler. Pick the range that shows the step whole, up to 200 lines. Split a longer file into two boxes.
- Include unchanged code when the reader needs it to follow the path: the existing function a new one plugs into, for example. Its lines show as context, not as green.
- Shared code whose change reaches beyond this feature gets its own box, with the note saying so.
- **Every Core file gets a box.** Core is the code that matters, so none of it is relegated to the side panel. That includes small mechanical ones (a two-line upsert, a nav link, a template), each placed where it runs in the flow. A big PR simply has more boxes.

**Arrows** are calls, reads, writes or triggers, in run order. Label one when the call or argument matters (`run_model(layer=TEMP, buckets)`, `reads silver.temp_hdx`). Leave obvious next-step arrows unlabeled. Branches and joins are fine: the layout handles them.

**Descriptions** are required on every arrow, including unlabeled ones. In one or two sentences, say what passes from one box to the next (the table, value or call) and why the next step needs it. Readers turn them on to follow the code without opening every box.
- Write from the code you read, not from the box titles. Name the real table, column or function.
- Good: "080 writes the finished field rows to staging.temp_hdx_source; 090 upserts them into silver.temp_hdx by row_key."
- Weak: "Then the data goes to the next step." 

**Tests:** every changed test file goes beside the box whose code it checks. That covers unit tests, test helpers, and scenario inputs, expected outputs and READMEs.
- Scenario inputs sit beside the step that reads them, and expected outputs beside the step that produces them.
- A test that covers a whole run (a live suite, a DAG-shape test) sits beside the box that starts that run.
- A file may sit beside more than one box when it checks several.
- Give `lines` to show just the new test. Without `lines`, the whole file is shown, with unchanged stretches folded.
- Write each `label` as what the reader needs ("scenario 2: mappings, one deleted (input)"), not just the file name.

**Notes** are optional one-liners for files in the Other files panel (a migration, a docs page).

## When the format seems not to fit

- **Docs-only or config-only PR:** keep every section and still build the page. The boxes are the config or doc that matters and the code that reads it. Migration and After deploying are `None.`
- **Huge PR:** Other files caps each diff at 1500 lines, then links to GitHub. The flow still shows only the boxes a reviewer needs.
- **Deployment-repo PR (manifests, kustomize tags):** Core is the manifests. The flow is the rollout (migrate job → apply → pods restart), with boxes on the manifest lines that change. After deploying lists the exact `kubectl` commands the operator runs.
