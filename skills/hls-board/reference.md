# hls-board reference

Detail behind `SKILL.md`. Load when a command's output is not what you expected, or when you need something
`board.sh` does not wrap.

Written against `gh` 2.45.0 and the GitHub Projects v2 API.

## What the JSON looks like

### `gh project view <n> --owner <o> --format json`

```json
{ "id": "PVT_kwDO...", "number": 7, "title": "Delivery", "url": "...", "items": {"totalCount": 41},
  "fields": {"totalCount": 6}, "owner": {"type": "Organization", "login": "Hematogenix"} }
```

`.id` is the project node id every `item-edit` call needs.

### `gh project field-list <n> --owner <o> --format json --limit 100`

```json
{ "fields": [
  { "id": "PVTF_...", "name": "Title", "type": "ProjectV2Field" },
  { "id": "PVTSSF_...", "name": "Status", "type": "ProjectV2SingleSelectField",
    "options": [ {"id": "f75ad846", "name": "Todo"}, {"id": "47fc9ee4", "name": "In Progress"} ] } ] }
```

Option ids are short hex strings, not `PVT*` ids. Only single-select fields carry `options`. Iteration fields
need `--iteration-id` instead, and date fields `--date YYYY-MM-DD`.

### `gh project item-list <n> --owner <o> --format json --limit 500`

```json
{ "items": [
  { "id": "PVTI_...", "title": "Fix the QC export", "status": "In Progress",
    "content": { "type": "Issue", "number": 123, "title": "...", "url": "...", "body": "...",
                 "repository": "Hematogenix/x" } } ] }
```

Custom field values are flattened onto the item, keyed by the field name in camelCase — `Status` becomes
`status`, `Target Date` becomes `targetDate`. A field with no value on that item is simply absent, which is why
`board.sh` reads it as `.status // "-"`.

`content.type` is `Issue`, `PullRequest` or `DraftIssue`. Draft issues have no number and no URL, so they
cannot be worked, deferred or linked to a branch — convert them in the UI first.

## One field per call

`gh project item-edit` updates a single field per invocation for real issues. Moving a card and setting a date
is two calls. There is no batch endpoint through the CLI.

## Things `gh project` does not expose

Reach for `gh api graphql` when you need:

- an item's full field values including which iteration it sits in;
- adding an issue to a project *and* setting fields atomically;
- reading the project's status-update posts.

The mutation behind a card move, if you ever need it directly:

```bash
gh api graphql -f query='
  mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){
    updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,
      value:{singleSelectOptionId:$o}}){ projectV2Item { id } } }' \
  -f p=PVT_... -f i=PVTI_... -f f=PVTSSF_... -f o=47fc9ee4
```

## Linked branches vs closing keywords

Two separate mechanisms, and they are easy to conflate.

- `gh issue develop 123 --checkout` creates a **linked branch**. GitHub shows it in the issue's Development
  panel. It does not close the issue.
- `Closes #123` in the **PR body** is what closes the issue on merge. `Fixes` and `Resolves` work the same;
  the keyword must be in the body or a commit message, and the issue must be in the same repository unless you
  write the full `owner/repo#123`.

**`gh` 2.45 has no `closingIssuesReferences` JSON field** — `gh pr view --json closingIssuesReferences` fails
with "Unknown JSON field" and lists what it does support. Newer `gh` has it. `board.sh pr` sidesteps the
version question by asking GraphQL:

```bash
gh api graphql -F owner=cli -F name=cli -F number=14065 -f query='
  query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$number){ closingIssuesReferences(first:20){ nodes { number } } } } }' \
  -q '.data.repository.pullRequest.closingIssuesReferences.nodes[].number'
```

An empty result on a PR meant to finish an issue means the body is missing the keyword. Two things also
produce an empty result even when the body looks right: a keyword pointing at an issue in another repository
written as a bare `#123`, and a PR whose base is not the default branch — GitHub only links the reference when
merging would actually reach the default branch.

Watch the failure mode: on a GraphQL error `gh` prints the whole error document to **stdout**, so a naive
capture ends up holding JSON where it expected numbers. `board.sh` filters to bare digits for that reason.

The branch name is chosen by GitHub, typically `123-slug-of-the-title`. Override with `--name` only if a repo
convention demands it, and expect the automation that parses branch names to break if you do.

## `gh pr view --json statusCheckRollup`

Each entry is either a check run or a legacy commit status, and their shapes differ:

```json
{ "__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
  "detailsUrl": "...", "workflowName": "ci" }
{ "__typename": "StatusContext", "context": "codecov", "state": "SUCCESS", "targetUrl": "..." }
```

So a status context has no `.name` and no `.conclusion`. `board.sh pr` counts on `.conclusion` and `.status`,
which means legacy statuses fall into the "pending" bucket. If a repo still uses them, count `.state` too.

`conclusion` values worth handling: `SUCCESS`, `FAILURE`, `TIMED_OUT`, `CANCELLED`, `SKIPPED`, `NEUTRAL`,
`ACTION_REQUIRED`. `SKIPPED` and `NEUTRAL` are not failures.

`reviewDecision` is `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `null` when no review is required.

`mergeable` is `MERGEABLE`, `CONFLICTING` or `UNKNOWN`. `UNKNOWN` usually means GitHub is still computing it —
re-read after a few seconds rather than reporting it as a problem.

## Rate limits

Project mutations are GraphQL and share the 5000 points/hour GraphQL budget. `gh api rate_limit` shows what is
left. Listing a 500-item board is a single query, so ordinary use will not come close.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `HLS_BOARD_OWNER` | the current repo's owner | org or user that owns the board |
| `HLS_BOARD_NUMBER` | none, required | the number in the board URL |
| `HLS_BOARD_BASE` | the repo's default branch | branch `work` branches from and `pr-create` targets |
| `HLS_BOARD_STATUS_FIELD` | `Status` | the single-select field cards move between |
| `HLS_BOARD_NEW` | `Todo` | status a newly filed issue lands in |
| `HLS_BOARD_ACTIVE` | `In Progress` | status `work` moves a card to |
| `HLS_BOARD_BACKLOG` | `Backlog` | status `defer` moves a card to |
| `HLS_BOARD_LIMIT` | `500` | how many items to fetch when looking up an issue |
