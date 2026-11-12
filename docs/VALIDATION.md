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
