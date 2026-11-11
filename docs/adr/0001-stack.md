# ADR 0001: Gleam on the BEAM, with a minimal Erlang FFI

- Status: accepted
- Date: 2026-11-10

## Context

Receipt is a rebuild of the audit system in
[api-relay-audit](https://github.com/toby-bridges/api-relay-audit) v2.5.0
(Python standard library plus `curl`) with three additional statistical
checks. The new checks need things the original did not:

- many concurrent requests to several endpoints (Step 16 keeps a planted
  cache entry warm on one endpoint while probing another);
- timings that are not affected by wall-clock adjustments;
- deterministic statistics (permutation tests, sequential tests) that give
  the same answer when replayed from a recorded trace;
- a single file that a user can read, build and run locally.

## Decision

1. **Language: Gleam, compiled to Erlang, running on the BEAM.**
   Static types catch a class of report-shape bugs at compile time, and the
   verdict and status types can be closed unions so that no step can return
   a value outside the documented vocabulary.
2. **Concurrency: OTP processes.** Each endpoint probe runs in its own
   process; the keep-warm workers of Step 16 are plain processes that are
   stopped by message.
3. **Timing: Erlang's monotonic clock** (`erlang:monotonic_time/1`), never
   the system clock. Wall-clock time is used only for the report timestamp.
4. **Distribution: an escript** built with `gleescript`. The user needs an
   Erlang/OTP runtime and nothing else.
5. **Tests: `gleeunit` for unit tests, `qcheck` for property tests, and
   recorded traces** (see [TRACE_FORMAT.md](../TRACE_FORMAT.md)) for
   deterministic end-to-end tests with no network.
6. **Randomness: a seeded generator written in Gleam.** Permutation tests
   and randomised tie-breaking take an explicit seed so that a replayed
   trace reproduces the same p-values.
7. **No Python, no JavaScript/TypeScript** in Receipt itself. The test bed
   under `testbed/` runs a third-party gateway (LiteLLM) from configuration
   only; any fault-injection code in the test bed is Gleam.

## Erlang FFI policy

Gleam cannot express a few things Receipt needs. Each use of the FFI is the
smallest Erlang shim that exposes an OTP function, with all logic kept in
Gleam, and each gets its own ADR when it is introduced:

| Need | Why Gleam alone is not enough | Shim |
|---|---|---|
| Monotonic time | No clock in the Gleam standard library | one call to `erlang:monotonic_time/1` |
| HTTP with streamed chunks, per-chunk timing, proxy and CA options | `gleam_httpc` 5.0 returns only complete bodies, exposes no chunk timing and no proxy setting | thin wrapper over OTP `httpc` |
| DNS records and TLS certificate summary (Step 1) | No resolver or TLS introspection in Gleam packages | `inet_res` and `ssl` calls |

Everything else, including the SSE parser, the API adapters, all
statistics and both reporters, is Gleam.

## Consequences

- Users need Erlang/OTP 27 or newer to run the escript.
- The Gleam ecosystem is small, so Receipt has few dependencies and more
  first-party code (statistics, CLI parsing). That is acceptable for a tool
  whose users are expected to read it before trusting it.
- The FFI surface must stay small enough to review in one sitting. A change
  that adds logic to an `.erl` file instead of a `.gleam` file needs a new
  ADR.
