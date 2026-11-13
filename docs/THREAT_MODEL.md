# Threat model

This document says what Receipt assumes about a relay, what the person
running Receipt can and cannot see, and which kinds of dishonest behaviour
each step can and cannot surface. It is written before any code and before
any real endpoint is tested.

## Vocabulary

Receipt uses four words with fixed meanings. They are used the same way in
the code, the reports and every document in this repository.

| Word | Meaning |
|---|---|
| **signal** | An observation that is more likely under dishonest behaviour than under honest behaviour, but that honest behaviour can also produce. |
| **anomaly** | A step's pre-registered rule (see [THRESHOLDS.md](./THRESHOLDS.md)) fired. An anomaly is a reason to investigate. It is not proof of intent or of a specific mechanism. |
| **inconclusive** | The step ran but could not reach a decision: probes were blocked, a usage field was missing, the rate limit was hit, or the result fell in a band the rule leaves undecided. Inconclusive is never counted as clean. |
| **clean** | The step ran, had enough valid observations, and its rule did not fire. Clean means "this probe saw nothing", not "the relay is honest". |

A fifth verdict, **informational**, is used by steps that only describe the
endpoint (for example which gateway software it appears to run) and make no
claim either way.

## Parties

```text
user (runs Receipt) --> relay R --> ... --> upstream provider --> model
                          ^
                          may itself buy from other relays
```

- **User / auditor.** An ordinary customer of the relay. Holds an API key
  for the relay and, optionally, a key for a *trusted reference provider*
  that serves the same open-weight model.
- **Relay.** Any service between the user and the model: reseller, gateway,
  proxy, aggregator. It terminates TLS, so it sees and can change every
  request and response in plaintext.
- **Upstream.** Whatever the relay forwards to. It may be the model's
  original provider, a cloud host, or another relay.
