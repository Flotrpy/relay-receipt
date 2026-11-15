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

## Step-by-step parity

| # | api-relay-audit step | Receipt step | Status | What changed and why |
|---|---|---|---|---|
| 1 | Infrastructure recon: DNS, WHOIS, TLS certificate, HTTP headers, homepage preview | Infrastructure recon | changed | WHOIS is dropped (it needs an external binary or port 43 and adds little). DNS and TLS use OTP directly instead of shelling out. |
| 2 | Model list (connectivity is a separate `--connectivity` mode) | Connectivity | changed | Merged: lists models and checks which API format answers a minimal chat request. Later steps use the detected format. |
| 3 | Token injection: billed `input_tokens` minus a hard-coded expected value; `>100` red, `>20` yellow | Token injection (delta) | changed | Primary method compares billed prompt tokens with a trusted reference serving the same open-weight model, under the validity gates of [arXiv:2608.29930](https://arxiv.org/abs/2608.29930). The original fixed-estimate method is kept as a labelled fallback when no reference is configured. |
| 4 | Prompt extraction: three direct requests for the system prompt | Prompt extraction | same | Same intent, own wording. Structural and weak markers are kept as separate evidence grades. |
| 5 | Instruction override: "cat test" and a Claude identity override | Instruction override / identity self-report | changed | The adherence test is repeated and decided by majority, to avoid a verdict from one sampled reply. The identity part no longer assumes Claude: the self-reported family is compared with the claimed model and recorded as a consistency signal. |
| 6 | Jailbreak and role impersonation: three probes | Jailbreak resistance | same | Same intent, own wording. Advisory: it does not move the rating, as upstream. |
| 7 | Context length: five canaries, coarse scan then binary search up to 800K characters | Context truncation scan | changed | Same canary method. The ladder is sized by profile and by the claimed model's context window so that free-tier token limits are respected; sizes that hit a rate or size limit are inconclusive. |
| 8 | Tool-call package substitution: text echo of four pinned install commands | Tool-call substitution | changed | Keeps the text-echo probe and adds the structured tool-call probe that upstream lists as future work: the model is asked to call a tool with an exact command and the returned arguments are compared. |
| 9 | Error-response leakage: broken requests, scan body and headers | Error-response leakage | same | Same triggers and severity grades (critical / high / medium). No oversized-request probe by default. |
| 10 | Stream integrity: Anthropic SSE only; other formats are inconclusive | Stream (SSE) integrity | changed | Anthropic checks kept. An equivalent rule set for OpenAI-style streams is added so OpenAI-compatible relays are no longer always inconclusive. |
| 11 | Web3 prompt injection (profile `web3` / `full`) | not implemented | dropped | Reported as `not_applicable` in every profile. Wallet-safety probes are outside Receipt's scope. |
| 12 | Infrastructure fingerprint: three unauthenticated GETs matched against gateway signatures | Infrastructure fingerprint | same | Same method and confirmation rule (2 of 3 probes). Signature list is Receipt's own. |
| 13 | Latency variance: 10 identical probes, coefficient of variation and a gap-based bimodality rule | Latency variance | changed | Same probe plan and the same cut-offs, computed on a monotonic clock, with median and MAD reported next to mean and standard deviation. Still informational. |
| 14 | Upstream channel classifier: id prefixes and headers, three tiers | Upstream channel classifier | same | Same tiered idea; rules for the reference providers used in this project are added. Still informational. |
| 15 | none | Inflation probe | new | Saturation single-probe audit, [arXiv:2609.20370](https://arxiv.org/abs/2609.20370). See [steps/15-inflation.md](./steps/15-inflation.md). |
| 16 | none | Upstream map | new | CacheTracer Flood / Prove, [arXiv:2608.20732](https://arxiv.org/abs/2608.20732). See [steps/16-upstream-map.md](./steps/16-upstream-map.md). |
| 17 | none | Identity test | new | AgentProv and RUT with sequential early stopping. See [steps/17-identity.md](./steps/17-identity.md). |

## Things Receipt deliberately does not carry over

- **Agent-harness plugins and skills** (DSH, OpenClaw, Hermes). Receipt is a
  command-line tool only.
- **Community evidence registry and public site.** Receipt publishes no
  results about real providers (see the responsible-use rules in
  [THREAT_MODEL.md](./THREAT_MODEL.md)).
- **`--key` flag.** Keys come from the environment only.
- **Claude-specific assumptions** (thinking-signature checks as a required
  invariant, Claude self-identification as the expected answer). Where a
  check only makes sense for one vendor's format it is applied only when
  that format is in use.

## Expected disagreements in head-to-head runs

When both tools audit the same endpoint (Phase G), these differences are
expected by design and are not defects in either tool:

1. Step 3 can differ because the baselines differ (fixed estimate versus
   trusted reference).
2. Step 5 will differ on non-Claude models: upstream expects a Claude
   identity.
3. Step 10 will differ on OpenAI-compatible endpoints: upstream reports
   inconclusive, Receipt runs its OpenAI rule set.
4. The overall rating can differ whenever any of the above differ, and
   whenever Steps 15-17 report an anomaly.

Any other disagreement found in Phase G is documented with its cause in
`docs/VALIDATION.md`.
