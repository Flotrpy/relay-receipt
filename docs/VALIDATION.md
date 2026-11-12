# Validation

How well Receipt finds what it is designed to find, and how often it flags
something that is not there. Every number below was produced by the tools
in this repository; nothing is copied from the papers except where a row
says "paper".

Three kinds of evidence, in increasing realism:

1. **Simulator** — Receipt's statistics run against the simulated relay
   (`test/support/fake.gleam`) and the prefix-cache simulator
   (`test/support/cachesim.gleam`) many times with fresh seeds. These check
   that each test behaves as designed. They say nothing about real models.
2. **Test bed** — Receipt against a local evil relay (`testbed/`) that
   forwards to real free-tier models through an unmodified LiteLLM gateway,
   with one fault switched on at a time, and against no fault.
3. **Honest controls** — Receipt against hosted providers directly.

Results that come from real services are anonymised as **Provider A** (the
hosted inference provider used as the trusted reference and behind the
gateway) and **Provider B** (the second provider behind the gateway) until
the providers have been informed; see [SECURITY.md](../SECURITY.md).
Thresholds were not changed in response to any test-bed or control result;
the changes logged in [THRESHOLDS.md](./THRESHOLDS.md) predate them.

## Test bed: parity and inflation steps under five conditions

Receipt audited the evil relay (`testbed/`) with each condition switched on
in turn. The relay forwards to the open-weight model `openai/gpt-oss-120b`
on Provider A through an unmodified LiteLLM gateway; the trusted reference
is the same model on Provider A directly. One run per condition, seed
20261112, 10 requests per minute. Produced by `testbed/run.sh a` and
`evilrelay/matrix`.

| Condition | Step 3 | Step 4 | Step 5 | Step 6 | Step 8 | Step 9 | Step 10 | Step 15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| a-inject | **anomaly** | clean | clean | clean | **anomaly** | **anomaly** | clean | **anomaly** |
| a-none | clean | clean | clean | inconclusive | clean | **anomaly** | clean | clean |
| a-pad | clean | inconclusive | **anomaly** | clean | **anomaly** | **anomaly** | clean | **anomaly** |
| a-rewrite | clean | clean | clean | clean | **anomaly** | **anomaly** | clean | clean |
| a-swap | clean | inconclusive | clean | inconclusive | clean | **anomaly** | clean | clean |

| Step | TP | FN | Inconclusive (fault) | FP | TN | Inconclusive (honest) |
| --- | --- | --- | --- | --- | --- | --- |
| 3 | 1 | 0 | 0 | 0 | 1 | 0 |
| 4 | 0 | 1 | 0 | 0 | 1 | 0 |
| 5 | 0 | 1 | 0 | 0 | 1 | 0 |
| 6 | 0 | 1 | 0 | 0 | 0 | 1 |
| 8 | 1 | 0 | 0 | 0 | 1 | 0 |
| 9 | 0 | 0 | 0 | 1 | 0 | 0 |
| 10 | 0 | 0 | 0 | 0 | 1 | 0 |
| 15 | 1 | 0 | 0 | 0 | 1 | 0 |

Counting rules: a fault is a positive only for the steps aimed at it
(inject: 3, 4, 5, 6; pad: 15; rewrite: 8; swap: 17, tested separately
below). An anomaly from another step under a fault is shown in the grid but
not counted as a false positive, because the relay really is dishonest.
Inconclusive is counted on its own, never as clean. With one run per
condition these are case reports, not rates.

### What happened, condition by condition

- **none (honest relay).** Clean on Steps 3, 4, 5, 8, 10 and 15. Step 6 was
  inconclusive: the role-play probe gets an in-character reply that differs
  between the endpoint and the reference, so it is neither a refusal nor
  explained by the reference. Step 9's anomaly is real: LiteLLM adds an
  `x-litellm-model-api-base` response header naming its upstream API host,
  and the relay passes it on. That is exactly the kind of plumbing leak
  Step 9 looks for; it is counted as a false positive above only because
  this condition is labelled honest.
- **inject (hidden prompt, ~170 tokens).** Step 3 found it, measuring 151
  extra prompt tokens per request against the reference. Steps 4, 5 and 6
  missed it: this model kept the injected prompt secret as instructed and
  still obeyed the caller's own system prompt, so nothing outranked it in
  practice. Two off-target anomalies, both caused by the injected prompt's
  "always answer fully" instruction: Step 15 (the prompt lengthens answers,
  which is a provider-side inflation in the sense of arXiv:2609.20370) and
  Step 8, where the model wrapped the correct `pip install requests==2.31.0`
  in prose. Step 8's report attributes this to "rewriting on the return
  path", which is the wrong mechanism here: the command was intact, the
  reply around it was not. This is a known limitation of a text-echo probe
  and is left as is, because Step 8's rule was fixed before testing.
