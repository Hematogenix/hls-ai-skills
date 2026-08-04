# HLS Goals API — full reference

Everything not in `SKILL.md`'s core loop. Measured against the live API on **2026-08-04**; where this disagrees
with the board, the board is right — report it rather than working around it.

## Endpoints

### Read

| Endpoint | Returns |
|---|---|
| `GET /api/docs` | the hand-written markdown spec (401 without auth) |
| `GET /api/auth/me` | `{id, name, email}` — no expiry or scope field |
| `GET /api/teams` | `[{id, name, departmentId, departmentName, role}]` — **the only place `role` appears** |
| `GET /api/teams/:teamId` | team detail with roster; **no `role` for the caller** |
| `GET /api/teams/:teamId/goals` | `{goals: [...], currentPeriods}` — exactly two keys |
| `GET /api/goals/:goalId` | full detail, below |
| `GET /api/teams/:teamId/retrospective?scope=&granularity=` | completed goals bucketed by completion date |
| `GET /api/artifacts/:artifactId/download` | the file |

Two endpoints exist but are **not in the API's own docs**: `GET /api/users` → `[{id, name, email}]` (org-wide,
broader than any single roster) and `GET /api/departments` → `[{id, name}]`. Both plain arrays.

`GET /api/tokens` returns **401**, not 403 — token management is browser-session only.

### Write

