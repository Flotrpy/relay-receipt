# Thresholds

Every pass/fail cut-off Receipt uses is listed here and was fixed **before
any real endpoint was tested**. The code reads these values from one module
(`receipt/thresholds`), and a test checks that module against this file.

Changing a value after validation has started requires: a new dated entry
in the change log at the bottom of this file, the reason, and a re-run of
the validation in `docs/VALIDATION.md`. Values are never tuned to make a
particular endpoint pass or fail.

Significance level everywhere: `alpha = 0.05`.

## Verdicts and statuses

| Verdict | Meaning |
|---|---|
| `clean` | The step ran with enough valid observations and its rule did not fire. |
| `anomaly` | The step's rule fired. |
| `inconclusive` | The step could not decide. Never counted as clean. |
| `informational` | The step only describes the endpoint. |

| Status | Meaning |
|---|---|
| `run` | The step executed. |
| `skipped` | The user turned it off, or an earlier failure (no connectivity) made it pointless. |
| `profile_gated` | The selected profile does not include it. |
| `not_applicable` | It cannot apply to this run (no reference configured, fewer than two endpoints, dropped step). |

A step whose status is not `run` always carries the verdict `inconclusive`:
a step that did not run is not evidence of anything.

An `anomaly` may carry a severity: `medium`, `high` or `critical`. Steps
that do not grade severity use `high`.

## Step classes

| Class | Steps | Effect of an anomaly |
|---|---|---|
| critical | 8, 9 (severity high or critical), 10 | `HIGH` on its own |
| major | 3, 4, 5, 7, 15, 17 | `MEDIUM` on its own, `HIGH` with a second major anomaly |
| advisory | 6 | shown, does not move the rating |
| informational | 1, 2, 12, 13, 14, 16 | never moves the rating |

Steps of class critical or major are the **rated steps**.

## Overall rating

First matching rule wins.

| # | Condition | Rating |
|---|---|---|
| 1 | Any critical-class step has verdict `anomaly` | `HIGH` |
| 2 | Two or more major-class steps have verdict `anomaly` | `HIGH` |
| 3 | Exactly one major-class step has verdict `anomaly` | `MEDIUM` |
| 4 | Step 9 has verdict `anomaly` with severity `medium` | `MEDIUM` |
| 5 | Any rated step has status `run` and verdict `inconclusive`, or any step crashed, or no rated step has status `run` | `MEDIUM` |
| 6 | Otherwise | `LOW` |

`LOW` means at least one rated step ran and no rule above matched. It is not a
statement that the relay is safe. Rated steps that did not run are listed
under coverage in every report.

## Transport

| Setting | Value |
|---|---|
| Request timeout | 60 s (180 s for Step 7 requests) |
| Retries | 2, on transport errors, HTTP 429 and HTTP 5xx |
| Backoff | exponential, base 1 s, factor 2, full jitter, cap 30 s |
| `Retry-After` | honoured up to 60 s; longer waits end the step as inconclusive |
| Default pacing | at most 20 requests per minute per endpoint (`--rpm`) |
| Rate-limit give-up | 3 consecutive HTTP 429 responses after retries end the step as inconclusive |

## Parity steps

### Step 1: Infrastructure recon

| Condition | Verdict |
|---|---|
| Host resolves | `informational` |
| Host does not resolve | `inconclusive` |

### Step 2: Connectivity

| Condition | Verdict |
|---|---|
| A minimal chat request succeeds in at least one API format | `informational` |
| No format succeeds | `inconclusive`; all later steps that need chat are `skipped` |

### Step 3: Token injection

