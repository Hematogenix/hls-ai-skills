---
name: hls-board
description: Work a GitHub projects board with the gh CLI — read the board, carry out a specific issue on a linked branch, file a new issue after brainstorming, defer work to the backlog, and check whether a pull request is ready. Use whenever an issue number, the project board, the backlog, or PR/CI status comes up, when someone says "work on #123" or "pick up the next thing", and when a brainstorm produces work that should be written down rather than lost.
---

# GitHub projects board

Everything goes through `scripts/board.sh`. It exists because GitHub Projects v2 is GraphQL behind a thin CLI:
moving a card needs the project's node id, the field's node id and the option's node id, none of which are the
names you see on screen. `board.sh help` lists the subcommands. Run `scripts/verify-board-auth.sh` when
anything looks wrong — it prints scopes, the resolved board and the real status option names.

## Setup — do this when the board commands fail

**1. Grant the project scope.** `gh` does not ask for it at login, so a working `gh` still cannot touch a board:

```bash
gh auth refresh -s project
```

`read:project` is a *different, weaker* scope. It lists a board but cannot move a card, so ask for `project`.

**2. Point the skill at a board.** Take the owner and number from the board URL —
`github.com/orgs/Hematogenix/projects/7` is owner `Hematogenix`, number `7`. `gh project list --owner <org>`
shows what you can reach. Put them in `.claude/settings.local.json` under `env`, never in the committed
`.claude/settings.json`:

```json
{ "env": { "HLS_BOARD_OWNER": "Hematogenix", "HLS_BOARD_NUMBER": "7" } }
```

Add the keys to the existing `env` object if the file already exists. No restart is needed; `env` reaches a
running session as soon as the file is saved. The owner alone can be skipped inside a repo — it defaults to the
repo's owner.

**3. Check the status names match.** The scripts assume `Todo`, `In Progress` and `Backlog`. If the board uses
other words, set `HLS_BOARD_NEW`, `HLS_BOARD_ACTIVE` and `HLS_BOARD_BACKLOG` alongside the two above.
`verify-board-auth.sh` names the mismatch for you.

**4. Say which branch work merges into, if it is not the default.** `work` branches from it and `pr-create`
targets it. Both fall back to the repo's default branch, which is right for most repos. Where it is not — a
repo whose day-to-day branch is `development` while `main` holds an older stack — set it once so nobody has to
remember:

```json
{ "env": { "HLS_BOARD_BASE": "development" } }
```

A single call can override it with `--base <branch>`. Record the repo's real integration branch in that repo's
`CLAUDE.md` too, so it is visible without reading settings.

## The operations we use

| Do this | Call |
|---|---|
| See the board | `board.sh board` or `board.sh board "In Progress"` |
| See just my work | `board.sh mine` |
| Read one issue before starting | `board.sh issue 123` |
| Start work on it | `board.sh work 123` |
| File a new issue | `board.sh new --title "..." --body-file <f> --yes` |
| Push it to the backlog | `board.sh defer 123 --reason "..." --yes` |
| Move a card anywhere else | `board.sh status 123 "In Review" --yes` |
| Leave a short note | `board.sh comment 123 "text" --yes` |
| Is the PR ready? | `board.sh pr` |
| Open the PR | `board.sh pr-create --yes` |

**Every write takes `--yes`, and that flag means a person said yes.** The board and the issue tracker are read
by other people; a wrong card move or a chatty issue costs someone else time. Confirm the title, the labels or
the reason first, then pass `--yes`. `work` is the one exception: it creates a branch and moves the card the
person just asked you to work on, which is exactly what they asked for.

## Keep issues and comments slim

**This is the rule that matters most, because an agent will get it wrong by default.** You have the whole
conversation in context and the temptation is to write all of it down. Don't.

An issue body is three things: what is wrong or wanted, how we will know it is done, and a link if one exists.
Usually four lines. No restating the discussion that produced it, no design essay, no options table, no
checklist of everything you considered.

