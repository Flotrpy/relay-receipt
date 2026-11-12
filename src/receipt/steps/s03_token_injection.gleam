//// Step 3: Token injection.
////
//// A relay that prepends a hidden system prompt bills more prompt tokens
//// than the text the user sent accounts for.
////
//// Reference method: send the same controlled texts to the endpoint and
//// to a trusted reference serving the same model, and compare billed
//// prompt tokens. If the two count alike up to one fixed offset (the
//// shift-invariant score of arXiv:2608.29930 is at least 0.725), that
//// offset is the extra prompt the endpoint bills for. Missing counts make
//// the result uninformative, never zero.
////
//// Estimate method (no reference): compare with a rough estimate of the
//// expected count. Cut-offs: `docs/THRESHOLDS.md`.

import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/string
import receipt/api/types as api
import receipt/config.{Full, General}
import receipt/ctx.{type Ctx}
import receipt/endpoint.{type Endpoint}
import receipt/probes/texts
import receipt/report/block.{Paragraph, Table}
import receipt/seq
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Anomaly, Clean}

const id = 3

/// Billed prompt tokens for one text: endpoint and reference.
pub type Pair {
  Pair(endpoint: Option(Int), reference: Option(Int))
}

pub type Repeat {
  Repeat(
    /// Pairs where both counts are present.
    valid: Int,
    total: Int,
    /// Whether the validity gates are met.
    informative: Bool,
    /// Most frequent offset among valid pairs, if any.
    modal_offset: Option(Int),
    /// Share of valid pairs whose offset equals the mode.
    score: Float,
  )
}

fn offsets(pairs: List(Pair)) -> List(Int) {
  list.filter_map(pairs, fn(pair) {
    case pair.endpoint, pair.reference {
      Some(endpoint), Some(reference) -> Ok(endpoint - reference)
      _, _ -> Error(Nil)
    }
  })
}

/// The most frequent value; ties go to the smallest absolute value, then
/// to the smaller value, so the result is deterministic.
pub fn mode(values: List(Int)) -> Option(Int) {
  values
  |> list.fold(dict.new(), fn(tally, value) {
    dict.upsert(tally, value, fn(existing) {
      case existing {
        Some(count) -> count + 1
        None -> 1
      }
    })
  })
  |> dict.to_list
  |> list.sort(fn(a, b) {
    int.compare(b.1, a.1)
    |> order_then(int.compare(int.absolute_value(a.0), int.absolute_value(b.0)))
    |> order_then(int.compare(a.0, b.0))
  })
  |> list.first
  |> option.from_result
  |> option.map(fn(pair) { pair.0 })
}

fn order_then(first: Order, second: Order) -> Order {
  case first {
    order.Eq -> second
    _ -> first
  }
}

/// Summarise one repeat under the validity gates.
pub fn analyse_repeat(pairs: List(Pair)) -> Repeat {
  let total = list.length(pairs)
  let found = offsets(pairs)
  let valid = list.length(found)
  let coverage = case total {
    0 -> 0.0
    _ -> int.to_float(valid) /. int.to_float(total)
  }
  let modal = mode(found)
  let score = case modal, valid {
    Some(m), valid if valid > 0 ->
      int.to_float(list.count(found, fn(offset) { offset == m }))
      /. int.to_float(valid)
    _, _ -> 0.0
  }
  Repeat(
    valid: valid,
    total: total,
    informative: valid >= thresholds.injection_min_valid_pairs
      && coverage >=. thresholds.injection_min_coverage,
    modal_offset: modal,
    score: score,
  )
}

pub type Decision {
  /// Not every repeat passed the validity gates.
  NotEligible
  /// The endpoints do not count tokens alike; the offset means nothing.
  NotComparable(score: Float)
  /// Comparable, with this many extra prompt tokens billed per request.
  Offset(tokens: Int, score: Float)
}