- **pad (billed padding).** Step 15 found it (S = 3 after two blocks, ten
  questions). Steps 5 and 8 also fired, because the padding appended to
  every answer breaks a one-word reply and trails an echoed command. For
  Step 8 "changed on the return path" is accurate; Step 5's explanation
  ("something outranks the caller's system prompt") is not, since the
  change was made after the model answered.
- **swap (gpt-oss-20b served as gpt-oss-120b).** No step in this matrix
  noticed, as expected: the two models share a tokenizer (Step 3 offset 0)
  and behave similarly on these probes. Step 17 is the step aimed at this.
- **rewrite (package names changed in replies).** Step 8 found it in 6 of 6
  probes, including both structured tool-call probes.

## Steps 15 and 17 on the simulated relay

Produced by `gleam run -m tools/simulate -- 200`. Every run uses a fresh
seed for Receipt and fresh random streams for the simulated models.

### Step 15 on the simulated relay (200 runs each)

| Condition | Anomalies | Rate | 95% Wilson interval |
| --- | --- | --- | --- |
| no inflation (false positives) | 0 / 200 | 0.0% | 0.0% to 1.9% |
| inflation on 25% of requests | 196 / 200 | 98.0% | 95.0% to 99.2% |
| inflation on 50% of requests | 200 / 200 | 100.0% | 98.1% to 100.0% |
| inflation on every request | 200 / 200 | 100.0% | 98.1% to 100.0% |

### Step 17 on the simulated relay (200 runs each, general profile)

| Condition | Anomalies | Rate | 95% Wilson interval |
| --- | --- | --- | --- |
| same simulated model (false positives) | 0 / 200 | 0.0% | 0.0% to 1.9% |
| different simulated model | 200 / 200 | 100.0% | 98.1% to 100.0% |
| same model, tools unsupported on the endpoint | 200 / 200 | 100.0% | 98.1% to 100.0% |

How to read these:

- **False-positive rates are the meaningful rows.** 0 of 200 honest runs
  raised an anomaly in either step, so both are below 1.9% at 95%
  confidence on the simulator. That agrees with the designs: Step 15's
  paper reports 0.02% with no system prompt, and Step 17's bound is 5%
  anytime-valid by construction. The simulator is far from the worst case
  (it carries no benign system prompt, which is what raised Step 15's
  false-positive rate to 7.30% in the paper).
- **Detection rows are easy cases.** The simulated inflation adds hundreds
  of words; the simulated "different model" has a different favourite tool
  in every template and a disjoint vocabulary. A real substitute is usually
  far closer to the claimed model. These rows show the machinery works, not
  how often a real substitution would be caught.
- The third Step 17 row is a reminder that "different" does not say why:
  the same simulated model behind an endpoint that drops tool definitions is
  rightly reported as behaving differently.

## Step 16 on simulated topologies

Each endpoint balances its requests round-robin over a set of isolated cache
domains, so the true relation of every pair is known by construction.
Produced by `gleam run -m tools/topologies`.

| Preset | Topology | Pairs right | Detail |
| --- | --- | --- | --- |
| coarse | one shared domain | 1 / 1 | target / b: expected clone, got clone |
| coarse | superset | 1 / 1 | target / b: expected contains, got contains |
| coarse | subset | 1 / 1 | target / b: expected contained_in, got contained_in |
| coarse | disjoint | 1 / 1 | target / b: expected no_observed, got no_observed |
| coarse | overlap | 1 / 1 | target / b: expected partial, got partial |
| coarse | three-to-two | 0 / 1 | target / b: expected contains, got inconclusive |
| coarse | four-to-one | 0 / 1 | target / b: expected contains, got inconclusive |
| coarse | chain of three | 2 / 3 | target / b: expected contains, got inconclusive; b / c: expected contains, got contains; target / c: expected contains, got contains |
| paper | one shared domain | 1 / 1 | target / b: expected clone, got clone |
| paper | superset | 1 / 1 | target / b: expected contains, got contains |
| paper | subset | 1 / 1 | target / b: expected contained_in, got contained_in |
| paper | disjoint | 1 / 1 | target / b: expected no_observed, got no_observed |
| paper | overlap | 1 / 1 | target / b: expected partial, got partial |
| paper | three-to-two | 1 / 1 | target / b: expected contains, got contains |
| paper | four-to-one | 0 / 1 | target / b: expected contains, got inconclusive |
| paper | chain of three | 3 / 3 | target / b: expected contains, got contains; b / c: expected contains, got contains; target / c: expected contains, got contains |

