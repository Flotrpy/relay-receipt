# ADR 0002: Erlang shim over OTP `httpc` for HTTP

- Status: accepted
- Date: 2026-11-10

## Context

Receipt needs, for every request:

- the response body as raw bytes, split exactly as the network delivered
  it, with a monotonic arrival time per chunk (Steps 10, 13, 16 and the
  trace format depend on this);
- every response header;
- a hard deadline;
- TLS verification against the system trust store or a user-supplied CA
  file, and support for an HTTPS proxy from the environment, because many
  users sit behind one.

`gleam_httpc` 5.0 returns only complete bodies, has no per-chunk callback,
and exposes neither proxy nor CA settings. No other Gleam HTTP client on
Hex offers chunk timing. Writing an HTTP/1.1 and TLS client in Gleam on raw
sockets would be far more code, and far more risk, than calling the client
that ships with OTP.

## Decision

Add one Erlang module, `src/receipt_http_ffi.erl`, that wraps
`httpc:request/4` in asynchronous streaming mode and returns plain data:

```text
request(Method, Url, Headers, Body, TimeoutMs) ->
    {ok, {Status, Headers, Body, [{AtUs, Chunk}], HeadersUs, FirstByteUs, DoneUs}}
  | {error, {Kind, Detail}}
```

The shim does exactly four things:

1. starts `inets` and `ssl` once and applies `HTTPS_PROXY` / `NO_PROXY`
   from the environment;
2. builds TLS options: peer verification is always on, using
   `SSL_CERT_FILE` when set and the operating system's trust store
   otherwise;
3. collects `httpc` stream messages, stamping each with
   `erlang:monotonic_time(microsecond)`;
4. maps `httpc` error terms onto the five error kinds of
   `docs/TRACE_FORMAT.md`.

Everything else (retries, pacing, redaction, recording, parsing) is Gleam.

## Consequences

- There is no option to disable TLS verification.
- `httpc` streams only 200 and 206 responses; other statuses arrive as one
  message. For those, the single chunk's arrival time is the completion
  time, which is accurate enough because Receipt only analyses chunk timing
  for successful streams.
- Redirects are not followed. A relay that redirects an API call is
  reported as it is.
- The shim is about a hundred lines and has its own tests against a local
  server.