/// Combine repeats into a decision.
pub fn decide(repeats: List(Repeat), all_pairs: List(Pair)) -> Decision {
  case repeats != [] && list.all(repeats, fn(repeat) { repeat.informative }) {
    False -> NotEligible
    True -> {
      let score =
        float.sum(list.map(repeats, fn(repeat) { repeat.score }))
        /. int.to_float(list.length(repeats))
      case
        score >=. thresholds.injection_score_threshold,
        mode(offsets(all_pairs))
      {
        True, Some(tokens) -> Offset(tokens, score)
        _, _ -> NotComparable(score)
      }
    }
  }
}

fn prompt_tokens(
  ctx: Ctx,
  endpoint: Endpoint,
  label: String,
  system: String,
  text: String,
) -> Option(Int) {
  let params = api.simple(endpoint.model, text, 1) |> api.with_temperature(0.0)
  let params = case system {
    "" -> params
    system -> api.with_system(params, system)
  }
  case ctx.rate_limited_out(ctx, endpoint) {
    True -> None
    False ->
      ctx.chat(ctx, endpoint, id, label, params)
      |> result.map(fn(completion) { completion.usage.prompt_tokens })
      |> result.unwrap(None)
  }
}

pub fn run(ctx: Ctx) -> StepResult {
  case ctx.reference {
    Some(reference) -> run_reference(ctx, reference)
    None -> run_estimate(ctx)
  }
}

fn run_reference(ctx: Ctx, reference: Endpoint) -> StepResult {
  let repeats = case ctx.profile {
    General -> thresholds.injection_repeats_general
    Full -> thresholds.injection_repeats_full
  }
  let runs =
    seq.range(1, repeats)
    |> list.map(fn(repeat) {
      texts.all()
      |> list.index_map(fn(text, index) {
        let label =
          "r" <> int.to_string(repeat) <> "/t" <> int.to_string(index + 1)
        Pair(
          endpoint: prompt_tokens(ctx, ctx.target, label, "", text),
          reference: prompt_tokens(ctx, reference, label, "", text),
        )
      })
    })
  reference_result(list.map(runs, analyse_repeat), list.flatten(runs))
}

/// Turn the analysis of the reference method into a step result.
pub fn reference_result(
  repeats: List(Repeat),
  pairs: List(Pair),
) -> StepResult {
  let decision = decide(repeats, pairs)
  let rows =
    list.index_map(repeats, fn(repeat, index) {
      [
        int.to_string(index + 1),
        int.to_string(repeat.valid) <> " of " <> int.to_string(repeat.total),
        case repeat.informative {
          True -> "yes"
          False -> "no"
        },
        option.map(repeat.modal_offset, int.to_string) |> option.unwrap("-"),
        float.to_string(float.to_precision(repeat.score, 3)),
      ]
    })
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("method", json.string("reference"))
    |> step.with_data("valid_pairs", json.int(list.length(offsets(pairs))))
    |> step.with_data("total_pairs", json.int(list.length(pairs)))
    |> step.with_data("score", json.nullable(score_of(decision), json.float))
    |> step.with_data(
      "modal_offset",
      json.nullable(
        case decision {
          Offset(tokens, _) -> Some(tokens)
          _ -> None
        },
        json.int,
      ),
    )
    |> step.with_details([
      Paragraph(
        "Billed prompt tokens for 30 controlled texts, endpoint minus reference.",
      ),
      Table(
        ["Repeat", "Valid pairs", "Informative", "Modal offset", "Score"],
        rows,
      ),
    ])
  }
  case decision {
    NotEligible ->
      step.inconclusive(
        id,
        "usage_missing",
        "Too few texts returned a prompt-token count from both endpoints to compare them.",
      )
      |> decorate
    NotComparable(score) ->
      step.inconclusive(
        id,
        "counts_not_comparable",
        "The endpoint and the reference do not count tokens alike (score "
          <> float.to_string(float.to_precision(score, 3))
          <> ", below 0.725), so the difference cannot be read as an added prompt.",
      )
      |> decorate
      |> step.with_finding(
        step.Note,
        "A low score can mean a different tokenizer or chat template. arXiv:2608.29930 shows this signal alone does not identify a model family.",
      )
    Offset(tokens, _) -> offset_result(tokens) |> decorate
  }
}

