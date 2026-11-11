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