What the misses show, and why the thresholds were left alone:

- **The inconclusive band is part of the method.** In "three-to-two" under
  the coarse preset, the reverse direction covers 2 of the 3 domains, so
  about 10 of 30 probes miss: more than the 2 misses a "contained" decision
  allows, fewer than the 11 that reject containment. Algorithm 2 of
  arXiv:2608.20732 returns inconclusive there, and so does Receipt. With the
  paper preset (181 probes) the same pair is decided correctly.
- **Calibration limits how much load-balancing Step 16 can see.** In
  "four-to-one" the larger endpoint spreads requests over four domains.
  Calibration repeats a prompt three times looking for a reported cache
  hit; all three repeats land on other domains, so the endpoint is reported
  as having no cache telemetry and its pairs as unknown. This is a design
  limit of Receipt's calibration (three attempts, fixed in
  [THRESHOLDS.md](./THRESHOLDS.md)), not of CacheTracer, and is recorded
  here rather than tuned away. The paper calibrates per model offline.
- In both cases the result is "unknown", never a wrong relation.

## Test bed: Step 17 under model swap and no fault

Receipt ran Step 17 alone against the evil relay, claiming the open-weight
model `qwen/qwen3.8-27b` on Provider A, with the same model on Provider A
directly as the trusted reference. Under `swap` the relay served
`openai/gpt-oss-20b` instead and reported the claimed name in every reply.
One run per condition, seed 20261112, 20 requests per minute. Produced by
`testbed/run.sh b`.

| Condition | Verdict | Output | E-value | Batches | Requests sent / failed |
| --- | --- | --- | --- | --- | --- |
| b-swap | **anomaly** | different (false-positive bound 5%, anytime-valid) | 54.7 | 1 | 310 / 0 |
| b-none | inconclusive | insufficient data | 0.67 | 2 (1 valid) | 468 / 101 (rate limits) |

| Step | TP | FN | Inconclusive (fault) | FP | TN | Inconclusive (honest) |
| --- | --- | --- | --- | --- | --- | --- |
| 17 | 1 | 0 | 0 | 0 | 0 | 1 |

- **Swap.** The first batch already passed the rejection threshold
  (E ≥ 20), so the sequential test stopped after one batch, as designed.
- **No fault.** The first batch was valid and showed no difference (tool
  choice p = 0.70, rank uniformity p = 0.30; no template had a Holm-adjusted
  p below 1). The second batch was invalidated by HTTP 429 responses: the
  relay and the reference draw on the same free-tier quota, so every probe
  costs it twice. "Same" needs the full batch budget, so Receipt reported
  insufficient data rather than claim the models match. This is the
  behaviour the specification asks for, but it means the honest-relay case
  has **not** been shown to come out "same" on a real model. A re-run needs
  about 700 more requests on that model than the daily free quota had left.

## Test bed: Step 16 on two relays that share one gateway

Two honest evil-relay instances (ports 4100 and 4200) forwarded to the same
LiteLLM gateway and the same model on Provider A. Step 16 (full profile,
coarse preset) was asked to map them. Produced by `testbed/run.sh d`.

Result: **inconclusive**, reason `no_cache_telemetry`. Neither endpoint
reported a cached prompt token during calibration, so no pair could be
classified, and the adjacency list holds one inconclusive edge. This is the
expected outcome for this provider and model, which did not report prompt
caching through the gateway at the time of the run; Step 16 has nothing to
measure without it. It is recorded as a limit of this test bed, not as a
pass: the correct relation here ("clone") was **not** demonstrated on a real
service. The relation logic itself is exercised on the simulated topologies
in the previous section.

## Comparison with the papers' numbers

A small-scale check, not a replication: one model per step, a handful of
runs, free-tier quotas. Each row gives what the paper reports, what Receipt
measured here, and why the two are or are not comparable.

