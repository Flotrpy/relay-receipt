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
| 5 | Any rated step has status `run` and verdict `inconclusive`, or any step crashed | `MEDIUM` |
| 6 | Otherwise | `LOW` |

`LOW` means no rule above matched for the steps that ran. It is not a
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
| Any reply contains a structural leak (instruction-style text of at least 40 characters presented as the system prompt, or a second-person role definition such as "You are ..." followed by rules) | `anomaly` |
| No structural leak, but a reply has only weak markers and is not a refusal, or some probes failed or were empty | `inconclusive` |
| Every reply is a refusal or a statement that there is no system prompt | `clean` |

### Step 5: Instruction override / identity self-report

| Setting | Value |
|---|---|
| Adherence trials | 3 |
| Trial passes when | the reply, lower-cased and stripped of punctuation and whitespace, equals the sentinel word |

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
