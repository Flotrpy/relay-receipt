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