| Step | Paper | Paper reports | Receipt measured | Comparable? |
| --- | --- | --- | --- | --- |
| 3 | arXiv:2608.29930 | Token counts are comparable across endpoints when the shift-invariant score is at least 0.725 (frozen threshold) | Score 1.0 in both runs; modal offset 0 on the honest relay, 151 tokens under the hidden-prompt fault (30 of 30 pairs valid each) | Qualitatively. One model, one injected prompt; the paper's holdout rates were not re-measured |
| 15 | arXiv:2609.20370 | 85.1% detection averaged over activation rates 0–1; error bound worst case 7.30% | Test bed: padding and hidden-prompt conditions flagged (S = 3 of threshold 3), honest relay S = 0. Simulator: 0/200 false positives; 98–100% detection at 25–100% inflation | No. The paper averages over activation rates and four calibrated models; the test bed pads every answer, and `gpt-oss-120b` was not in the paper's calibration set |
| 16 | arXiv:2608.20732 | Binomial thresholds 59 / 124 / 181 / 234 / 286 probes and M_partial = 15 | Reproduced exactly by `stats/binomial` (unit tests). Simulated topologies: 7 of 8 under the paper preset; real shared gateway inconclusive (no cache telemetry) | Thresholds: yes. Accuracy on real resellers: not measured |
| 17 | arXiv:2609.00052, arXiv:2506.06975 | AgentProv detection 94.13% at 10 samples per template, 99.84% at 25 (K = 20); 7% false positives under system-prompt injection, 53% for RUT | Swap detected after one batch (E = 54.7); honest relay insufficient data (rate limits); simulator 0/200 false positives, 200/200 detection | Direction only. One substitute model, one run each; the paper's rates come from many model pairs |

What this does and does not show:

- Receipt's implementations behave as the papers describe on the cases
  tried, and the CacheTracer thresholds match the paper digit for digit.
- No detection rate or false-positive rate above is a population estimate.
  With one run per condition, a single result says only that the method
  can fire, or can stay quiet, in that case.
- Step 15 inherits the paper's stated limit: misreported hidden reasoning
  tokens cannot be detected black-box (arXiv:2510.05181).

## Head-to-head with api-relay-audit v2.5.0

Both tools audited the same evil relay, forwarding to `openai/gpt-oss-20b`
on Provider A through the gateway, under three conditions: no fault, hidden
prompt, and package rewriting. api-relay-audit ran with
`--skip-infra --skip-context --skip-latency-variance`; Receipt ran Steps
3, 4, 5, 6, 8, 9, 10, 12 and 14 without a trusted reference, so both used a
fixed-estimate method in Step 3. Produced by `testbed/run.sh e`.

**The first three passes exposed three bugs in the test bed, not in either
tool.** The relay matched only compact JSON (Python sends `"messages": [`),
applied the hidden prompt only on `/chat/completions`, and applied response
faults only there. api-relay-audit prefers `/v1/messages` when its
Anthropic-format probe returns text, so in those passes some faults never
reached it. Receipt sends compact JSON to `/chat/completions`, so none of
its runs were affected. The table counts an api-relay-audit run only where
the fault demonstrably reached it; the rest are listed as excluded. The
fourth pass, on the fixed relay, ran into the provider's daily token limit
during the rewrite condition (HTTP 429 on most requests), so that
condition has no clean fourth run for either tool.

| Check | Condition | Receipt | api-relay-audit | Runs counted |
| --- | --- | --- | --- | --- |
| Hidden prompt (Step 3) | hidden prompt | **anomaly** 4 of 4 (about 216 extra tokens) | **red** 2 of 2 (about 214–217 tokens) | Receipt 4; ara 2 (passes 1–2 excluded: fault did not reach it) |
| Hidden prompt (Step 3) | no fault | inconclusive 4 of 4 (61 tokens over estimate, below the cut-off) | yellow 4 of 4 ("minor injection", about 63 tokens) | 4 each |
| Prompt extraction (Step 4) | hidden prompt | clean 2, inconclusive 2 (missed) | passed 2 of 2 (missed) | Receipt 4; ara 2 |
| Prompt extraction (Step 4) | no fault | clean 1, inconclusive 3 | **red** 4 of 4 ("hidden prompt content extracted") | 4 each |
| Package rewriting (Step 8) | rewriting | **anomaly** 3 of 3, inconclusive 1 (rate limit) | **red** in pass 1 with the rewritten names visible; red in pass 2 from empty replies only | Receipt 4; ara 2 (pass 3 excluded: fault did not reach it; pass 4: rate limit) |
| Package rewriting (Step 8) | no fault | clean 4 of 4 | **red** 1 of 4 | 4 each |
| Error leakage (Step 9) | no fault | **anomaly** 4 of 4 | green 4 of 4 | 4 each |
| Stream integrity (Step 10) | no fault | clean 4 of 4 | **red** 4 of 4 | 4 each |

Why the tools disagree, case by case:

