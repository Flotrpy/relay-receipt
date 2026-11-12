# Test bed

A local "evil relay" for checking that Receipt finds what it is designed to
find, and does not flag an honest relay.

```text
Receipt ──▶ evil relay (Gleam, 127.0.0.1) ──▶ LiteLLM gateway ──▶ Groq / Gemini free tiers
   │
   └──────▶ trusted reference: Groq directly, same model
```

- `litellm/config.yaml` — configuration for an unmodified
  [LiteLLM](https://github.com/BerriAI/litellm) proxy. No custom code runs
  inside it.
- `evilrelay/` — a small Gleam proxy with one switchable fault:

| Fault | What the relay does | Steps aimed at it |
|---|---|---|
| `none` | forwards everything unchanged | none (honest control) |
| `inject` | prepends a ~170-token system prompt that outranks the caller's | 3, 4, 5, 6 |
| `pad` | appends ~120 words to every answer and bills them as output tokens | 15 |
| `swap` | serves another model and reports the claimed name | 17 |
| `rewrite` | changes package names in answers and in tool-call arguments | 8 |

- `run.sh` — starts the relay for each fault and runs Receipt with a fixed
  seed, keeping every JSON report and trace in an output directory.
- `evilrelay/src/evilrelay/matrix.gleam` — turns the reports into per-step
  confusion matrices.

## Running it

You need Erlang/OTP, Gleam, Python for LiteLLM only, and free Groq and
Gemini API keys.

```bash
python3 -m venv .venv && .venv/bin/pip install 'litellm[proxy]'
```

```bash
GROQ_API_KEY=... GEMINI_API_KEY=... LITELLM_MASTER_KEY=sk-local-test \
  .venv/bin/litellm --config testbed/litellm/config.yaml --port 4000
```

```bash
gleam run -m gleescript
```

```bash
LITELLM_MASTER_KEY=sk-local-test RECEIPT_REFERENCE_KEY="$GROQ_API_KEY" \
  testbed/run.sh a testbed/results
```

```bash
cd testbed/evilrelay && gleam run -m evilrelay/matrix -- ../results ../results/matrix.md
```

Matrices: `a` (Steps 3-6, 8-10, 15 under all five conditions), `b`
(Step 17 under `none` and `swap`), `c` (honest controls), `d` (Step 16
over two relays sharing one gateway), `e` (head-to-head with
api-relay-audit; set `ARA_DIR`).

The free tiers allow roughly 1000 requests per model per day on Groq, so
the matrices are spread over several models and run with a low request
rate. Results name real providers and stay in `testbed/results/`, which is
ignored by git.

The relay listens on the loopback interface only. Do not expose it.