**Reference method** (a trusted reference is configured), after
[arXiv:2608.29930](https://arxiv.org/abs/2608.29930):

| Setting | Value |
|---|---|
| Texts per repeat | 30 built-in controlled texts |
| Request settings | temperature 0, `max_tokens = 1` |
| Repeats | 1 in `general`, 3 in `full` |
| Repeat is informative when | at least 20 paired counts are valid and paired coverage is at least 0.8 |
| Step is eligible when | every repeat is informative |
| Offset per text | `d = prompt_tokens(endpoint) - prompt_tokens(reference)` |
| Modal offset `m` | most frequent `d`; ties go to the smallest absolute value |
| Shift-invariant score `s` | fraction of texts with `d = m`, averaged over repeats |
| Counts comparable when | `s >= 0.725` (the paper's frozen threshold) |

| Condition | Verdict |
|---|---|
| Not eligible | `inconclusive` |
| `s < 0.725` | `inconclusive` (the two endpoints do not count tokens alike, so the offset is not interpretable) |
| `s >= 0.725` and `m > 100` | `anomaly` |
| `s >= 0.725` and `20 < m <= 100` | `inconclusive` |
| `s >= 0.725` and `m < -20` | `inconclusive` |
| `s >= 0.725` and `-20 <= m <= 20` | `clean` |

**Estimate method** (no reference): three minimal messages; expected
prompt tokens are estimated as `ceil(characters / 4) + 12`; `delta` is the
largest billed-minus-expected difference.

| Condition | Verdict |
|---|---|
| Every probe failed or returned no prompt-token count | `inconclusive` |
| `delta > 100` | `anomaly` |
| `20 < delta <= 100` | `inconclusive` |
| `delta <= 20` | `clean` |

The 100 and 20 token cut-offs are api-relay-audit's.

### Step 4: Prompt extraction

Three probes, no system prompt sent.

| Condition | Verdict |
|---|---|
| Any reply contains a confirmed structural leak | `anomaly` (or `inconclusive` when the trusted reference shows one too) |
| No confirmed structural leak, but a reply has only weak markers and is not a refusal, or some probes failed or were empty | `inconclusive` |
| Every reply is a refusal, a statement that there is no system prompt, or a bare self-identification | `clean` |

A **structural leak** is instruction-style text of at least 40 characters
presented as the system prompt, or a second-person role definition such as
"You are ..." in a reply that also contains a directive. It is
**confirmed** when it is not an echo of the probe's own wording and the
same probe, asked a second time, returns a structural leak sharing at least
half of its distinct words. A **bare self-identification** is a reply
shorter than 200 characters that names a model family and contains no
directive.

### Step 5: Instruction override / identity self-report

| Setting | Value |
|---|---|
| Adherence trials | 3 |
| Trial passes when | the reply, lower-cased and stripped of punctuation and whitespace, equals the sentinel word |
| Trial is not judged when | the request fails or the reply is empty |

| Condition | Verdict |
|---|---|
| At least 2 of 3 trials fail | `anomaly` |
| Requests with a system message are rejected (HTTP 4xx) while the same request without one succeeds | `anomaly` |
| At least 2 of 3 pass, and the self-reported model family conflicts with the claimed model | `inconclusive` |
| At least 2 of 3 pass, no conflict | `clean` |
| Fewer than 2 trials returned a reply | `inconclusive` |

### Step 6: Jailbreak resistance (advisory)

Same evidence grades as Step 4, over three probes. `anomaly` on a
structural leak, `inconclusive` when every probe fails, otherwise `clean`.

### Step 7: Context truncation scan

| Setting | Value |
|---|---|
| Canaries per request | 5, evenly spaced |
| Sizes, `general` | 8 000 and 32 000 characters |
| Sizes, `full` | 8 000, 32 000, 128 000 and 400 000 characters |
| Size cap | sizes above 60% of `--context-window` (tokens x 4 characters) are not sent |
| Confirmation | a size with missing canaries is retried once |

| Result at one size | Meaning |
|---|---|
| ok | all 5 canaries recalled |
| edge-truncated | in both attempts the missing canaries form a block at the start or the end |
| recall-miss | canaries missing in any other pattern, or in only one attempt |
| limit | HTTP 413, 429, or an error naming context length |

| Condition | Verdict |
|---|---|
| Any size is edge-truncated | `anomaly` |
| No size is edge-truncated and at least one is a recall-miss or a limit | `inconclusive` |
| Every tested size is ok | `clean` |
| No size returned a reply | `inconclusive` |

### Step 8: Tool-call substitution

Four text-echo probes (pinned install commands for pip, npm, cargo, go)
and two structured tool-call probes.

| Probe result | Meaning |
|---|---|
| exact | character-identical |
| benign | same whitespace-separated tokens up to case and trailing punctuation |
| substituted | any other difference, in two attempts out of two |
| error | request failed, or the model did not echo / did not call the tool |

| Condition | Verdict |
|---|---|
| Any probe is substituted | `anomaly` |
| Every probe is an error | `inconclusive` |
| Otherwise | `clean` |

### Step 9: Error-response leakage

Five broken requests: malformed JSON, unknown model, wrong content type,
missing `messages`, unknown path.

| Severity | Trigger |
|---|---|
| critical | the full API key appears in a body or header |
| high | any 12 or more consecutive characters of the key; an upstream provider API host other than the audited host; an environment-variable name ending in `KEY`, `TOKEN`, `SECRET` or `PASSWORD` |
| medium | a filesystem path, or a stack-trace marker |

| Condition | Verdict |
|---|---|
| Any hit | `anomaly` with the highest severity found |
| No hit, and at least one probe returned an HTTP error response | `clean` |
| Every probe returned HTTP 200 or failed in transport | `inconclusive` |

### Step 10: Stream (SSE) integrity

OpenAI-style rules:

1. every `data:` payload is valid JSON or the literal `[DONE]`;
2. exactly one `[DONE]`, and nothing but comments after it;
3. every chunk carries the same `id`;
4. every chunk carries the same `model`;
5. each choice has exactly one non-null `finish_reason`;
6. if `usage` appears more than once, its token counts never decrease.

Anthropic-style rules:

1. every event type is one of `ping`, `message_start`,
   `content_block_start`, `content_block_delta`, `content_block_stop`,
   `message_delta`, `message_stop`, `error`;
2. `input_tokens`, when repeated, does not change;
3. `output_tokens` never decreases;
4. exactly one `message_stop`, after `message_start`, with only `ping`
   after it;
5. any `signature_delta` carries a non-empty signature.

| Condition | Verdict |
|---|---|
| Any rule is violated | `anomaly` |
| The response is not an event stream, has no events, or the stream fails in transport | `inconclusive` |
| All rules hold | `clean` |

A stream `model` that differs from the requested name is recorded as a
note, not as a rule violation: gateways legitimately return canonical
names.

### Step 12: Infrastructure fingerprint

Three unauthenticated GET requests (`/`, the models path, a random path).
A framework is **confirmed** when its signature matches in at least 2 of 3
responses, **tentative** with 1, **unknown** with 0. Verdict is always
`informational`, or `inconclusive` if no request got a response.

### Step 13: Latency variance

| Setting | Value |
|---|---|
| Probes | 10 identical requests (`--latency-probes`, 3 to 50), `max_tokens = 8` |
| Bimodal when | the largest gap between consecutive sorted latencies that leaves at least 2 samples on each side exceeds 0.5 x the median |
| Otherwise, coefficient of variation | below 0.25 stable; below 0.5 variable; else high-variance |

Verdict is `informational`, or `inconclusive` with fewer than 3 successful
probes. The cut-offs are api-relay-audit's.

### Step 14: Upstream channel classifier

Tier 1 (a single deterministic marker) gives confidence 1.0. Tier 2 sums
marker weights per channel and takes the maximum, capped at 1.0. A channel
is named only at confidence 0.5 or more. Verdict is always
`informational`, or `inconclusive` if no authenticated response was
obtained.

## New steps

### Step 15: Inflation probe

From [arXiv:2609.20370](https://arxiv.org/abs/2609.20370), unchanged.
Design: [steps/15-inflation.md](./steps/15-inflation.md).

| Setting | Value |
|---|---|
| Questions `n` | 20 |
| Relative-gain threshold `tau` | 0.60 |
| Top-`k` | 3 |
| Decision threshold `H` | 3 |
| Request settings | temperature 0, `max_tokens = 1024` |
| Block size | 5 questions |
| Minimum valid pairs for `clean` | 16 |

| Condition | Verdict |
|---|---|
| `S >= 3` at a block boundary | `anomaly` |
| Full run, at least 16 valid pairs, `S < 3` | `clean` |
| Otherwise | `inconclusive` |

### Step 16: Upstream map

From [arXiv:2608.20732](https://arxiv.org/abs/2608.20732). Design:
[steps/16-upstream-map.md](./steps/16-upstream-map.md).

| Parameter | `paper` | `coarse` |
|---|---|---|
| Resolution `delta` | 0.05 | 0.20 |
| `alpha` per direction | 0.05 | 0.05 |
| `N_flood` | 59 | 14 |
| `M_contain` | 4 | 2 |
| `N_prove` | 181 | 30 |
| `M_partial` | 15 | 11 |
| `M_nohit` | 59 | 14 |
| `L_probe` | 59 | 14 |
| Flood attempt cap `A_max` | 1000 | 250 |
| Consecutive error cap `E_abort` | 8 | 8 |
| Keep-warm workers | 2 | 2 |
| Keep-warm interval | 20 s per worker | 20 s per worker |

| Setting | Value |
|---|---|
| Base prefix length | 1 280 tokens (above the common 1 024-token cache minimum) |
| Default cache chunk `b` when the provider documents none | 128 tokens, replaced by the calibrated value when larger |
| Prefix stride | `2 x b` tokens |
| Hit | `cached_tokens >= prompt_tokens - b` |
| Calibration attempts | 3 |
| Default preset | `coarse` |

| Condition | Verdict |
|---|---|
| At least one pair classified (any relation except `inconclusive`) | `informational` |
| Every pair is `inconclusive` | `inconclusive` |

### Step 17: Identity test

Design: [steps/17-identity.md](./steps/17-identity.md).

| Setting | Value |
|---|---|
| Templates `K` (component A) | 20 |
| Samples per template per batch, each side | 5 |
| Component A request settings | temperature 0.7, `max_tokens = 256` |
| Prompts per batch (component B) | 10 |
| Reference samples per prompt `m` | 10 |
| Component B request settings | temperature 0.5, `max_tokens = 30` |
| Permutations / simulations `B` | 4 999 |
| p-to-e calibrator | `(1 - p + p ln p) / (p (ln p)^2)`, `e(1) = 1/2` |
| Combination | arithmetic mean of the two components' e-value products |
| Rejection threshold | `E >= 20` (`1 / alpha`) |
| Maximum batches | 2 in `general`, 5 in `full` |
| Batch validity, component A | at least 4 of 5 valid samples per side in at least 16 of 20 templates |
| Batch validity, component B | at least 8 of 10 prompts with an endpoint reply and at least 8 of 10 reference replies |

| Condition | Outcome | Verdict |
|---|---|---|
| `E >= 20` at a batch boundary | `different` | `anomaly` |
| Maximum batches done, `E < 20`, at least 2 valid batches in at least one component | `same` | `clean` |
| Otherwise | `insufficient_data` | `inconclusive` |

## Change log

| Date | Change | Reason |
|---|---|---|
| 2026-11-10 | Initial values | Fixed before any implementation or endpoint test. |
| 2026-11-12 | Steps 4 and 6: a structural leak must be confirmed by a second request and must not echo the probe; a bare self-identification counts like a refusal. Step 5: an empty reply is not judged. | A smoke test of the pipeline against an honest endpoint serving a reasoning model, run before the validation phase, showed three false signals: the model invented a different "configuration" for a diagnostic probe, replied to a translation probe with only its built-in identity line, and returned empty replies when its token budget went to reasoning. None of these is evidence about a relay. The change was made on that evidence and is disclosed here; the cut-offs of Steps 15-17 are untouched. |
| 2026-11-11 | Rating rule 5 also matches when no rated step ran | Found while wiring the pipeline, before any validation run: an endpoint that answers no chat request had every rated step skipped and would have been rated `LOW`. A run that tested nothing must not look like a run that found nothing. |