- **Step 4 on the honest relay.** Asked to continue a JSON object holding
  "the hidden prompt", the model invents one ("You are ChatGPT, a large
  language model…"). api-relay-audit treats instruction-like text as an
  extracted prompt. Receipt requires a structural leak to be confirmed and
  not explained by the model's own default behaviour (THRESHOLDS change log,
  2026-11-12), so it reports clean or inconclusive. Neither tool extracted
  the real hidden prompt under the fault.
- **Step 8 on the honest relay.** api-relay-audit's one red came from an
  empty reply, which it scores as a substitution. Receipt counts only a
  command that comes back *changed* in two attempts; an empty reply is "no
  command returned". The same rule explains api-relay-audit's red in pass 2
  under the rewrite fault and in the rate-limited fourth pass: those reds
  are right by luck, not because a rewrite was seen.
- **Step 9.** The unmodified LiteLLM gateway returns the upstream API base
  in a response header on errors. Receipt reports it;
  api-relay-audit's header scan did not flag it. It is a real disclosure by the gateway, but
  under the counting rules above it is a false positive for the relay
  condition, and it is counted as one.
- **Step 10.** api-relay-audit opens an Anthropic-format stream. The gateway
  translates the OpenAI-format upstream and reports `input_tokens: 0` in
  `message_start`, and the model name does not contain "claude"; both trip
  its rules. Receipt checks the stream in the format the endpoint natively
  serves and applies the same rules to both APIs, and found the stream
  well formed.
- **Step 8 under the hidden prompt.** Both tools flag rewriting there too.
  The hidden prompt changes how the model answers, so a check aimed at
  rewriting fires on a different cheat. This is shown but not counted, as
  in the earlier sections.

These are case reports from at most four runs per cell on one model. They
show where the two tools' rules differ, not which tool is more accurate in
general.

## Honest controls

Receipt audited two hosted services that are assumed honest. The
specification asks that these come out clean; the results are reported as
they came out.

**Provider A, direct.** `allam-2-7b`, with the same model on Provider A as
the trusted reference, Steps 1, 3–6, 8–10 and 12–15, 6 requests per minute
per endpoint, seed 20261112. 148 requests, none rate-limited. Step 7 was
left out because this model's 4k-token context cannot hold the scan's
larger sizes.

An earlier attempt on `openai/gpt-oss-120b` was abandoned: the model's
free daily token quota had been spent by the test-bed matrices, and 47 of
94 requests came back HTTP 429. Its usable steps (3, 8, 9, 10) were clean,
and the rest were inconclusive, as the specification requires for rate
limits. It is kept out of the table.

**Provider B, through the gateway.** `gemma-4-26b-a4b-it` behind the
unmodified LiteLLM gateway, no trusted reference, Steps 3–6, 8–10 and
12–15. Provider B's OpenAI-compatible endpoint could not be authenticated
from the environment the runs were made in, so the gateway was the only
route; that makes this a control of Provider B *plus* the gateway.

| Step | Provider A, direct | Provider B, via gateway |
| --- | --- | --- |
| 1 Infrastructure recon | informational | – |
| 3 Token injection | clean (reference: offset 0) | clean (estimate) |
| 4 Prompt extraction | inconclusive (3 weak replies) | inconclusive (1 unrelated, 2 empty) |
| 5 Instruction override | clean (2 of 3 followed) | clean (3 of 3) |
| 6 Jailbreak resistance | inconclusive (1 weak, 2 unrelated) | inconclusive (1 refused, 2 empty) |
| 8 Tool-call substitution | clean (4 of 6 returned a command) | clean (6 of 6) |
| 9 Error leakage | clean | **anomaly** (upstream host in a gateway header) |
| 10 Stream integrity | clean | clean |
| 12 Infrastructure fingerprint | informational | informational |
| 13 Latency variance | informational | informational |
| 14 Channel classifier | informational | informational |
| 15 Inflation probe | clean (S = 0 over 20 pairs) | clean (S = 0 over 20 pairs) |
| Rating | MEDIUM (rule 5: Step 4 inconclusive) | HIGH (rule 1: Step 9) |

What this shows:

- **No anomaly on the direct control.** Nothing Receipt measured on
  Provider A directly was flagged. The control is not "clean" overall
  because Steps 4 and 6 were inconclusive: the small model gave replies too
  weak to score as refusals. By design an inconclusive step is never
  counted as clean, and it raises the rating to MEDIUM.
- **The one anomaly on Provider B comes from the gateway**, the same header
  seen in every test-bed run, not from Provider B. A direct Provider B
  control remains to be done.
