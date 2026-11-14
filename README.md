# Receipt

[![CI](https://github.com/Flotrpy/relay-receipt/actions/workflows/ci.yml/badge.svg)](https://github.com/Flotrpy/relay-receipt/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue)](./LICENSE)
[![Gleam](https://img.shields.io/badge/Gleam-1.19-ffaff3?logo=gleam&logoColor=black)](https://gleam.run)
[![Erlang/OTP 27+](https://img.shields.io/badge/Erlang%2FOTP-27%2B-a90533?logo=erlang&logoColor=white)](https://www.erlang.org)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-fe5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org)

**A local security auditor for AI API relays** — the resellers, gateways and
proxies that sell access to large language models.

A relay sits between you and the model. It sees every request and response
in plaintext and can change them: add a hidden system prompt, serve a
cheaper model under the name you paid for, pad answers to bill more tokens,
rewrite the package names in an agent's install commands, or forward your
traffic through other relays. Receipt sends a fixed set of probes to an
endpoint you choose and writes down what it observed.

A report contains **signals, anomalies and inconclusive results**. It is
not a safety certificate.

```text
receipt audit --url https://relay.example/v1 --model qwen/qwen3.8-27b \
  --reference-url https://trusted-provider.example/v1 --reference-model qwen/qwen3.8-27b
```

## What it checks

Receipt keeps the 14-step design of
[api-relay-audit](https://github.com/toby-bridges/api-relay-audit) v2.5.0
(see [docs/PARITY.md](./docs/PARITY.md) for what changed) and adds three
statistical checks from 2026 research.

| # | Step | Looks for | Class |
|---|---|---|---|
| 1 | Infrastructure recon | DNS, TLS certificate, landing page | informational |
| 2 | Connectivity | which API format answers | informational |
| 3 | Token injection | extra billed prompt tokens versus a trusted reference ([arXiv:2608.29930](https://arxiv.org/abs/2608.29930) validity gates) | major |
| 4 | Prompt extraction | a prompt the user never sent, confirmed twice and cross-checked with the reference | major |
| 5 | Instruction override | a hidden prompt that outranks the caller's system prompt | major |
| 6 | Jailbreak resistance | the same, through indirect probes | advisory |
| 7 | Context truncation | markers lost at one end of a long input | major |
| 8 | Tool-call substitution | rewritten install commands, in text and in structured tool calls | critical |
| 9 | Error-response leakage | your key, upstream hosts, secrets, paths, stack traces in errors | critical |
| 10 | Stream integrity | broken SSE invariants, for OpenAI-style and Anthropic-style streams | critical |
| 12 | Infrastructure fingerprint | known gateway software | informational |
| 13 | Latency variance | two latency clusters (weak signal) | informational |
| 14 | Upstream channel | serving-channel markers | informational |
| **15** | **Inflation probe** | provider-side output lengthening, by the saturation audit of [arXiv:2609.20370](https://arxiv.org/abs/2609.20370) | major |
| **16** | **Upstream map** | hidden shared backends between endpoints, by CacheTracer's Flood/Prove of [arXiv:2608.20732](https://arxiv.org/abs/2608.20732) | informational |
| **17** | **Identity test** | whether the endpoint serves the claimed model: tool-choice MMD ([arXiv:2609.00052](https://arxiv.org/abs/2609.00052)) plus rank uniformity ([arXiv:2506.06975](https://arxiv.org/abs/2506.06975)), with anytime-valid early stopping | major |

Step 11 (Web3 wallet probes) is not part of Receipt and is always reported
as `not_applicable`.

Every step returns a verdict (`clean`, `anomaly`, `inconclusive`,
`informational`) and a status (`run`, `skipped`, `profile_gated`,
`not_applicable`). The overall rating (`LOW`, `MEDIUM`, `HIGH`) follows a
fixed rule table in [docs/THRESHOLDS.md](./docs/THRESHOLDS.md). Every
cut-off was fixed before any real endpoint was tested; the few changes
made since are logged there with their reason.

## Example output

From [docs/examples/sample-report.md](./docs/examples/sample-report.md),
generated from a **synthetic** relay (a simulator with a hidden prompt and
one package rewrite, on reserved example domains):

```markdown
## Rating: HIGH

Rule 1 of the rating table matched.

- Step 8 (Tool-call substitution): anomaly in a critical step

| # | Step | Status | Verdict | Summary |
| --- | --- | --- | --- | --- |
| 3 | Token injection | run | inconclusive | The endpoint bills 87 more prompt tokens per request than the reference: more than a template difference usually explains, less than the anomaly cut-off. |
| 4 | Prompt extraction | run | anomaly (high) | A reply presents instruction-style text as the system prompt although none was sent: a signal of an added prompt. |
| 5 | Instruction override / identity self-report | run | anomaly (high) | The model did not follow a simple caller system instruction in 3 of 3 trials: a signal that something outranks the caller's system prompt. |
| 8 | Tool-call substitution | run | anomaly (high) | 1 of 6 pinned commands came back changed in two attempts: a signal of rewriting on the return path. |
| 15 | Inflation probe | run | clean | No PTIA-consistent signal: S = 0 (threshold 3) over 20 valid question pairs. |
| 17 | Identity test | run | clean | same: not distinguished from the trusted reference after 2 batch(es) (E = 0.445). |
```

The full report has one section per step with what was sent, what came
back, the rule applied and, for statistical steps, the error rate. The same
content is available as JSON (`--format json`, schema in
[docs/REPORT_SCHEMA.md](./docs/REPORT_SCHEMA.md)).

## Validation

Full method, every run and every caveat:
[docs/VALIDATION.md](./docs/VALIDATION.md). In short:

**Test bed.** A local evil relay in front of real free-tier models, one
fault at a time, one run per condition (case reports, not rates).
Inconclusive is counted on its own, never as clean.

| Step | Aimed at | TP | FN | Inconclusive (fault) | FP | TN | Inconclusive (honest) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3 Token injection | hidden prompt | 1 | 0 | 0 | 0 | 1 | 0 |
| 4 Prompt extraction | hidden prompt | 0 | 1 | 0 | 0 | 1 | 0 |
| 5 Instruction override | hidden prompt | 0 | 1 | 0 | 0 | 1 | 0 |
| 6 Jailbreak resistance | hidden prompt | 0 | 1 | 0 | 0 | 0 | 1 |
| 8 Tool-call substitution | package rewriting | 1 | 0 | 0 | 0 | 1 | 0 |
| 9 Error leakage | (honest relay only) | – | – | – | 1 | 0 | 0 |
| 10 Stream integrity | (honest relay only) | – | – | – | 0 | 1 | 0 |
| 15 Inflation probe | billed padding | 1 | 0 | 0 | 0 | 1 | 0 |
| 17 Identity test | model swap | 1 | 0 | 0 | 0 | 1 | 1 |

The Step 9 false positive is a real header the unmodified LiteLLM gateway
returns. Step 17 on the honest relay was run twice: the first run ran out
of free quota and correctly said "insufficient data" rather than "same";
the re-run on a fresh quota said "same" (E = 0.385). Both are counted.

**Simulator.** 200 seeded runs each: Step 15 raised no false positives and
caught 98–100% of 25–100% inflation; Step 17 raised no false positives and
caught every swapped model. Step 16 got 7 of 8 synthetic topologies right
with the paper's preset, and the eighth was "unknown", never wrong.

**Head-to-head with api-relay-audit v2.5.0.** Both caught the hidden
prompt by token count and the package rewrite. On the honest relay,
api-relay-audit raised red flags for prompt extraction (an invented
prompt), stream integrity (a gateway translation artefact) and, once,
package rewriting (an empty reply); Receipt raised none of those, and
flagged the gateway's header in Step 9.

**Honest controls.** Directly against a hosted provider, Receipt raised no
anomaly; two prompt-leak steps were inconclusive on a small model's weak
replies, so the rating was MEDIUM, not LOW. Through the gateway, the only
anomaly was the gateway's own header.

## What it does not claim

- **It is not a safety certificate.** A relay that passes has passed these
  probes, on these requests, at this time. A relay can behave differently
  on traffic it recognises as an audit, or on a small share of requests.
- **An anomaly is not proof.** It says a pre-registered rule fired. It does
  not say who did it, how, or whether it was deliberate.
- **Inconclusive is never clean.** Blocked probes, missing usage fields and
  rate limits are reported as inconclusive and raise the rating.
- **Reported numbers are the relay's numbers.** Token counts, cached-token
  counts, model names and headers are whatever the endpoint returned.
- **Misreported hidden reasoning tokens cannot be detected black-box.**
  Auditing reported token counts needs model access
  ([arXiv:2510.05181](https://arxiv.org/abs/2510.05181)), and audits that
  rely on evidence the provider supplies can be evaded
  ([arXiv:2605.30040](https://arxiv.org/abs/2605.30040)). Step 15 only sees
  output that is visibly longer.
- **The trusted reference is trusted by assumption.** Steps 3 and 17
  compare with it; if it changes, they blame the relay.
- **The upstream map is an under-approximation.** An endpoint that reports
  no cached tokens removes itself from the map; a missing relation is
  unknown, not absent. A relation shows shared cache reach, not who
  supplies whom.

The full list, per step, is in [docs/THREAT_MODEL.md](./docs/THREAT_MODEL.md).

## Install

Receipt is a single escript. It needs Erlang/OTP 27 or newer.

There is no published release yet, so build it from source. You also
need [Gleam](https://gleam.run) 1.19 or newer:

```bash
git clone https://github.com/Flotrpy/relay-receipt && cd relay-receipt
```

```bash
gleam run -m gleescript
```

## Usage

The key is read from an environment variable. There is no option that
takes a key, so it never appears in your shell history or process list.

```bash
export RECEIPT_API_KEY=...        # key for the relay
export RECEIPT_REFERENCE_KEY=...  # key for the trusted reference (optional)
```

```bash
receipt audit --url https://relay.example/v1 --model <model> --output report.md
```

Common options:

| Option | Meaning |
|---|---|
| `--reference-url`, `--reference-model` | A trusted provider serving the same model. Enables the reference method of Step 3 and Step 17. |
| `--profile full` | Run everything, including Step 16 and the longer ladders. |
| `--endpoint NAME=URL,MODEL,KEY_VAR` | Another endpoint for Step 16 (repeatable). |
| `--format json` | JSON report, schema version 1. |
| `--record trace.jsonl` / `--replay trace.jsonl` | Record every exchange (keys redacted), or rerun an audit offline from a recording. |
| `--only 3,8,15` / `--skip 7` | Choose steps. Step 2 still runs to detect the API format unless `--api-format` is given. |
| `--rpm 10` | Requests per minute per endpoint (default 20). |
| `--fail-on MEDIUM` | Exit 3 at or above a rating, for automation. |

Run `receipt help` for the full list. Exit codes: 0 report written, 1 could
not run, 2 replay failed, 3 `--fail-on` reached.

Audit only endpoints you are a customer of, with your own key, at rates
their terms allow. Do not publish findings that name a provider without
contacting them first; see [SECURITY.md](./SECURITY.md).

## How it is built

- Gleam on the BEAM ([ADR 0001](./docs/adr/0001-stack.md)), with two thin
  Erlang shims over OTP for HTTP with per-chunk timing and for DNS / TLS
  ([ADR 0002](./docs/adr/0002-http-ffi.md),
  [ADR 0003](./docs/adr/0003-dns-tls-ffi.md)).
- Monotonic clock for all timing; seeded randomness so a recorded trace
  replays to the same report ([docs/TRACE_FORMAT.md](./docs/TRACE_FORMAT.md)).
- Statistics written for this project and property-tested: Wilson
  intervals, Holm correction, binomial thresholds, MMD permutation test,
  Cramér-von Mises, e-values.
- Design documents were written before code:
  [threat model](./docs/THREAT_MODEL.md),
  [Step 15](./docs/steps/15-inflation.md),
  [Step 16](./docs/steps/16-upstream-map.md),
  [Step 17](./docs/steps/17-identity.md),
  [thresholds](./docs/THRESHOLDS.md).

## License

AGPL-3.0-only. See [LICENSE](./LICENSE). Research references are listed in
[docs/REFERENCES.md](./docs/REFERENCES.md).