fn score_of(decision: Decision) -> Option(Float) {
  case decision {
    NotEligible -> None
    NotComparable(score) | Offset(_, score) -> Some(score)
  }
}

fn offset_result(tokens: Int) -> StepResult {
  let stated = int.to_string(tokens)
  case
    tokens > thresholds.injection_anomaly_tokens,
    tokens > thresholds.injection_clean_tokens,
    tokens < 0 - thresholds.injection_clean_tokens
  {
    True, _, _ ->
      step.ran(
        id,
        Anomaly,
        "The endpoint bills "
          <> stated
          <> " more prompt tokens per request than the reference for the same text: a signal of an added prompt.",
      )
      |> step.with_finding(
        step.Signal,
        "Constant extra prompt tokens are consistent with a hidden system prompt of about that size. They do not show what the prompt says or who added it.",
      )
    False, True, _ ->
      step.inconclusive(
        id,
        "small_offset",
        "The endpoint bills "
          <> stated
          <> " more prompt tokens per request than the reference: more than a template difference usually explains, less than the anomaly cut-off.",
      )
    False, False, True ->
      step.inconclusive(
        id,
        "negative_offset",
        "The endpoint bills "
          <> stated
          <> " prompt tokens relative to the reference, that is, fewer. This is unexpected and not interpreted.",
      )
    False, False, False ->
      step.ran(
        id,
        Clean,
        "Billed prompt tokens match the reference up to a constant offset of "
          <> stated
          <> ".",
      )
  }
}

/// Rough expected prompt tokens for the estimate method.
pub fn estimate_tokens(system: String, text: String) -> Int {
  let characters = string.length(system) + string.length(text)
  { characters + 3 } / 4 + thresholds.injection_estimate_overhead
}

fn run_estimate(ctx: Ctx) -> StepResult {
  texts.minimal()
  |> list.index_map(fn(probe, index) {
    let #(system, text) = probe
    let billed =
      prompt_tokens(
        ctx,
        ctx.target,
        "minimal/" <> int.to_string(index + 1),
        system,
        text,
      )
    #(estimate_tokens(system, text), billed)
  })
  |> estimate_result
}

/// Turn `#(expected, billed)` observations into a step result.
pub fn estimate_result(observations: List(#(Int, Option(Int)))) -> StepResult {
  let deltas =
    list.filter_map(observations, fn(observation) {
      case observation.1 {
        Some(billed) -> Ok(billed - observation.0)
        None -> Error(Nil)
      }
    })
  let rows =
    list.index_map(observations, fn(observation, index) {
      [
        int.to_string(index + 1),
        "about " <> int.to_string(observation.0),
        option.map(observation.1, int.to_string)
          |> option.unwrap("not reported"),
      ]
    })
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("method", json.string("estimate"))
    |> step.with_data(
      "delta",
      json.nullable(option.from_result(list.reduce(deltas, int.max)), json.int),
    )
    |> step.with_finding(
      step.Limit,
      "No trusted reference was configured, so expected counts are a rough estimate (characters / 4 + 12), not a measurement.",
    )
    |> step.with_details([
      Table(["Probe", "Expected prompt tokens", "Billed"], rows),
    ])
  }
  case list.reduce(deltas, int.max) {
    Error(Nil) ->
      step.inconclusive(
        id,
        "usage_missing",
        "No probe returned a prompt-token count.",
      )
      |> decorate
    Ok(delta) ->
      case
        delta > thresholds.injection_anomaly_tokens,
        delta > thresholds.injection_clean_tokens
      {
        True, _ ->
          step.ran(
            id,
            Anomaly,
            "A minimal message was billed about "
              <> int.to_string(delta)
              <> " more prompt tokens than its text accounts for: a signal of an added prompt.",
          )
          |> decorate
        False, True ->
          step.inconclusive(
            id,
            "small_delta",
            "A minimal message was billed about "
              <> int.to_string(delta)
              <> " more prompt tokens than estimated; too small to call without a reference.",
          )
          |> decorate
        False, False ->
          step.ran(
            id,
            Clean,
            "Billed prompt tokens are within the estimate for minimal messages.",
          )
          |> decorate
      }
  }
}
