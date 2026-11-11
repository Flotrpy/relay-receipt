# ADR 0003: Erlang shim for DNS records and the TLS certificate

- Status: accepted
- Date: 2026-11-11

## Context

Step 1 (infrastructure recon) reports the DNS records of the relay's host
and a summary of the TLS certificate it presents. api-relay-audit gets
these by running `dig`, `nslookup` and `openssl`. Receipt should not shell
out: external tools differ per platform and their output is unstructured.

Gleam has no resolver API and no way to read a peer certificate. OTP has
both (`inet_res`, `ssl`, `public_key`).

## Decision

Add `src/receipt_net_ffi.erl` with two functions that return plain data:

```text
dns(Host) -> [{Type, Value}]
tls_certificate(Host, Port, TimeoutMs) ->
    {ok, {Subject, Issuer, NotBefore, NotAfter}} | {error, Detail}
```

- `dns/1` queries A, AAAA, CNAME and NS records with `inet_res`, falling
  back to the system resolver for the address when `inet_res` returns
  nothing (for example for names that exist only in the hosts file).
- `tls_certificate/3` opens a TLS connection with peer verification on,
  reads the peer certificate, closes the connection and sends no
  application data. A verification failure is returned as the error
  detail, which is itself worth reporting.

Formatting the result into report text happens in Gleam. The values are
stored in the trace as observations (see `docs/TRACE_FORMAT.md`), so the
shim is never called during replay.

## Consequences

- No dependency on `dig`, `whois` or `openssl`. WHOIS is dropped (see
  `docs/PARITY.md`).
- Behind an HTTPS-only proxy the direct TLS connection can fail; Step 1
  then reports the failure text and stays informational as long as the
  host resolves or answers HTTP.
