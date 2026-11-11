# Parity with api-relay-audit v2.5.0

Receipt keeps the system of
[toby-bridges/api-relay-audit](https://github.com/toby-bridges/api-relay-audit)
v2.5.0: a numbered step pipeline, the `general` and `full` profiles, a
Markdown report by default with a versioned JSON report for automation, a
`LOW` / `MEDIUM` / `HIGH` rating, inconclusive results that stay visible,
and the position that a report is not a safety certificate.

Receipt is a clean-room rewrite in Gleam. No source code or probe text is
copied. The probe *intent* of each step is kept; the wording is Receipt's
own.

## System-level parity

| Aspect | api-relay-audit v2.5.0 | Receipt | Status |
|---|---|---|---|
| Step pipeline | 14 numbered steps | 17 numbered steps (1-14 kept, 15-17 new) | same, extended |
| Profiles | `general` (default), `web3`, `full` | `general` (default), `full` | changed: no `web3` profile |
| Per-step result | coloured flags (`green` / `yellow` / `red`) plus per-step return values | typed verdict (`clean`, `anomaly`, `inconclusive`, `informational`) and status (`run`, `skipped`, `profile_gated`, `not_applicable`) on every step | changed: one vocabulary for all steps |
| Rating | 6-dimension matrix, first match wins | rule table over step classes, first match wins ([THRESHOLDS.md](./THRESHOLDS.md)) | same idea, extended to the new steps |
| Inconclusive handling | shown, raises rating to at least `MEDIUM` for matrix steps | shown, raises rating to at least `MEDIUM` for rated steps | same |
| Crash handling | a crashed step is recorded and the audit continues | same; a crashed step is `inconclusive` with the crash recorded | same |
| Markdown report | default | default | same |
| JSON report | `--format json`, `schema_version: 1`, embeds the Markdown | `--format json`, `schema_version: 1`, structured per-step objects ([REPORT_SCHEMA.md](./REPORT_SCHEMA.md)) | changed: Receipt's schema is its own v1, not interchangeable |
| API key | `--key` or `--key-env`; v2.5.0 keeps it out of `curl` arguments | environment variable only; there is no flag that takes a key | changed: stricter |
| API formats | Anthropic-compatible and OpenAI-compatible | same | same |
| Target models | assumes the route identifies as Claude | any model; identity is tested against a trusted reference, not against a fixed vendor | changed |
| Transport | Python stdlib with `curl` fallback | OTP `httpc` behind a recordable transport | changed |
| Record / replay | optional hash-only transparent log | full JSONL trace, replayable offline ([TRACE_FORMAT.md](./TRACE_FORMAT.md)) | changed |
