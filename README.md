# hls-ai-skills

Agent skills shared across Hematogenix, installable with `gh skill`.

One skill per directory under `skills/`, each with a `SKILL.md` carrying `name` and `description` frontmatter.
That description is the only part an agent loads at startup, so it states both what the skill does and when to
reach for it — that is what makes the skill trigger at the right moment.

## Installing

```bash
gh skill install Hematogenix/hls-ai-skills hls-goals
```

`gh skill` is in preview and arrived in a recent GitHub CLI. If the command is unrecognised, upgrade first:

```bash
gh --version          # 2.45 is too old — it has no `skill` command
gh extension upgrade --all
# then upgrade gh itself via your package manager, e.g.
sudo apt update && sudo apt install --only-upgrade gh
```

Other subcommands worth knowing: `gh skill list` shows what you have installed, `gh skill search` finds skills
across repositories, and `gh skill update` pulls newer versions of ones you already have.

## Skills

| Skill | What it does | You will also need |
|---|---|---|
| [`hls-goals`](skills/hls-goals/) | Read and update the HLS Goals board over its REST API — list a team's goals, post markdown progress updates, attach artifacts as proof of work, complete goals. | An `HLS_GOALS_TOKEN` of your own. See below. |
| [`hls-board`](skills/hls-board/) | Work a GitHub projects board with `gh` — read the board, start an issue on a linked branch, file a slim issue after brainstorming, defer work to the backlog, check whether a PR is ready. | `gh auth refresh -s project`, plus `HLS_BOARD_OWNER` and `HLS_BOARD_NUMBER`. |
| [`pr-description`](skills/pr-description/) | Write a PR body in a fixed format and build its review page — a pan-and-zoom flowchart of the PR's real code, where each box opens to its diff, arrows carry call descriptions, and tests sit beside the code they check. | Claude Code with the Artifact tool (claude.ai), plus `python3`, `git` and `gh`. |

### hls-goals needs a token before it works

Installing the skill does **not** give you access. The Goals board authenticates with a personal API token that
acts as *you* — your team memberships and your lead/member permissions apply exactly as they do in the UI, and
every action is attributed to you. So each person needs their own.

The skill walks you through this on first use, but in short:

1. Sign in to the Goals board, click **API** in the top-right of the navbar, create a token, and copy the secret.
2. Store it under the `env` key of **`.claude/settings.local.json`** — *not* `.claude/settings.json`, which is
   committed and shared, so a token there goes into git and out to the whole team.
3. Check `.claude/settings.local.json` is gitignored, and add it if not. Claude Code only auto-gitignores that
   file when it writes a setting there itself, so a hand-created one can be unprotected.
4. Run `skills/hls-goals/scripts/verify-goals-auth.sh` to confirm. `env` values reach a running session as soon
   as the file is saved, so no restart is needed.

Never paste a token into a chat or commit it to a file. Anything pasted into a conversation is written to the
transcript on disk.

### hls-board needs the project scope before it works

`gh` does not request the `project` scope at login, so a `gh` you have been using happily for months still
cannot read or move a card on a projects board. Grant it once:

```bash
gh auth refresh -s project
```

`read:project` is a weaker, separate scope: it lists a board but cannot move anything, which makes the failure
look like a bug rather than a permission. Then set `HLS_BOARD_OWNER` and `HLS_BOARD_NUMBER` under `env` in
`.claude/settings.local.json` — both come from the board URL — and run
`skills/hls-board/scripts/verify-board-auth.sh`, which prints exactly what is missing.

## Adding a skill

Create `skills/<name>/SKILL.md` with `name` and `description` frontmatter. Keep the body lean — auth, the few
operations people actually use, and pointers outward — and put fuller detail in a sibling `reference.md` that is
loaded only when needed. Wrap any HTTP or shell mechanics in `scripts/`, so there is one place to fix when an
API changes. Commit scripts with their executable bit set (`git update-index --chmod=+x`), because a clone
preserves the mode and an install that lands a non-executable script fails confusingly.

If a skill ever disagrees with the live system it describes, the system is right. Report the discrepancy so the
skill gets fixed rather than working around it in place.