> Weekly QC export drops rows when a sample has no result row.
>
> Done when the export includes every sample, with blanks for missing results.
> Seen in the 2026-08-11 run, see [#88](https://github.com/Hematogenix/x/issues/88).

Comments are one or two sentences: what changed and where to look. `board.sh comment` is for "root cause was
the inner join, fix in #92" — not for pasting a diff, a log or a status table. If a note needs headings to be
readable, it belongs in the PR description or a doc, and the comment should link to it.

Write the body to a file and pass `--body-file`. `board.sh new` requires this on purpose: inline bodies get
mangled by shell quoting, and the file forces you to look at the length before it is public.

## The four workflows

### Working an issue

1. `board.sh issue 123` — read it before touching anything. Check nobody else is assigned and no branch exists.
2. `board.sh work 123` — creates the linked branch off the base branch and moves the card to In Progress.
   GitHub owns the branch name; do not invent your own, because the link is what ties the branch to the issue
   in the UI.
3. Do the work. Commit as normal.
4. `board.sh pr-create --yes` when there is something to review. It opens a **draft** PR against the base
   branch whose body says `Closes #123`, so merging closes the issue. On a repo whose base is not the default
   branch, `board.sh pr` will report `closes: NOTHING` even with the keyword present — GitHub only links the
   reference when merging would reach the default branch. Check the body rather than trusting that line.
5. `board.sh pr` to watch checks. Merging is a human decision — never merge.

If the issue turns out to be bigger than it read, say so and propose splitting it rather than quietly growing
the branch.

### Creating an issue after brainstorming

Brainstorming produces far more text than an issue should hold. Distil, don't transcribe.

1. Say what you would file: title, one-line body, labels. Ask.
2. Write the body to a file, then `board.sh new --title "..." --body-file /tmp/body.md --yes`.
3. It lands on the board as Todo, unassigned. Filing an issue is not the same as taking it on, so leave it for
   whoever picks it up. Add `--assign-me` only when the person says they are taking it now.
4. If several issues come out of one discussion, file them separately — one issue per thing that can be
   finished on its own.

### Deferring work to the backlog

Deferring is the honest move when work surfaces mid-task but is not this task. It is better than a TODO comment
nobody reads and better than scope creep.

`board.sh defer 123 --reason "blocked on the vendor schema, revisit after 2.0" --yes` moves the card to
Backlog, comments the reason and unassigns you. The reason is required: the board shows *what* moved, only the
comment says *why*, and in three weeks nobody remembers.

If the deferred work does not have an issue yet, create it first, then defer it.

### Checking a PR

`board.sh pr` on the branch, or `board.sh pr [number]`. It reports check counts, failing check names, the
review decision, mergeability, and — the one people miss — whether the PR actually closes an issue. A linked
branch alone does **not** close anything on merge; only `Closes #n` in the body does.

Report what it says plainly. Failing checks are a fact, not something to work around.

## When the work is bigger than an issue

Work spanning several issues or more than a session usually deserves a goal on the HLS Goals board too — see
the `hls-goals` skill, which will also tell you to propose one. Keep them in their lanes: the goal carries a
two-sentence summary and links to the issue; the issue carries the detail. Do not copy one into the other, or
they drift.

## Traps that will bite you

**Projects v2 wants node ids, not names.** `gh project item-edit` takes `--field-id`, `--project-id` and
`--single-select-option-id`, all opaque ids. Passing the name of a status is accepted on the command line and
does nothing useful. `board.sh` resolves the ids for you; do the same if you bypass it.

**`read:project` is not `project`.** The read scope lists boards fine, which makes the failure look like a bug
in the write path rather than a missing permission.

**There is no lookup by issue number.** `gh project item-list` returns a page of items and you scan it
client-side; the default limit is 30, so `board.sh` asks for 500 and tells you when a lookup ran off the end.

**An issue must already be on the board.** `work`, `defer` and `status` fail if it is not. Add it with
`gh project item-add <n> --owner <o> --url <issue-url>`.

**`gh issue develop` needs a real branch checked out.** It fails oddly on a detached HEAD, and it can only
branch issues in the current repository.

**`gh pr view --json closingIssuesReferences` does not exist before gh ~2.50** — it errors with "Unknown JSON
field". `board.sh pr` asks GraphQL instead, so it works on the 2.45 that is installed here.

**`gh pr checks` exits non-zero when checks fail**, which kills a `set -e` script that calls it unguarded. Use
`board.sh pr`, which reads the check rollup as JSON instead.

**Draft PRs do not run every workflow.** A green `board.sh pr` on a draft can still turn red when it is marked
ready, if any workflow filters on `types: [ready_for_review]`.

Field shapes, the JSON these commands return and how to reach the parts `gh` does not expose are in
`reference.md`. Load it when a command's output surprises you.