- **Trusted reference.** A provider the user chooses to trust for the
  purpose of comparison (in this project's test bed: a free hosted tier).
  Trust here is an assumption made by the user, not something
  Receipt verifies.

## What a dishonest relay controls

The relay is a full application-layer man-in-the-middle by design. No
provider enforces end-to-end integrity between client and model
([arXiv:2604.08407](https://arxiv.org/abs/2604.08407)). A relay can:

| Capability | Example |
|---|---|
| Rewrite the request | Prepend a hidden system prompt; drop or truncate long context; change sampling parameters; strip tools. |
| Choose the model | Serve a cheaper, smaller, quantized or unrelated model under the advertised name; mix models per request. |
| Rewrite the response | Change package names or tool-call arguments; pad or lengthen output; alter streamed events. |
| Rewrite metadata | Report any `usage` numbers, model name, ids and headers it likes. |
| Choose its upstream | Forward through other relays without saying so; share upstream credentials with unrelated storefronts. |
| Keep what it sees | Log prompts, responses and any credentials that pass through. |
| Behave conditionally | Act only on some requests, only after a warm-up period, or only when a request does not look like an audit ([arXiv:2604.08407](https://arxiv.org/abs/2604.08407), AC-1.b). |

Receipt assumes the relay cannot break TLS to *other* hosts, cannot read the
user's machine, and cannot change what the trusted reference returns.

## What the user can observe

Receipt is strictly black-box. For each request it can record:

- the bytes it sent and the bytes it received, including every response
  header and every server-sent event;
- when each chunk arrived, on a monotonic clock;
- the `usage` object the relay chose to report (prompt, completion, cached
  and reasoning token counts where present);
- public facts about the relay's host: DNS records, TLS certificate,
  responses to unauthenticated requests;
- the same observations from the trusted reference, when one is configured.

Receipt cannot observe: the request the relay actually sent upstream, the
model weights or logits, hidden reasoning text, the relay's logs, or what
the relay does with other customers' traffic.

Everything in a report is derived from the first list. Anything that would
need the second list is stated as a limit, not inferred.

## What each step can and cannot catch

"Catches" below means "produces an anomaly or a visible signal when the
behaviour is present on the audited requests". Every row is subject to the
general limits in the next section.

| Step | Cheat it is aimed at | Signal used | Cannot catch |
|---|---|---|---|
| 1 Infrastructure recon | none (descriptive) | DNS, TLS certificate, HTTP headers | Anything about behaviour. |
| 2 Connectivity | none (descriptive) | Which API formats answer | Anything about behaviour. |
| 3 Token injection | Hidden system prompt added to every request | Billed prompt tokens minus the count a trusted reference bills for the same text and model | A relay that subtracts its own overhead from `usage`; injections on only some requests; a relay with no reference available falls back to a rough estimate. |
| 4 Prompt extraction | Hidden system prompt | Model repeats instructions the user never sent | Prompts the model refuses to reveal; a relay that filters the reply. |
| 5 Instruction override | Hidden prompt that outranks the user's system prompt | Model fails to follow a simple user system instruction; self-reported identity conflicts with the claimed model | Hidden prompts that do not conflict with the test instruction. Self-reported identity is a consistency signal only. |
| 6 Jailbreak resistance | Hidden prompt, weak guardrails | Role-play and encoding requests that reveal injected text | Same limits as Step 4. |
| 7 Context truncation | Relay silently drops part of a long prompt | Canary strings planted through a long input are not recalled | Truncation above the tested size; honest model recall failures look the same and are reported as inconclusive unless the pattern is positional. |
| 8 Tool-call substitution | Relay rewrites package names or tool arguments ([arXiv:2604.08407](https://arxiv.org/abs/2604.08407), AC-1.a) | Exact comparison of echoed install commands and of structured tool-call arguments | Rewrites triggered only by packages or contexts outside the probe set; conditional delivery. |
| 9 Error-response leakage | Relay echoes credentials or internals when a request fails | Error bodies and headers scanned for the key, upstream URLs, environment names, paths, stack traces | Leaks that happen only in the relay's own logs. |
| 10 Stream integrity | Relay rewrites or re-chunks streamed output | SSE event grammar, id and model consistency, usage monotonicity, single terminal event | A relay that rebuilds a well-formed stream. |
| 12 Infrastructure fingerprint | none (descriptive) | Gateway software markers in unauthenticated responses | A relay that strips the markers. |
| 13 Latency variance | Per-request model mixing | Spread and bimodality of latency for identical requests | Mixing between models with similar latency. Network jitter produces the same signal. |
| 14 Upstream channel | Undisclosed upstream | Id prefixes and headers that identify a serving channel | A relay that rewrites ids and headers. |
| 15 Inflation probe | Provider-side output lengthening ([arXiv:2609.20370](https://arxiv.org/abs/2609.20370)) | A length-inducing probe adds far fewer tokens than it does on normal service | Misreported token counts without longer text; misreported hidden reasoning tokens (see below); inflation on a small fraction of requests. |
| 16 Upstream map | Hidden shared backends between endpoints ([arXiv:2608.20732](https://arxiv.org/abs/2608.20732)) | A prompt cached through one endpoint is reported as a cache hit through another | Endpoints whose upstream has no prefix cache or reports no cached-token count; sharing below the measurement resolution; a relay that zeroes the cached-token field. |
| 17 Identity test | Model substitution | Tool-choice distribution ([arXiv:2609.00052](https://arxiv.org/abs/2609.00052)) and rank uniformity of responses ([arXiv:2506.06975](https://arxiv.org/abs/2506.06975)) against the same model on the trusted reference | Substitution on a small fraction of requests; a substitute tuned to imitate the reference on these probes; any model for which no trusted reference exists. |

## Limits that apply to every step

1. **A report is not a safety certificate.** A relay that passes every step
   has passed these probes, on these requests, at this time.
2. **Conditional behaviour.** A relay can recognise audit traffic, or act on
   one request in a thousand. Receipt reduces this risk (ordinary-looking
   probes, randomised order) but cannot remove it.
3. **Reported numbers are the relay's numbers.** Token counts, cached-token
   counts, model names and ids are whatever the relay returns. A step that
   relies on them says so, and says in which direction a lie would bias it.
4. **Hidden reasoning tokens cannot be audited black-box.** When a model's
   reasoning is not returned, the user sees only a count. The sequential
   audit of [arXiv:2510.05181](https://arxiv.org/abs/2510.05181) needs the
   output text and access to the model's next-token probabilities, and its
   authors argue that some form of model access is necessary for any
   effective audit of reported tokens. Receipt has neither, and
   [arXiv:2605.30040](https://arxiv.org/abs/2605.30040) shows that audits
   built on provider-supplied evidence can be evaded with large inflation.
   Receipt therefore does not claim to detect misreported hidden reasoning
   tokens, and every report that includes Step 15 says so.
5. **Statistical tests have error rates.** Steps 15, 16 and 17 state their
   false-positive rate. A rejection at the 5% level will happen by chance
   on about one honest endpoint in twenty.
6. **The reference is trusted by assumption.** If the trusted reference
   itself changes the model or the prompt, Steps 3 and 17 will blame the
   relay.
7. **Attribution is out of scope.** Receipt reports what was observed at an
   endpoint. It does not say who caused it, whether it was deliberate, or
   which party in a resale chain is responsible.

## Responsible use

- Receipt is for auditing endpoints you are a customer of, with your own
  key, at request rates their terms allow.
- Probe prompts are synthetic. Receipt never sends other people's data.
- Results that name a real provider are not published from this repository
  without first contacting that provider. See [SECURITY.md](../SECURITY.md)
  once it exists; until then the rule is: do not publish.