`POST /api/teams/:teamId/goals` `{title, description?, timeframe, parentGoalId?}` — any member.
Wrapped as `goals.sh create --team <id> --timeframe <tf> --title "..." [--description "..."] [--parent <goalId>]`, which validates the timeframe against the enum and both ids as UUIDs before writing. Named flags on purpose: this is a live write with no undo on a team where you are only a member.
`PATCH /api/goals/:goalId` `{title?, description?, parentGoalId?}` — **lead only**; `parentGoalId: null` unlinks;
the parent must be an active goal in the same team and cycles are rejected.
`POST /api/goals/:goalId/rescope` `{timeframe}` · `POST /api/goals/:goalId/carry-over` (**no body** — the server
targets `currentPeriods[timeframe]` itself) · `POST /api/goals/:goalId/{archive,restore}` — lead only.
`POST /api/goals/:goalId/updates` `{text}` · `POST /api/goals/:goalId/assignments` `{userId?}` (omit to assign
yourself; assigning others is lead-only) · `DELETE /api/goals/:goalId/assignments/:userId`.
Wrapped as `goals.sh assign <goalId>`, self only — a `userId` argument would earn most callers a 403, so it
is not offered. `goals.sh create` self-assigns by default; `--no-assign` opts out.
`POST /api/goals/:goalId/artifacts` multipart `file` + optional `note`, 25 MB cap ·
`DELETE /api/artifacts/:artifactId` (own artifact; others' is lead-only).
`POST /api/goals/:goalId/{complete,reopen}`.

Spelling is `carry-over`; `carryover` 404s. Paths are case-sensitive and a trailing slash 308-redirects.

## The goal object

**List item** (`/api/teams/:teamId/goals`), 16 keys, all present on every row:

`id`, `teamId`, `title`, `description`, `timeframe`, `period`, `status`, `prevStatus`, `parentGoalId`,
`createdBy`, `createdAt`, `completedAt`, `assignees`, `artifactCount`, `parentTitle`, `childCount`

**Detail** (`/api/goals/:goalId`), 17 keys: the same, minus `parentTitle` / `childCount` / `artifactCount`, plus
`updates`, `artifacts`, `parent`, `children`.

The docs are wrong both ways: **`updateCount` is documented but does not exist** in either response, and
`teamId`, `prevStatus`, `createdBy`, `createdAt`, `completedAt`, `parentTitle`, `childCount` are real but
undocumented. There is no way to get an update count without fetching the detail.

| field | type | notes |
|---|---|---|
| `description` | string | never null; `""` when unset, so "optional" means empty, not absent |
| `prevStatus` | string \| null | `null` when active, `"active"` on archived — it is the **restore target**, not a history |
| `parentGoalId` / `parentTitle` | string \| null | always agreed with `parent.id`; no orphans observed |
| `completedAt` | string \| null | ISO-8601 `…Z`, same shape as `createdAt` |
| `createdBy` | string | a raw userId with no name beside it — resolve via `/api/users` or the roster |
| `artifactCount`, `childCount` | number | |

Nested shapes:

```
assignees[] = {userId, name}
children[]  = {id, title, status, timeframe, period}
parent      = {id, title, status}                       -- no period
updates[]   = {id, userId, userName, text, isAuto, createdAt}
artifacts[] = {id, filename, note, uploadedBy, uploaderName, uploadedAt, sizeBytes, version, supersedesId}
```

`updates[].isAuto` marks system-written audit entries from rescope and carry-over, with text like
`Re-scoped to Jul–Sep (yearly → quarterly).` Filter them out before summarising human progress.

Artifacts are **versioned**: `version` is an integer and `supersedesId` is `string | null`, so re-uploading the
same filename chains rather than replaces. `note` may be null.

## Enums

`timeframe` — `yearly | quarterly | monthly | weekly`. All four in use.
`status` — `active | completed | archived`.
`role` — `lead | member`.
Retrospective `scope` — `team | department`; `granularity` — `quarter | month`. Anything else 422s with
`{"error":"invalid scope"}` / `{"error":"invalid granularity"}`. Both default when omitted.

## Periods

`currentPeriods` is keyed by timeframe:

```json
{"yearly":"2026","quarterly":"2026-Q3","monthly":"2026-08","weekly":"2026-W32"}
```

A goal's `period` always matches the format of its own `timeframe`. Weeks are ISO (`2026-W30`). Because the
server derives the destination, **`carry-over` takes no argument**.

## Errors

`{"error": string}` with 401 / 403 / 404 / 409 / 422 — with three deviations that matter:

- **A malformed goal id → HTTP 500, zero-byte body, no content-type.** Not 422, not JSON. Validate the UUID
  client-side.
- **A nonexistent team → 403** `{"error":"not a member of this team"}`, because the membership check precedes
  the existence check. 404 is unreachable on team routes.
- **Unknown `/api/*` paths → an HTML Next.js 404**, not JSON.

Auth failures are distinguishable and worth surfacing separately: no header or a non-Bearer scheme gives
`{"error":"not signed in"}`, while a rejected token gives `{"error":"invalid or revoked API token"}`.

Every documented write route answers a **bare 405 with an empty body and no `Allow` header** to a GET, which
makes GET a safe existence probe.

## No pagination, no server-side filtering

`/api/teams/:teamId/goals` returns everything, archived included. `limit`, `page`, `offset`, `per_page`,
`pageSize`, `cursor`, `status`, `timeframe` and `period` are all **ignored**, and there is no `meta` / `total` /
`next`. Filter client-side.

## Retrospective

`{departmentName, groups[]}` where `groups[] = {period, stats, goals[]}` and
`stats = {completed, contributors, artifacts}`.

Its `goals[]` is a **different shape** from the board's: `{id, title, description, timeframe, period, teamId,
teamName, completedAt, assignees[{userId,name}], artifacts[{id, filename}]}` — note `teamName`, and artifacts
reduced to id and filename. It returns completed goals only, bucketed by **completion date** rather than the
goal's own `period`, so a `2026-W29` goal can appear under group `2026-07`.

`scope=department` reads across the team-membership boundary: goals whose team returns 403 on a direct read are
visible here. Anything summarising a retrospective may therefore surface other teams' content.

## Not present

`GET /api/goals` (no collection), `/api/artifacts` (no collection), `/api/goals/:id/updates` and
`/api/artifacts/:id` are **405 rather than readable** — updates and artifact metadata arrive only inside the
goal detail. Also absent: `/api/health`, `/api/version`, `/api/me`, `/api/users/:id`, `/api/search`,
`/api/notifications`, `/api/config`, `/api/settings`, and `/api/goals/:id/{children,history,activity}`.
