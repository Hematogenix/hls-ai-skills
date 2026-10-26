Adds two test tables that let every HDX form through, whatever its double entry or accession says, so we can see what we would get without the holds.

## What lands

- **`silver.temp_hdx`**: one row per form and field, like `silver.hdx`, plus:
  - `entry_type`, per form, the first that fits: `ERROR`, `ENTRY_DELETED`, `SINGLE_ENTRY`, `INCOMPLETE`, `COMPLETE` (exactly what `silver.hdx` publishes), `MISMATCH`.
  - `complete_value`: the superuser's choice, else the value both entries agree on, else a single entry's value. NULL where the entries disagree and nobody resolved it.
  - `entries_agree` per field (NULL on a single entry), `accession_withheld_reason`, and `status` (`MATCH`, `MISMATCH`, `SINGLE_ENTRY`, `RESOLVED`).
- **`silver.temp_hdx_categorized`**: one row per form with three JSON maps of field to value, `entry1`, `entry2` and `complete`, plus `entry_type`, `accession_withheld_reason` and `partial_view_missing`. `complete` is filled only when `entry_type` is `COMPLETE` and every field has a complete value.
- **DAGs `temp_load_hdx` and `temp_load_hdx_categorized`**: the first runs when `silver_load_hdx` would, the second after it.
- **Console page HDX test** (`/dq/hdx-test`): counts by entry type, a form list filtered by entry type, accession hold or protocol, and a form view with entry 1, entry 2 and the complete value side by side.
- **Docs**: both tables on a new "HDX test in silver" page, a README section on the first load and removal, and the Data Explorer system prompt (wiki `00144aa`, already live).

## How it is built

- The models live in a new `temp` layer, at `airflow/sql/temp/hdx/` and `airflow/sql/temp/hdx_categorized/`. Their steps follow `silver/hdx` and `silver/hdx_categorized`, except:
  - left joins replace the double-entry gate;
  - each form is keyed on its own, so a form with no enrollment still gets an accession verdict;
  - a mapping tombstone flags its form deleted.
- The accession ladder is shared: `hdx.temp_gate` writes the same verdicts to `staging.temp_hdx_accession`.
- No fates and no ledger rows. Nothing reads these tables, so they never reach the gate, the spine or gold. Tests fail if another model reads a temp table.
- Each DAG runs every step in one task and takes a `buckets` param, so one run can load the whole history.
- **Shared change:** `run_model` now counts rows written to `silver.` or `gold.` instead of the model's own layer. That gives the same count for every existing layer, but it touches every layer DAG.

## Code flow

54 files: Core 26 (+1142 −9) · Migrations 2 (+488 −0) · Tests 20 (+326 −8) · Docs 6 (+86 −1).
Follow the code from the DAGs to the console, each box opening to its diff, with tests beside it: **[review page](https://claude.ai/artifact/8joRktEWxdo4jWnQCS7MS7)**.

## Migration

ClickHouse `000055_temp_hdx`, after Hematogenix/datahub-airflow#360's `000054_finding_value_accessions`.

## After deploying

1. Trigger `temp_load_hdx` with `{"window_start": "2000-01-01", "buckets": 64}`.
2. When it finishes, trigger `temp_load_hdx_categorized` the same way.

## Testing

- Offline airflow tests and ruff pass.
- Console tests pass (862).
- New scenario `temp_hdx_entry_types` covers a form of every entry type, a form with no accession and a COMPLETE form whose entries disagree. Its second step settles the mismatch and deletes a mapping.
- Every HDX scenario passes with bucketed reruns, which write nothing new.
- Full live suite passes (95 passed, 11 skipped).
- Docs description check and a strict docs build pass.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
