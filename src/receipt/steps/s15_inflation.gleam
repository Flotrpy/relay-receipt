//// Step 15: Inflation probe.
////
//// The saturation single-probe audit of arXiv:2609.20370 (Section 4.3,
//// Algorithm 1), implemented as specified in
//// `docs/steps/15-inflation.md`. If a service is already lengthening its
//// answers, asking for a longer answer adds much less than it does on
//// normal service.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import receipt/api/types as api
import receipt/ctx.{type Ctx}
import receipt/prng.{type Prng}
import receipt/probes/questions.{type Question}
import receipt/report/block.{Paragraph, Table}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Anomaly, Clean}

const id = 15

/// What one request produced.
pub type Length {
  /// Visible output tokens.
  Tokens(count: Int)
  /// The reply stopped at the token limit.
  Truncated
  /// The request failed or reported no output-token count.
  Unavailable
}

pub type Pair {
  Pair(question: String, probe: String, original: Length, probed: Length)
}

pub type Evidence {
  Evidence(delta: Int, relative_gain: Float, score: Int)
}

/// Question-level evidence of Algorithm 1 for output lengths `l0`
/// (original) and `l1` (probed).
pub fn evidence(l0: Int, l1: Int) -> Evidence {
  let delta = l1 - l0
  let gain = int.to_float(int.max(delta, 0)) /. int.to_float(l0 + 1)
  let direction = case delta <= 0 {
    True -> 1
    False -> 0
  }
  let small = case gain <=. thresholds.inflation_tau {
    True -> 1
    False -> 0
  }
  Evidence(delta, gain, direction + small)
}

/// The evidence of a pair, or `None` when the pair is invalid.
pub fn pair_evidence(pair: Pair) -> Option(Evidence) {
  case pair.original, pair.probed {
    Tokens(l0), Tokens(l1) -> Some(evidence(l0, l1))
    _, _ -> None
  }
}

/// The sum of the k largest scores.
pub fn top_k_sum(scores: List(Int), k: Int) -> Int {
  list.sort(scores, fn(a, b) { int.compare(b, a) })
  |> list.take(k)
  |> int.sum
}

pub type Decision {
  /// S reached the threshold.
  Signal(statistic: Int)
  /// The full run finished with enough valid pairs and S below the
  /// threshold.
  NoSignal(statistic: Int)
  /// Too few valid pairs to call it clean.
  Undecided(statistic: Int, valid: Int)
}

/// The aggregate statistic S over the valid pairs.
pub fn statistic(pairs: List(Pair)) -> Int {
  list.filter_map(pairs, fn(pair) { option.to_result(pair_evidence(pair), Nil) })
  |> list.map(fn(found) { found.score })
  |> top_k_sum(thresholds.inflation_top_k)
}

pub fn valid_count(pairs: List(Pair)) -> Int {
  list.count(pairs, fn(pair) { pair_evidence(pair) != None })
}

/// Decide from the pairs collected. `finished` is whether every planned
/// question was asked.
pub fn decide(pairs: List(Pair), finished: Bool) -> Decision {
  let s = statistic(pairs)
  let valid = valid_count(pairs)
  case
    s >= thresholds.inflation_threshold,
    finished && valid >= thresholds.inflation_min_valid_pairs
  {
    True, _ -> Signal(s)
    False, True -> NoSignal(s)
    False, False -> Undecided(s, valid)
  }
}

type Planned {
  Planned(question: Question, probe: String)
}

fn plan(prng: Prng) -> #(List(Planned), Prng) {
  let #(chosen, prng) =
    prng.sample(questions.pool(), thresholds.inflation_questions, prng)
  list.fold(chosen, #([], prng), fn(acc, question) {
    let #(planned, prng) = acc
    let #(coin, prng) = prng.int_below(prng, 2)
    let probe = case coin {
      0 -> questions.probe_a
      _ -> questions.probe_b
    }
    #([Planned(question, probe), ..planned], prng)
  })
  |> fn(pair) { #(list.reverse(pair.0), pair.1) }
}

fn measure(ctx: Ctx, label: String, prompt: String) -> Length {
  let params =
    api.simple(ctx.target.model, prompt, thresholds.inflation_max_tokens)
    |> api.with_temperature(0.0)
  case ctx.chat(ctx, ctx.target, id, label, params) {
    Error(_) -> Unavailable
    Ok(completion) ->
      case
        completion.finish_reason,
        api.visible_output_tokens(completion.usage)
      {
        Some("length"), _ | Some("max_tokens"), _ -> Truncated
        _, Some(count) -> Tokens(count)
        _, None -> Unavailable
      }
  }
}

/// Ask one block of questions, with the block's requests in a seeded
/// random order so an original and its probed twin are not adjacent in a
/// fixed pattern.
fn ask_block(
  ctx: Ctx,
  block: List(Planned),
  prng: Prng,
) -> #(List(Pair), Prng) {
  let requests =
    list.flat_map(block, fn(planned) {
      [
        #(planned.question.id, False, questions.render(planned.question)),
        #(
          planned.question.id,
          True,
          questions.render_probed(planned.question, planned.probe),
        ),
      ]
    })
  let #(ordered, prng) = prng.shuffle(requests, prng)
  let results =
    list.map(ordered, fn(request) {
      let #(question_id, probed, prompt) = request
      let label =
        question_id
        <> case probed {
          True -> "/probed"
          False -> "/original"
        }
      #(question_id, probed, measure(ctx, label, prompt))
    })
  let find = fn(question_id: String, probed: Bool) {
    list.find_map(results, fn(result) {
      case result.0 == question_id && result.1 == probed {
        True -> Ok(result.2)
        False -> Error(Nil)
      }
    })
    |> option.from_result
    |> option.unwrap(Unavailable)
  }
  #(
    list.map(block, fn(planned) {
      Pair(
        question: planned.question.id,
        probe: case planned.probe == questions.probe_a {
          True -> "A"
          False -> "B"
        },
        original: find(planned.question.id, False),
        probed: find(planned.question.id, True),
      )
    }),
    prng,
  )
}

