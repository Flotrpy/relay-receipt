# Step 16: Upstream map

Design document. Written before implementation; the implementation must
follow it. Cut-offs are repeated in [THRESHOLDS.md](../THRESHOLDS.md), which
is the authoritative copy.

## Paper basis

Ji et al., *Uncovering and Understanding Hidden Dependencies in the LLM API
Reseller Ecosystem via Prefix-Cache Side Channels* ("CacheTracer"),
[arXiv:2608.20732](https://arxiv.org/abs/2608.20732). Receipt implements the
five primitives of Section III: Profile, Flood, Prove, Classify and
BuildGraph.

A note on the word "timing". CacheTracer's hit test reads the
**cached-token count** that the API reports in `usage`; it does not infer
hits from latency. Latency (time to first token) is used only by Profile,
to decide which pairs to test first. Receipt follows the paper: verdicts
come from cached-token telemetry, and timing is recorded as supporting
information only.

## Claim

Providers isolate prefix caches per tenant (organisation, project or
workspace). If a fresh prompt cached through endpoint A is then reported as
a cache hit through endpoint B, some of B's requests reach a cache domain
that A's requests also reach: the two endpoints share upstream credentials
somewhere along their paths.

Step 16 reports **cache-reach relations between the endpoints the user
supplies**. A relation shows overlapping or nested cache reach. It does not
identify a supplier, a contract or a forwarding path, and a shared backend
is not by itself wrongdoing. The step's verdict is therefore
`informational` whenever it completes.

## Assumptions (from the paper)

1. **Cache telemetry integrity.** A reported cached-token count reflects
   real reuse of state planted by an earlier request. A relay that hides
   hits can only remove relations from the result, not create them.
2. **Routing consistency.** During one measurement window, successful
   requests to an endpoint are independent draws from a fixed distribution
   over cache domains, and the prompt prefix does not change that
   distribution.

## Raw signals

Per request: `usage.prompt_tokens`, the cached-token count
(`usage.prompt_tokens_details.cached_tokens`, or
`usage.cache_read_input_tokens` on Anthropic-style endpoints), status,
transport error or timeout, and time to first token.

## Procedure

Inputs: two or more endpoints (base URL, model, key environment variable)
that claim to serve the same model, and a resolution preset.

### Prompts

Each direction uses one fresh prompt `P`: a fixed instruction to reply with
exactly `OK`, then a nonce never used before, then padding words. Because
the instruction and nonce come first, every shorter cut of `P` is a true
prefix of `P`. The **prefix ladder** `P[1] ⊂ P[2] ⊂ ... ⊂ P[L_probe] = P`
is built by cutting the padding at increasing lengths. Token lengths are
taken from the `prompt_tokens` the endpoint itself reports.

### Calibrate (per endpoint, once)

Send a fresh calibration prompt twice. If the second response reports no
cached tokens after three attempts, the endpoint has no usable cache
telemetry and every pair involving it is `inconclusive`. Otherwise record
the cache-chunk length `b` as the smallest observed gap between
`prompt_tokens` and `cached_tokens`, rounded up to the chunk size the
provider documents when known.

### Profile

One short streaming request per endpoint; record time to first token; sort
endpoints by it; order candidate pairs by increasing rank distance
(neighbours first). Profile only changes the order of testing.

### Flood(A, P)

Send `P` through A repeatedly. A response is a **hit** when
`cached_tokens >= prompt_tokens(P) - b`. Stop when `N_flood` consecutive
hits are seen. Abort with failure after `A_max` attempts or `E_abort`
consecutive transport errors. On success start `w` low-rate keep-warm
workers that keep sending `P` through A until Prove ends.

### Prove(B, ladder)

Probe B starting at the shortest prefix. Count successful probes `n`, hits
`h`, misses `m`.

- A hit keeps the current prefix.
- A miss moves to the next longer prefix, because the miss may itself have
  cached the prefix it probed (the *self-hit* problem). The stride between
  ladder steps is larger than `b`, so state created by a miss at one step
  cannot satisfy the hit test at the next.
- A timeout also consumes the current prefix but is not counted in `n`.
- Other transport errors are not counted and do not move the ladder.

Outcomes:

| Outcome | Condition |
|---|---|
| `no_observed` | `h = 0` and `m = M_nohit` |
| `partial` | `h > 0` and `m >= M_partial` |
| `contained` | `n = N_prove` reached with `m <= M_contain` |
| `inconclusive` | ladder exhausted, `E_abort` consecutive errors, or `n = N_prove` with `m > M_contain` |

### Classify(A, B)

Run both directions with independent fresh prompts.

| A floods, B probes | B floods, A probes | Pair relation |
|---|---|---|
| contained | contained | `clone` (equivalent cache reach) |
| contained | not contained | `B ≺ A` (B's reach is inside A's) |
| not contained | contained | `A ≺ B` |
| partial in either, contained in neither | | `partial` (shared reach, no containment) |
| no_observed | no_observed | `no_observed` |
| inconclusive in either | | `inconclusive` |

### BuildGraph

Test pairs in Profile order. Before testing a pair, skip it if its relation
is already implied by transitivity of containment (`A ≺ B` and `B ≺ C`
imply `A ≺ C`; clones are interchangeable). Output:

- Markdown: a Mermaid graph. Containment is a directed edge from the
  containing endpoint to the contained one, clones are joined by a double
  line, partial sharing is a dashed line, inconclusive pairs are listed
  under the graph and never drawn as "no edge".
- JSON: an adjacency list with, for every tested direction, the outcome and
  its `(n, h, m)` counts, plus the list of pairs skipped by implication.

## Statistical test and null hypothesis

All thresholds follow from a resolution `delta` and a per-direction
significance level `alpha`, exactly as in Section III of the paper.

- **Flood stop.** If at least `delta` of A's routing mass were still
  uncovered, each request would hit with probability at most `1 - delta`.
  `N_flood` is the smallest `n` with `(1 - delta)^n <= alpha`.
- **Contained.** Null: at least `delta` of B's routing mass is not covered
  by the planted state. `N_prove` is the smallest `N` with
  `P[Binomial(N, delta) <= M_contain] <= alpha`.
- **No sharing observed.** Null: at least `delta` of B's routing mass is
  covered. `M_nohit` is the smallest `m` with `(1 - delta)^m <= alpha`.
- **Partial.** Null: containment holds at resolution `delta`. `M_partial`
  is the smallest `m` with
  `P[Binomial(N_prove, delta) >= m] <= alpha`.
- `L_probe = M_nohit`, the most prefixes a no-hit decision can consume.

Two presets are fixed in advance:

| Parameter | `paper` (`delta = 0.05`) | `coarse` (`delta = 0.20`) |
|---|---|---|
| `alpha` | 0.05 | 0.05 |
| `N_flood` | 59 | 14 |
| `M_contain` | 4 | 2 |
| `N_prove` | 181 | 30 |
| `M_partial` | 15 | 11 |
| `M_nohit` | 59 | 14 |
| `L_probe` | 59 | 14 |
| `A_max` (flood attempts) | 1000 | 250 |
| `E_abort` | 8 | 8 |
| keep-warm workers `w` | 2 | 2 |

The `paper` column reproduces the paper's numbers and the implementation
must derive them from the formulas above (this is a unit test). The
`coarse` preset uses the same formulas at a resolution a free-tier rate
limit can afford; it detects only sharing that covers at least 80% of an
endpoint's routing mass as containment, and misses sharing below 20%.

Each directional decision has error at most `alpha` at resolution `delta`
under the two assumptions. The level is per direction, as in the paper: it
is not corrected for the number of pairs, and the report says how many
directions were tested so the reader can judge.

## Request budget

Per direction, successful requests only:

| Preset | Flood (minimum) | Prove (maximum) | Per pair, both directions |
|---|---|---|---|
| `paper` | 59 | 181 | about 480 plus keep-warm |
| `coarse` | 14 | 30 | about 90 plus keep-warm |

Prompts are long (above the provider's minimum cacheable length, typically
1024 tokens), so token cost dominates. The step is `profile_gated` outside
the `full` profile and `not_applicable` when fewer than two endpoints are
given.

## Early-stopping rule

Built into Prove: it returns `no_observed` after `M_nohit` straight misses
and `partial` as soon as `M_partial` misses follow at least one hit. Only
`contained` needs the full `N_prove`.

## Inconclusive conditions

- The endpoint reports no cached-token count, or calibration finds no
  cache.
- Flood fails (attempt cap or error cap).
- Prove exhausts the ladder or hits the error cap.
- Rate limiting stops a direction before a decision.
- `prompt_tokens` is missing, so prefix lengths cannot be calibrated.

A pair that is inconclusive is reported as unknown, never as unrelated.

## Known evasions and failure modes

- **Hiding telemetry.** A relay that strips or zeroes the cached-token
  count removes itself from the map. The result is an under-approximation:
  a missing relation is unknown, not absent.
- **Reporting fake hits.** A relay could report cached tokens it did not
  get. That breaks Assumption 1 and would create a false relation; Receipt
  cannot detect it from one endpoint alone.
- **Unstable routing.** Fallbacks, quota exhaustion or load shedding during
  the window break Assumption 2 and usually turn a real containment into
  `partial` or `inconclusive`.
- **Cache expiry.** Long runs can outlive the cache lifetime in spite of
  keep-warm traffic.
- **Containment is not supply.** `B ≺ A` is equally consistent with A
  buying from B and with both buying from overlapping third parties.
