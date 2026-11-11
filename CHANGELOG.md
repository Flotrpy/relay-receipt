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

### Phase B: core infrastructure

- Gleam project scaffold; `receipt` escript built with `gleescript`.
- Closed verdict, status, severity and class types; step result type whose
  constructors make "not run" imply "inconclusive".
- Step catalog and the first-match rating engine, with property tests for
  monotonicity and order independence.
- Environment-only key handling with redaction to a same-length stand-in.
- Seeded SplitMix64 generator for reproducible shuffles and permutations.
- Monotonic clock; UTC timestamps for reports.
- HTTP transport over OTP `httpc` (ADR 0002): TLS verification always on,
  proxy and CA from the environment, per-chunk arrival times.
- Incremental server-sent events parser, independent of chunk boundaries.
- OpenAI-compatible and Anthropic-compatible adapters behind one chat front.
- JSONL trace codec, redaction, recorder and strict replayer.
- Retry policy with full-jitter backoff; client with per-endpoint pacing,
  per-step request counts and rate-limit give-up.
- Configuration, profiles and a pure command-line parser that refuses keys
  as arguments.
- Report model with standing limits; JSON (schema v1) and Markdown
  reporters, with tests on report wording.
- Step runner with gating and per-step crash isolation.
- `receipt/thresholds`: one module of pre-registered cut-offs, checked
  against `docs/THRESHOLDS.md` by a test.
