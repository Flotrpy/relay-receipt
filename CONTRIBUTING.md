# Contributing to Receipt

Thank you for helping. Receipt is small on purpose, so that people can
read it before they trust it. Contributions that keep it that way are the
most welcome.

## Ground rules

1. **No stronger claims than the evidence.** Use "signal", "anomaly" and
   "inconclusive" exactly as defined in
   [docs/THREAT_MODEL.md](./docs/THREAT_MODEL.md). An inconclusive result is
   never counted as clean.
2. **Thresholds are pre-registered.** Every cut-off lives in
   [docs/THRESHOLDS.md](./docs/THRESHOLDS.md) and `src/receipt/thresholds.gleam`,
   and a test keeps the two in step. Changing one needs a dated entry in the
   change log at the bottom of that document with the reason, and must
   never be done to make a particular endpoint pass or fail.
3. **No real keys or endpoints in the repository.** Fixtures come from the
   simulated relay (`test/support/fake.gleam`) or the local test bed. Never
   commit a trace from a real service.
4. **Gleam only.** Receipt is Gleam on the BEAM. Erlang is allowed only as
   a thin shim over an OTP function, with an ADR in `docs/adr/` (see
   ADR 0001 for the policy). No Python or JavaScript in Receipt itself.

## Development

You need Erlang/OTP 27 or newer and Gleam 1.19 or newer.

```bash
gleam test
```

```bash
gleam format src test
```

```bash
gleam run -m gleescript
```

The last command builds the `receipt` escript.

Tests never touch the network. Step tests run against the simulated relay;
transport tests use a local server; `test/sample_replay_test.gleam` replays
the committed synthetic trace. If you change a step's requests, regenerate
the sample:

```bash
gleam run -m tools/make_sample
```

## Commits and pull requests

- One logical change per commit, with a Conventional Commits subject
  (`feat(step08): ...`, `fix(stream): ...`, `docs(thresholds): ...`).
- Every commit builds and passes all tests.
- Update `CHANGELOG.md` under "Unreleased".
- A new step or a changed verdict rule needs a design note in
  `docs/steps/` or an update to the existing one, written before the code.

## Reporting a relay

Please do not open issues that name a relay as dishonest. See
[SECURITY.md](./SECURITY.md) for responsible disclosure.
