# Trace format

Receipt can record every HTTP exchange of a run to a file (`--record`) and
later run the same audit from that file with no network (`--replay`).
Traces make the test suite deterministic and make a finding reviewable:
anyone with the trace can re-run the analysis.

Format name: `receipt-trace`, version `1`. Encoding: UTF-8
[JSON Lines](https://jsonlines.org/), one JSON object per line.

## Line types

### `header` (first line, exactly one)

```json
{"type":"header","format":"receipt-trace","version":1,
 "tool_version":"0.1.0","created_at":"2026-11-10T04:00:00Z",
 "seed":42,"key_lengths":{"target":40,"reference":56}}
```

| Field | Meaning |
|---|---|
| `seed` | Run seed. Replay uses it so shuffles, permutations and tie-breaks repeat exactly. |
| `key_lengths` | Length of each endpoint's API key, by endpoint name. See redaction. |

### `exchange` (one per HTTP request attempt)

```json
{"type":"exchange","seq":17,"endpoint":"target","step":15,
 "label":"q03/probed",
 "request":{"method":"POST","url":"https://relay.example/v1/chat/completions",
            "headers":[["content-type","application/json"],
                       ["authorization","[redacted]"]],
            "body":"{\"model\":\"m\",\"messages\":[...]}"},
 "response":{"status":200,
             "headers":[["content-type","application/json"]],
             "body_b64":"eyJpZCI6...",
             "chunks":[{"at_us":412345,"bytes":512},
                       {"at_us":498112,"bytes":301}]},
 "sse":null,
 "timing":{"started_us":1200345,"headers_us":398220,
           "first_byte_us":412345,"done_us":498112},
 "usage":{"prompt_tokens":212,"completion_tokens":97,
          "cached_tokens":null,"reasoning_tokens":null},
 "error":null}
```

| Field | Meaning |
|---|---|
| `seq` | Order in which requests were started, from 0. |
| `endpoint` | Endpoint name: `target`, `reference`, or a name given with `--endpoint`. |
| `step`, `label` | Which step sent it and the step's own label for the probe. For humans; not used for matching. |
| `request.headers` | Ordered list of pairs, names lower-cased. |
| `request.body` | Request body as a string (requests are always UTF-8 JSON or deliberately broken text). |
| `response` | `null` when no HTTP response was received. |
| `response.headers` | Ordered list of pairs; repeated headers appear once per occurrence. |
| `response.body_b64` | Raw response bytes, base64. |
| `response.chunks` | One entry per network chunk, with its arrival time and size. Chunk boundaries are exactly as received. |
| `sse` | For event streams: list of `{"at_us":..,"event":..,"data":..}` in order, derived from the body and chunk times. `null` otherwise. |
| `timing.started_us` | Monotonic microseconds since the start of the run. |
| `timing.headers_us`, `first_byte_us`, `done_us` | Monotonic microseconds since `started_us`. `null` if the event did not happen. |
| `usage` | Usage numbers as parsed by the API adapter, or `null`. Redundant with the body; kept so traces can be inspected without decoding. |
| `error` | `null`, or `{"kind":..,"detail":..}` with kind `timeout`, `connect`, `tls`, `closed` or `other`. |

All times come from Erlang's monotonic clock, never the system clock.

## Redaction

A trace must be safe to commit as a test fixture.

1. The values of `authorization`, `x-api-key`, `api-key` and
   `x-goog-api-key` request headers are replaced with `[redacted]`.
2. Each endpoint's key is replaced, wherever it appears in URLs, request
   bodies, response headers or response bodies, with a **stand-in key** of
   the same length: `sk-receipt-` followed by the repeating digits
   `0123456789abcdef`, cut to length. Any fragment of the key of 8 or more
   characters is replaced by the same positions of the stand-in.
3. During replay the endpoint's key *is* the stand-in key. Step 9, which
   looks for the key in error responses, therefore behaves identically on a
   replayed trace without the real key ever being stored.

Redaction happens before a line is written. There is no option to turn it
off.

Traces can still contain private relay URLs, model output and anything a
relay put in an error message. Review a trace before sharing it. Fixtures
committed to this repository come only from the local test bed or are
synthetic.

## Replay

- Requests are matched on `(endpoint, method, url, SHA-256 of the redacted
  request body)`. Exchanges with the same match key are served in recorded
  order.
- A request with no matching exchange fails the run with a `trace_miss`
  error. It is never retried and never falls back to the network.
- Timings are served from the trace. Waits (pacing, back-off, keep-warm
  intervals) return immediately.
- Retries are replayed as recorded: each attempt is its own exchange.

## Versioning

`version` is bumped on any incompatible change. A replayer refuses a trace
whose `format` or `version` it does not know.
