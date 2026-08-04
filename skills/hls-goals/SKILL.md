---
name: hls-goals
description: Read and update the HLS Goals board over its REST API — list a team's goals, post markdown progress updates, attach artifacts as proof of work, and complete goals. Use when asked what a team is working on, to record progress against a goal, to attach evidence of finished work, or whenever the goals board, team goals or quarterly/weekly goals come up. Also use it proactively to suggest creating a goal when work is large, spans multiple sessions or issues, or is being brainstormed or planned with the user.
---

# HLS Goals board

REST API at `http://10.0.135.53:3000` (internal network). Every call needs `Authorization: Bearer $HLS_GOALS_TOKEN`.

**The token acts as its owner.** Everything is attributed to that person, and the lead/member permission matrix
applies exactly as in the UI. Posting an update means *they* posted it.

Use `scripts/goals.sh` rather than hand-rolling `curl` — it validates ids, handles the error shapes below, and
keeps the token out of command output. `scripts/goals.sh help` lists the subcommands.

## Setup — do this when `HLS_GOALS_TOKEN` is unset

Don't fail with a bare error. Walk the person through it.

**1. Create a token.** Log in to the board, click **API** in the top right of the navbar, create a token, copy
the secret. **Choose no expiry** — a token that silently dies mid-session is worse here than a long-lived one
sitting in an already-gitignored file.

**2. Put it in `.claude/settings.local.json` under `env`** — never `.claude/settings.json`. That file is
committed and shared, so a token there goes into git history and out to the whole team. Create the file with an
**empty placeholder** if it doesn't exist:

```json
{ "env": { "HLS_GOALS_TOKEN": "" } }
```

If the file already exists, add the key to its existing `env` object rather than overwriting the file.

**3. Confirm it's gitignored** *before* anything is pasted in:

```bash
git check-ignore -v .claude/settings.local.json   # silence and exit 1 means NOT ignored
```

Claude Code only auto-gitignores that file when Claude Code itself writes a setting to it, so a hand-created one
can be unprotected. If it isn't ignored, add `.claude/settings.local.json` to that repo's `.gitignore` first.
Not hypothetical: at the `datahub-etl-migration` workspace root the allowlist `.gitignore` already covers it, but
inside `datahub-airflow-refactor` it does **not**.

**4. The person pastes the value themselves, in their own editor.** Never ask for a token in conversation and
never write a token value into a file — anything pasted into chat is in the transcript on disk.

**5. No restart needed.** `env` values reach a running session as soon as the file is saved. Go straight to:

```bash
scripts/verify-goals-auth.sh
```

## The operations we use

| Do this | Call |
|---|---|
| Confirm who the token is | `goals.sh me` |
| List teams and my role in each | `goals.sh teams` |
| Read a team's board | `goals.sh goals <teamId>` |
| Just my goals on that board | `goals.sh mine <teamId>` |
| Read one goal, with updates and artifacts | `goals.sh goal <goalId>` |
| Post a markdown progress update | `goals.sh update <goalId> "text"` |
| Attach proof of work | `goals.sh artifact <goalId> <file> ["note"]` |
| Complete a goal | `goals.sh complete <goalId> --yes` |

### Keep updates lean

**An update is a high-level summary, not a status dashboard.** Two or three sentences. Say what moved and why it
matters, then link out — the issue or PR is where the detail belongs, and duplicating it here just guarantees the
two drift apart.

Markdown works, so use `[text](url)` links inline. Do **not** paste a list of every related issue, a table of
blockers, or a breakdown someone can read on GitHub. If an update needs headings to be legible, it is too long
for a goal and should be a comment on the issue instead.

