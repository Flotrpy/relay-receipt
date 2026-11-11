# Changelog

All notable changes to Receipt are recorded here, one section per build
phase. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Phase A: design documents

- Repository scaffolding: license (AGPL-3.0-only), ignore rules, README stub.
- `docs/adr/0001-stack.md`: stack decision and Erlang FFI policy.
- `docs/THREAT_MODEL.md`: vocabulary, parties, relay capabilities, auditor
  observables, per-step coverage and general limits.
- `docs/REFERENCES.md`: reference list for every check.
- `docs/PARITY.md`: every api-relay-audit v2.5.0 step mapped to Receipt as
  same, changed or dropped.
- `docs/steps/15-inflation.md`, `16-upstream-map.md`, `17-identity.md`:
  design of the three new steps (paper basis, procedure, test, budget,
  early stopping, inconclusive conditions, known evasions).
- `docs/THRESHOLDS.md`: every cut-off and the rating rules, fixed before any
  endpoint is tested.
- `docs/TRACE_FORMAT.md`: JSONL record/replay format with mandatory key
  redaction.
- `docs/REPORT_SCHEMA.md`: JSON report schema v1 and Markdown layout.
