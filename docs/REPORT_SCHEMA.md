# Report schema

Receipt writes a Markdown report by default and a JSON report with
`--format json`. Both are produced from the same in-memory report, so they
never disagree.

Reports are local artefacts. They can contain private relay URLs and model
output and are not sanitised for publication.

## JSON report, schema version 1

One JSON document. With `--output`, it is written to the file and standard
output stays empty; without it, standard output holds exactly the document
and progress goes to standard error.

This schema is Receipt's own. It shares the idea and the version number
style of api-relay-audit's JSON report but is not interchangeable with it.

### Top level

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | integer | `1`. |
| `report_type` | string | `audit`. |
| `generated_at` | string | UTC time, RFC 3339. |
| `tool` | object | `{"name":"receipt","version":"..."}`. |
| `profile` | string | `general` or `full`. |
| `seed` | integer | Run seed. |
| `target` | endpoint | The audited endpoint. |
| `reference` | endpoint or `null` | The trusted reference, if configured. |
| `endpoints` | array of endpoint | Extra endpoints given for Step 16. |
| `risk_level` | string | `LOW`, `MEDIUM` or `HIGH`. |
| `rating` | object | `{"rule":3,"reasons":["..."]}`: which rule of [THRESHOLDS.md](./THRESHOLDS.md) matched, and why. |
| `steps` | array of step | Every step, in numeric order, including steps that did not run. |
| `coverage` | object | See below. |
| `limits` | array of string | Standing statements of what the report does not show. Always present. |

### `endpoint`

| Field | Type | Meaning |
|---|---|---|
| `name` | string | `target`, `reference`, or a user-given name. |
| `base_url` | string | As given by the user. |
| `model` | string | Model name requested. |
| `api_format` | string or `null` | `openai` or `anthropic`, as detected by Step 2. |

Keys never appear in a report.

### `step`

| Field | Type | Meaning |
|---|---|---|
| `id` | integer | Step number, 1 to 17. |
| `key` | string | Stable machine name, e.g. `token_injection`. |
| `title` | string | Human title. |
| `class` | string | `critical`, `major`, `advisory` or `informational`. |
| `status` | string | `run`, `skipped`, `profile_gated` or `not_applicable`. |
| `verdict` | string | `clean`, `anomaly`, `inconclusive` or `informational`. Always `inconclusive` when `status` is not `run`. |
| `severity` | string or `null` | `medium`, `high` or `critical` for an anomaly; otherwise `null`. |
| `summary` | string | One sentence. |
| `reason` | string or `null` | Machine-readable reason for an inconclusive verdict or a non-run status, e.g. `rate_limited`, `usage_missing`, `no_reference`. |
| `findings` | array | `{"level":"signal"|"note"|"limit","text":"..."}`. |
| `data` | object | Step-specific measurements. Stable keys are documented with each step. |
| `error_rate` | object or `null` | For statistical steps: `{"kind":"false_positive","bound":0.05,"basis":"..."}`. |
| `requests` | object | `{"sent":40,"failed":1}`. |
| `duration_ms` | integer | Monotonic duration of the step. |
| `crashed` | boolean | `true` if the step raised an error; its verdict is then `inconclusive`. |
| `references` | array of string | Paper identifiers the step is based on. |

Step-specific `data` for the new steps:

- **Step 15**: `n`, `valid_pairs`, `S`, `H`, `k`, `tau`, and `pairs`, a
  list of `{"question","probe","L0","L1","delta","R","score","valid"}`.
- **Step 16**: `preset`, `nodes`, `adjacency` (object: endpoint name to a
  list of `{"to","relation"}`), `directions` (list of
  `{"flood","probe","outcome","n","h","m"}`), `implied` (pairs skipped by
  transitivity), `inconclusive_pairs`.
- **Step 17**: `outcome` (`same`, `different`, `insufficient_data`),
  `e_value`, `e_tool_choice`, `e_rank_uniformity`, `threshold`, `batches`
  (list with each batch's p-values, e-values and validity), and
  `templates` (per-template distance and Holm-adjusted p-value).

### `coverage`

| Field | Type | Meaning |
|---|---|---|
| `not_run` | array | `{"id","status","reason"}` for each step whose status is not `run`. |
| `inconclusive` | array of integer | Steps that ran and were inconclusive. |
| `crashed` | array of integer | Steps that crashed. |

A step listed here is not evidence of clean behaviour.

## Markdown report

Sections, in order:

1. **Title and run facts**: target URL and model, profile, time, tool
   version, seed.
2. **Rating**: `LOW`, `MEDIUM` or `HIGH`, the rule that matched, and the
   reasons in words.
3. **Summary table**: one row per step with status, verdict and summary.
4. **Coverage**: steps that did not run, were inconclusive, or crashed.
5. **One section per step**, numbered as the step: what was sent, what was
   observed, the rule applied and the verdict. Step 16 includes a Mermaid
   graph; Step 17 states its error rate.
6. **What this report does not claim**: the `limits` list, always printed.

Wording rules, enforced by tests on the report text:

- a verdict of `anomaly` is described as a signal or an anomaly, never as
  proof, fraud or confirmation;
- `clean` is described as "no anomaly observed", never as safe;
- every `inconclusive` step is listed with its reason.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Audit completed and a report was written, whatever the rating. |
| 1 | The audit could not run (bad arguments, missing key, no connectivity). |
| 2 | A replay failed (`trace_miss` or unreadable trace). |

`--fail-on MEDIUM|HIGH` makes Receipt exit with code 3 when the rating is
at or above the given level, for use in automation.
