# Step 17: Identity test

Design document. Written before implementation; the implementation must
follow it. Cut-offs are repeated in [THRESHOLDS.md](../THRESHOLDS.md), which
is the authoritative copy.

## Paper basis

| Paper | Used for |
|---|---|
| Wang et al., *AgentProv: Auditing Agentic LLM API Providers via Tool-use Policy Probes*, [arXiv:2609.00052](https://arxiv.org/abs/2609.00052) | Component A: tool-choice fingerprint and MMD permutation test (Section 3, Algorithm 1). |
| Zhu et al., *Auditing Black-Box LLM APIs with a Rank-Based Uniformity Test*, [arXiv:2506.06975](https://arxiv.org/abs/2506.06975) | Component B: rank-uniformity test (Section 4.1). |
| Vovk and Wang, *E-values: Calibration, combination and applications*, Annals of Statistics 49(3), 2021 | p-to-e calibration and merging of e-values. |
| Ville's inequality (1939); see Ramdas et al., *Game-theoretic statistics and safe anytime-valid inference*, Statistical Science 38(4), 2023 | Validity of stopping early. |

## Claim

The endpoint claims to serve model `M`. A trusted reference provider serves
`M` too. If both really serve `M` in the same way, their responses to the
same probes are draws from the same distribution. Step 17 tests that
equality.

Output is one of:

| Outcome | Meaning | Verdict |
|---|---|---|
| `different` | The test rejected equality. The endpoint's behaviour differs from the reference's on these probes. | `anomaly` |
| `same` | The full budget was spent with enough valid data and equality was not rejected. | `clean` |
| `insufficient_data` | Not enough valid observations to decide. | `inconclusive` |

`different` does not say *why*: a different model, a quantized build, other
sampling settings or a hidden system prompt all make behaviour differ.
`same` means "not distinguished at this budget", not "proven identical".

## Raw signals

- **Component A.** For each request: the name of the tool the model called,
  read from the structured tool-call field (or "no call", or "malformed").
- **Component B.** For each request: the text of a short completion.

## Procedure

Both components run in **batches**. After every batch the sequential rule
below decides whether to stop.

### Component A: tool-choice distribution (AgentProv)

- `K = 20` built-in templates. Each has a neutral user request and four
  tools that do the same thing under different names, with identical
  descriptions and identical parameter schemas. Templates are written for
  Receipt in the style of the paper's Appendix A.2.
- Option set per template: the four tool names, `_no_call`, `_malformed`
  and `_other` (a tool name that was not offered).
- Controls from the paper: tool order is shuffled per sample with a
  deterministic seed; descriptions are length-matched; requests are worded
  without naming a product. Sample `j` of template `k` uses the same tool
  order on the endpoint and on the reference.
- Settings: temperature 0.7 (the paper's), `max_tokens = 256`, tool choice
  left to the model.
- One batch is `5` samples per template from the endpoint and `5` from the
  reference: 100 requests each.
- Fingerprint `phi`: for each template, the fraction of samples in each
  option. Statistic: `T = sum over templates of ||phi_ref_k - phi_tgt_k||^2`,
  the squared MMD under the delta kernel.
- Batch p-value: permutation test. Pool the batch's samples within each
  template, shuffle endpoint labels within the template keeping group
  sizes, recompute `T`; `B = 4999` permutations;
  `p = (1 + #{T_perm >= T_obs}) / (B + 1)`.

### Component B: rank uniformity (RUT), black-box variant

The paper scores each response with its log-rank under a locally run
reference model. Receipt has no local model, only a reference *API*, so it
keeps the paper's rank construction and test and replaces the score:

- One batch is `10` built-in everyday prompts. For each prompt: `1`
  completion from the endpoint and `m = 10` from the reference, at
  temperature 0.5 with at most 30 output tokens (the paper's settings).
- **Score.** For each of the `m + 1` responses to a prompt, the mean
  log-probability of its words under an add-one-smoothed unigram model
  estimated from the *other* `m` responses. Treating all `m + 1` responses
  alike is what makes the next step exact.
- **Rank.** With `g` reference scores below the endpoint's score and `t`
  equal to it, `r = (g + U * (t + 1)) / (m + 1)` with `U` uniform on
  `[0, 1]` from the run seed. If the endpoint and the reference serve the
  same distribution, the `m + 1` scores are exchangeable and `r` is exactly
  uniform on `[0, 1]`.
- **Batch p-value.** Cramér-von Mises statistic of the batch's ranks
  against the uniform distribution, as in the paper; its null distribution
  is simulated with `B = 4999` seeded draws;
  `p = (1 + #{w_sim >= w_obs}) / (B + 1)`.

This variant controls false positives exactly, for any score function. Its
power is lower than the paper's log-rank score and is reported as measured
in `docs/VALIDATION.md`, not assumed.

## Statistical test and null hypothesis

`H0`: for every probe, the endpoint's response distribution equals the
reference's.

Each batch uses fresh requests, so under `H0` each batch p-value is valid
given everything seen before it.

1. **Calibrate.** Each batch p-value becomes an e-value with
   `e(p) = (1 - p + p ln p) / (p (ln p)^2)` and `e(1) = 1/2`. This is the
   average of the calibrators `kappa * p^(kappa - 1)` over `kappa` in
   `[0, 1]`, so it needs no tuning.
2. **Accumulate.** Per component, multiply the e-values of its batches:
   `E_A`, `E_B`. A batch that fails its validity gate contributes `1`.
3. **Combine.** `E = (E_A + E_B) / 2`. The mean of two e-processes is an
   e-process, so no multiple-testing correction is needed between the
   components. A component that cannot run (for example the endpoint
   rejects tool definitions) stays at `1` and the report says so.
4. **Decide.** `different` as soon as `E >= 1 / alpha` with `alpha = 0.05`,
   that is `E >= 20`.

By Ville's inequality the probability that `E` ever reaches `20` under
`H0` is at most `0.05`, no matter when Receipt stops.

A per-template table (which templates moved most) is printed for
`different` results, with Holm-corrected p-values. It is a diagnostic only
and plays no part in the decision.

## Request budget

| | Endpoint | Reference |
|---|---|---|
| Component A, per batch | 100 | 100 |
| Component B, per batch | 10 | 100 |
| Per batch | 110 | 200 |

| Profile | Maximum batches | Samples per template (A) | Maximum requests (endpoint + reference) |
|---|---|---|---|
| `general` | 2 | 10 | 220 + 400 |
| `full` | 5 | 25 | 550 + 1000 |

The step is `not_applicable` when no reference is configured.

## Early-stopping rule

Stop with `different` at the first batch boundary where `E >= 20`.
Otherwise continue to the profile's maximum. There is no early stop for
`same`: equality cannot be accepted early.

## Reported error rate

- `different`: "false-positive rate at most 5% (anytime-valid)".
- `same`: the miss rate depends on how different a substitute is and cannot
  be bounded in general. The report quotes the detection rates the
  AgentProv paper measured for outright substitution at the same budget
  (Table 5, `K = 20`: 94.13% at 10 samples per template, 99.84% at 25) and
  labels them as the paper's, for component A only.

## Inconclusive conditions (`insufficient_data`)

- **Batch validity gates.** Component A: at least 4 of 5 valid samples per
  endpoint in at least 16 of 20 templates. Component B: at least 8 of 10
  prompts with an endpoint response and at least 8 of 10 reference
  responses each. A batch that fails contributes `1`.
- The run ends without `E >= 20` and with fewer than 2 valid batches in
  every component.
- The reference is unreachable or rate limited.
- The endpoint or the reference does not support the claimed model name.

A response that is not a tool call, or is malformed, is *data* for
component A (`_no_call`, `_malformed`), not a missing value. Only transport
failures are invalid.

## Known evasions and failure modes

- **Partial substitution.** Serving the claimed model on most requests and
  a substitute on a few lowers power in both components.
- **Probe recognition.** The built-in templates and prompts are public. A
  relay that recognises them can route them to the real model.
- **Imitation.** The AgentProv paper reports that prompt-level mimicry did
  not reproduce the reference's tool choices, but a substitute fine-tuned
  on these exact templates is not excluded.
- **Reference drift.** If the reference provider changes its own
  deployment (quantization, template, default system prompt), an honest
  relay that proxies the original provider will be reported `different`.
- **Deployment differences that are not substitution.** A hidden system
  prompt, different default sampling or a different chat template can
  cause `different`. The AgentProv paper measured a 7% false-positive rate
  for its test under system-prompt injection and 53% for RUT; Receipt's
  report points to Step 3 when both fire.
- **No reference.** Closed models with no trusted reference cannot be
  tested.
