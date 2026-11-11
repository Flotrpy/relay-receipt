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
  purpose of comparison (in this project: the free tiers of Groq and Google
  Gemini). Trust here is an assumption made by the user, not something
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