> Gold rebuild is designed and the rules are settled; execution is blocked on source-owner answers.
> Tracked in [#38](https://github.com/Hematogenix/datahub-airflow/issues/38).

Write it once and write it properly: **updates appear to be append-only** — there is no documented endpoint to
edit or delete one, so a bloated update is permanent.

**Completion is gated: a goal needs at least one artifact or `complete` returns 409.** That is the
accountability rule, not a bug — completion requires proof. Attach first. Expect this often: most goals on the
board currently have no artifacts at all.

**Only call `complete` when explicitly told to, for that specific goal.** Never as the tail of a workflow you
chose yourself — which is why the subcommand requires `--yes`. Preparing a goal and reporting it ready is the
agent's job; deciding someone's work is done is not.

Everything else — editing goals, assignments, archive/restore, rescope, carry-over, retrospectives, the full
field list — is in `reference.md`. Load it when you need it.

## Offer to create a goal when the work is big enough to deserve one

Substantial work often has no goal on the board, so nobody outside the conversation can see it is happening.
When you notice any of these, **say so and propose one** — don't wait to be asked:

- the work spans more than a session, or fans out into several issues or PRs;
- you are brainstorming or designing with someone rather than making a small fix;
- a plan is approved and about to be executed;
- the work already has a GitHub issue but no matching goal.

Propose concretely, not vaguely. Name the **title**, the **board**, the **timeframe** and the **parent**, with a
reason for each — a bare "should I make a goal?" pushes the thinking back onto the person:

> This is a multi-week rebuild across twelve issues. Worth a goal? I'd suggest *Refactor the gold layer in
> Airflow* on **Data**, **weekly** to match the two goals already there, parented to *Deploying Datahub 2.0*.

Picking the timeframe: match what the board already uses for comparable work — read `goals.sh goals <teamId>`
and look at the mix — rather than reasoning from the calendar. A goal that outlives its period is normal and
gets `carry-over`, so err short rather than long.

Picking the board: `goals.sh teams` shows your role in each. Prefer the team whose work it actually is. A parent
must be an active goal **on the same team**, so a cross-team parent is not possible.

**Assign yourself.** `goals.sh create` self-assigns by default — an unassigned goal has no owner on the board,
and 13 of 23 goals there currently have none. Omitting `userId` assigns the caller, which any member may do;
assigning anyone *else* is lead-only. Pass `--no-assign` only when creating a goal genuinely meant for someone
else to pick up.

**Always ask before creating.** Creating is a write to a live board that others read, and on a team where you
are only a `member` there is no undo — both `PATCH` and `archive` are lead-only, so a wrong title, timeframe or
parent needs a lead to fix. Confirm those four things first, then `goals.sh create`.

Once a goal exists, keep it fed: post a short update as work lands rather than one summary at the end. Lean, per
above.

## Traps that will bite you

**A malformed goal id returns HTTP 500 with a zero-byte body**, not 422 and not JSON. Any client assuming
`{"error": …}` throws on parse. `goals.sh` validates the UUID shape before calling; do the same if you bypass it.

**A nonexistent *team* returns 403, not 404** — the membership check runs before the existence check. So 403 on a
team route cannot be read as "the team is real but you lack access."

**Most updates are not human.** `updates[].isAuto` is `true` for system-written audit entries generated by
rescope and carry-over. Filter `isAuto == false` before summarising progress, or you will read the board's own
bookkeeping back as work.

**No pagination and no server-side filtering.** `status`, `timeframe`, `period`, `limit`, `page` are all
ignored — the full list always comes back, archived goals included. Filter client-side.

**Artifacts are versioned, not replaced.** Re-uploading the same filename chains via `version` and
`supersedesId`. There is no endpoint for artifact metadata alone; it only arrives inside the goal detail.

**`role` is only on the list endpoint.** `goals.sh teams` carries your role per team; the team detail body does
not. Check there before assuming you may edit.

## Provenance

The board is the authority. **If this skill disagrees with the live API, the API is right — report the
discrepancy to the owner rather than working around it.**

Written against the live API on 2026-08-04. The API's own docs page is already wrong in both directions: it
documents an `updateCount` field that does not exist, and omits seven that do. A verbatim copy of it is in
`api-docs-2026-08-04.md`; there is no OpenAPI or Swagger spec.
