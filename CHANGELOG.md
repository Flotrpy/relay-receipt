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

### Phase D: statistics library

Built before the parity steps because several of them use it.

- `stats/descriptive`: mean, variance, standard deviation, CV, quantiles.
- `stats/robust`: MAD, IQR, robust CV, trimmed mean, widest-gap bimodality.
- `stats/normal`: standard normal CDF and quantile.
- `stats/wilson`: Wilson score interval; reproduces the intervals published
  in arXiv:2608.29930.
- `stats/binomial`: binomial tails and the Step 16 threshold formulas;
  reproduces every value published in arXiv:2608.20732.
- `stats/holm`: Holm step-down correction.
- `stats/permutation`, `stats/mmd`: Monte Carlo p-values and the AgentProv
  MMD permutation test.
- `stats/cvm`, `stats/rut`: Cramér-von Mises uniformity test and the
  black-box rank-uniformity construction.
- `stats/evalue`: p-to-e calibration, products and means of e-values, with
  a simulation of Ville's inequality.
- Property and simulation tests throughout: p-values valid under the null,
  family-wise error controlled, ranks uniform under exchangeability.

### Phase C: parity steps 1-14

- Trace format gains `observation` lines so DNS and TLS lookups replay.
- ADR 0003 and the DNS / TLS certificate shim.
- Step 1 infrastructure recon, Step 2 connectivity and format detection.
- Step 3 token injection: validity-gated comparison with a trusted
  reference (arXiv:2608.29930), with the fixed-estimate fallback.
- Step 4 prompt extraction with a reference cross-check; Step 6 advisory
  jailbreak probes; shared leak grading.
- Step 5 instruction override by majority of three trials, plus identity
  self-report as a consistency signal.
- Step 7 context truncation scan with positional confirmation.
- Step 8 tool-call substitution, text and structured tool calls.
- Step 9 error-response leakage with redacted evidence.
- Step 10 stream integrity for OpenAI-style and Anthropic-style streams.
- Step 12 fingerprint, Step 13 latency variance, Step 14 channel
  classifier (all informational).
- Step 11 (Web3) reported as `not_applicable`.
- Rating rule 5 extended: a run in which no rated step ran is `MEDIUM`.
- A simulated relay with switchable faults for step tests, and an
  end-to-end test that a recorded run replays to an identical report.

### Phase E: new steps 15, 16 and 17

- Step 15 inflation probe: Algorithm 1 of arXiv:2609.20370 with the
  paper's parameters, block-wise early stopping, validity rules and the
  two mandatory limit statements.
- Step 16 upstream map: thresholds derived from delta and alpha, Flood and
  Prove state machines, prefix ladder, pair classification, implication
  pruning, Mermaid graph and adjacency list; a cache simulator with known
  topology for tests.
- Step 17 identity test: tool-choice templates, everyday prompts, batch
  MMD permutation and rank-uniformity tests, e-value accumulation with
  early stopping, per-template Holm-adjusted diagnostics.
- Changes made after a smoke test on an honest endpoint, each logged in
  `docs/THRESHOLDS.md`: probes leave room for reasoning tokens, an empty
  reply is not judged in Step 5, structural leaks in Steps 4 and 6 need
  confirmation, and replies that match the trusted reference are not
  attributed to the endpoint.

### Phase F: test bed

- LiteLLM gateway configuration (configuration only) in front of free
  hosted inference tiers.
- The evil relay, in Gleam, with five switchable conditions: none, hidden
  prompt, billed padding, hidden model swap, package rewriting.
- `testbed/run.sh` driving matrices of runs with fixed seeds and a trusted
  reference; a confusion-matrix builder that never counts inconclusive as
  clean and does not count off-target anomalies as false positives.
- Head-to-head mode against api-relay-audit v2.5.0.

### Phase G: validation

- `docs/VALIDATION.md`: test-bed confusion matrices for Steps 3–10 and 15
  and for Step 17; Step 16 on a shared gateway; simulator rates for Steps
  15 and 17 and synthetic topologies for Step 16; honest controls; a
  head-to-head with api-relay-audit v2.5.0 with every disagreement
  explained; a comparison with the papers' numbers.
- Validation summary in the README.
- No threshold was changed in response to a validation result.

### Phase H: polish

- Full README, CONTRIBUTING.md, SECURITY.md, test-bed README.
- CI on GitHub Actions: formatting, build, all tests, escript build,
  end-to-end replay of the synthetic sample trace, test-bed tests.
- Tag-triggered release workflow publishing the escript and its checksum.
- Synthetic sample trace and report with a replay test.
- Simulation and topology tools for the validation document.

### Fixed during validation

- Step 15 now states the paper's worst-case false-positive rate (7.30%)
  as its bound rather than an average.
- The simulated relay uses independent random rolls (test-only fix).
- A test key that collided with a controlled text broke trace replay of
  one request; the redaction limit is documented.
- Test bed: the hidden-prompt fault now also reaches Anthropic-style
  `/messages` requests, and requests are compacted before any fault is
  applied. Both bugs hid the faults from api-relay-audit, which sends
  spaced JSON and prefers `/messages`; the head-to-head was re-run.
  Receipt's own runs were unaffected (compact JSON, chat endpoint).
