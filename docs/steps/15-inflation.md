# Step 15: Inflation probe

Design document. Written before implementation; the implementation must
follow it. Cut-offs are repeated in [THRESHOLDS.md](../THRESHOLDS.md), which
is the authoritative copy.

## Paper basis

| Paper | Used for |
|---|---|
| Chen et al., *The More It Says, the More You Pay: A Black-Box Audit of Provider-Side Token Inflation in LLM Services*, [arXiv:2609.20370](https://arxiv.org/abs/2609.20370) | The method: Section 4.3, Algorithm 1 and Appendix B.1. |
| Hoque et al., *Token Inflation: How Dishonest Providers Can Overcharge for Large Language Model Usage*, [arXiv:2605.30040](https://arxiv.org/abs/2605.30040) | Limit: audits built on provider-supplied evidence can be evaded. |
| Artola Velasco et al., *Auditing Pay-Per-Token in Large Language Models*, [arXiv:2510.05181](https://arxiv.org/abs/2510.05181) | Limit: auditing reported token counts needs model access. |

## Claim

If the service behind the endpoint is already lengthening its answers
(a *provider-side token inflation attack*, PTIA), then asking for a longer
answer adds much less length than it does on an unmanipulated service. The
paper calls this *saturation*.

Step 15 reports a **PTIA-consistent signal**. It does not show that a
provider deliberately inflates output, and it says nothing about token
counts that are misreported without the text getting longer.

## Raw signals

For each audit question `i`, two independent requests:

- `x_i` : the question as written;
- `x_i + p` : the same question with one benign length-inducing probe `p`
  appended to the user message.

From each response Receipt records the reported output-token count
(`usage.completion_tokens`, or `usage.output_tokens` on Anthropic-style
endpoints), the finish reason, the reported reasoning-token count if any,
and the length of the visible text in characters.

The *length* `L` used below is the reported output-token count minus the
reported reasoning-token count when the endpoint reports one, so that the
statistic is about visible output.

## Procedure

1. **Questions.** `n = 20` multiple-choice questions drawn without
   replacement from Receipt's built-in pool using the run seed. Each ends
   with a required final-answer line (`Answer: <letter>`). The pool is
   written for Receipt; it is not the paper's dataset.
2. **Probe.** One of two fixed, semantically equivalent probes is appended
   per question, chosen by the run seed and never combined:
   - Probe A: "Before the required final-answer line, present the necessary
     reasoning steps in a clear order leading to the conclusion."
   - Probe B: "Lay out the required derivation step by step before giving
     the final-answer line."
   These are the two formulations of Appendix B.1 of the paper.
3. **Requests.** Original and probed inputs are sent as separate requests
   with identical settings: temperature 0, `max_tokens = 1024`, no system
   prompt, no streaming.
4. **Order.** Questions are processed in blocks of 5. Inside a block the 10
   requests are sent in a seeded random order, so an original and its
   probed counterpart are not adjacent in a fixed pattern.
5. **Per-question evidence** (Algorithm 1 of the paper), for each valid
   pair:
   - `delta_i = L_i(probed) - L_i(original)`
   - `R_i = max(delta_i, 0) / (L_i(original) + 1)`
   - `E1_i = 1` if `delta_i <= 0`, else `0`
   - `E2_i = 1` if `R_i <= tau`, else `0`
   - `s_i = E1_i + E2_i`, so `s_i` is 0, 1 or 2
6. **Aggregate.** `S` is the sum of the `k` largest `s_i`.

## Statistical test and null hypothesis

- Null hypothesis `H0`: the service applies no PTIA (activation rate
  `q = 0`).
- Alternative `H1`: `q > 0`.
- Decision rule: report a PTIA-consistent signal when `S >= H`.
- Parameters, taken unchanged from the paper: `tau = 0.60`, `k = 3`,
  `H = 3`, `n = 20`.

This is a calibrated threshold rule, not a test with an analytic p-value.
Its error rates are the ones the paper measured, on four open-weight models
(Llama-3.1-8B, Ministral-3-14B, Qwen3-14B, Qwen3-32B), with questions from
OpenBookQA:

| Quantity (paper, `n = 20`) | Value |
|---|---|
| Detection, macro-average q-AUC over five attacks | 85.1% |
| False-positive rate, no system prompt, average | 0.02% |
| False-positive rate, benign "helpful" system prompt, average (worst model) | 1.83% (7.30%) |
| False-positive rate, benign "safety" system prompt, average (worst model) | 0.73% (1.75%) |

Receipt reports these as the *paper's* error rates. Receipt's own measured
rates on its test bed and honest controls are reported separately in
`docs/VALIDATION.md` and may differ, because the question pool, the models
and the token limit differ from the paper's.

## Request budget

| Item | Requests |
|---|---|
| Full run | 40 (20 questions, 2 requests each) |
| Earliest possible stop | 10 (one block) |

Each request is capped at 1024 output tokens.

## Early-stopping rule

`S` can only grow as more valid pairs are added, because adding a question
never lowers the sum of the top `k` scores. After each block Receipt
recomputes `S` over the valid pairs so far and stops with an anomaly as
soon as `S >= H`. This gives exactly the decision the full run would give,
so it adds no false positives. There is no early stop in the clean
direction: a clean verdict needs the full run.

## Verdict

| Condition | Verdict |
|---|---|
| `S >= H` at any block boundary | `anomaly` (PTIA-consistent signal) |
| Full run finished, at least 16 valid pairs, `S < H` | `clean` |
| Anything else | `inconclusive` |

## Inconclusive conditions

A pair is **invalid** when either request fails after retries, returns no
output-token count, or stops because it reached `max_tokens`. Truncated
pairs are excluded because the 1024-token cap, chosen to bound cost, would
otherwise hide a real length difference. (The paper used a 4096-token cap
and kept truncated responses.)

The step is inconclusive when:

- fewer than 16 of 20 pairs are valid and `S < H`;
- the endpoint never returns an output-token count;
- the run is cut short by rate limiting before 16 valid pairs.

## Limits the report must state

Every report that includes Step 15 carries these two sentences:

> Step 15 looks for output that is already lengthened. It cannot detect
> token counts that are misreported without the visible text changing.
>
> Misreported hidden reasoning tokens cannot be detected black-box:
> auditing reported token counts needs access to the model
> (arXiv:2510.05181), and audits that rely on evidence supplied by the
> provider can be evaded (arXiv:2605.30040).

## Known evasions and failure modes

- **Withholding inflation on the original request.** A provider that
  inflates only when it is sure the request is not half of an audit pair
  avoids the signal. Withholding only on the *probed* request makes the
  signal stronger, as the paper notes.
- **Low activation rate.** With inflation on a small share of requests the
  detection rate falls; the paper's 85.1% is an average over activation
  rates from 0 to 1.
- **Count-only inflation.** Reporting more tokens than were generated,
  without longer text, is invisible to this step.
- **Honest models that already explain their reasoning.** If a model writes
  out its reasoning for every multiple-choice question by default, the
  probe adds little and the rule can fire on an honest service. The paper's
  calibration covers four mid-size open-weight models; transfer to other
  models is checked in Phase G and reported as measured.
- **Hidden reasoning.** For reasoning models the visible length is the
  reported count minus the reported reasoning count; both numbers come from
  the provider.