pub fn run(ctx: Ctx) -> StepResult {
  let #(planned, prng) = plan(ctx.prng(ctx, id))
  let blocks = list.sized_chunk(planned, thresholds.inflation_block)
  let #(pairs, finished) = ask_blocks(ctx, blocks, prng, [])
  build(pairs, finished)
}

fn ask_blocks(
  ctx: Ctx,
  blocks: List(List(Planned)),
  prng: Prng,
  collected: List(Pair),
) -> #(List(Pair), Bool) {
  case blocks {
    [] -> #(collected, True)
    [block, ..rest] -> {
      let #(pairs, prng) = ask_block(ctx, block, prng)
      let collected = list.append(collected, pairs)
      case
        statistic(collected) >= thresholds.inflation_threshold,
        ctx.rate_limited_out(ctx, ctx.target)
      {
        // S can only grow, so the full run would decide the same.
        True, _ -> #(collected, rest == [])
        False, True -> #(collected, False)
        False, False -> ask_blocks(ctx, rest, prng, collected)
      }
    }
  }
}

fn show(length: Length) -> String {
  case length {
    Tokens(count) -> int.to_string(count)
    Truncated -> "truncated"
    Unavailable -> "-"
  }
}

fn length_json(length: Length) -> json.Json {
  case length {
    Tokens(count) -> json.int(count)
    Truncated | Unavailable -> json.null()
  }
}

pub fn build(pairs: List(Pair), finished: Bool) -> StepResult {
  let decision = decide(pairs, finished)
  let valid = valid_count(pairs)
  let rows =
    list.map(pairs, fn(pair) {
      let found = pair_evidence(pair)
      [
        pair.question,
        pair.probe,
        show(pair.original),
        show(pair.probed),
        option.map(found, fn(e) { int.to_string(e.delta) })
          |> option.unwrap("-"),
        option.map(found, fn(e) {
          float.to_string(float.to_precision(e.relative_gain, 2))
        })
          |> option.unwrap("-"),
        option.map(found, fn(e) { int.to_string(e.score) })
          |> option.unwrap("invalid"),
      ]
    })
  let s = case decision {
    Signal(s) | NoSignal(s) | Undecided(s, _) -> s
  }
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("n", json.int(list.length(pairs)))
    |> step.with_data("valid_pairs", json.int(valid))
    |> step.with_data("S", json.int(s))
    |> step.with_data("H", json.int(thresholds.inflation_threshold))
    |> step.with_data("k", json.int(thresholds.inflation_top_k))
    |> step.with_data("tau", json.float(thresholds.inflation_tau))
    |> step.with_data(
      "pairs",
      json.array(pairs, fn(pair) {
        let found = pair_evidence(pair)
        json.object([
          #("question", json.string(pair.question)),
          #("probe", json.string(pair.probe)),
          #("L0", length_json(pair.original)),
          #("L1", length_json(pair.probed)),
          #(
            "delta",
            json.nullable(option.map(found, fn(e) { e.delta }), json.int),
          ),
          #(
            "R",
            json.nullable(
              option.map(found, fn(e) { float.to_precision(e.relative_gain, 4) }),
              json.float,
            ),
          ),
          #(
            "score",
            json.nullable(option.map(found, fn(e) { e.score }), json.int),
          ),
          #("valid", json.bool(found != None)),
        ])
      }),
    )
    |> step.with_error_rate(step.ErrorRate(
      "false_positive",
      0.073,
      "the worst case measured in arXiv:2609.20370 on four open-weight models (0.02% on average with no system prompt, 1.83% on average and 7.30% at worst with a benign system prompt); not re-measured for this endpoint's model",
    ))
    |> step.with_details([
      Paragraph(
        "L0 and L1 are visible output tokens for the original and the probed question. S is the sum of the 3 largest scores; a signal needs S >= 3.",
      ),
      Table(
        ["Question", "Probe", "L0", "L1", "Delta", "Relative gain", "Score"],
        rows,
      ),
    ])
    |> step.with_finding(
      step.Limit,
      "Step 15 looks for output that is already lengthened. It cannot detect token counts that are misreported without the visible text changing.",
    )
    |> step.with_finding(
      step.Limit,
      "Misreported hidden reasoning tokens cannot be detected black-box (arXiv:2510.05181, arXiv:2605.30040).",
    )
  }
  case decision {
    Signal(s) ->
      step.ran(
        id,
        Anomaly,
        "PTIA-consistent signal: S = "
          <> int.to_string(s)
          <> " (threshold 3) over "
          <> int.to_string(valid)
          <> " valid question pairs. A request for more detail added little or no length.",
      )
      |> step.with_finding(
        step.Signal,
        "This pattern is what provider-side output lengthening produces. It is also what a model that already explains every answer at length produces. It does not show deliberate inflation.",
      )
      |> decorate
    NoSignal(s) ->
      step.ran(
        id,
        Clean,
        "No PTIA-consistent signal: S = "
          <> int.to_string(s)
          <> " (threshold 3) over "
          <> int.to_string(valid)
          <> " valid question pairs.",
      )
      |> decorate
    Undecided(s, valid) ->
      step.inconclusive(
        id,
        case finished {
          True -> "too_few_valid_pairs"
          False -> "rate_limited"
        },
        "Only "
          <> int.to_string(valid)
          <> " valid question pairs (16 needed) and S = "
          <> int.to_string(s)
          <> ", below the threshold.",
      )
      |> decorate
  }
}
