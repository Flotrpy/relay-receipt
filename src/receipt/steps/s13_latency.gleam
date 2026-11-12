//// Step 13: Latency variance.
////
//// Sends identical minimal requests and looks at the spread of their
//// latencies. A relay that sends some requests to one backend and some to
//// another can show two clusters. This is a weak signal: network jitter
//// and provider load produce the same picture, so the step is always
//// `informational`. Cut-offs are api-relay-audit's; Receipt adds robust
//// summaries (median, MAD) that one slow request cannot distort.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import receipt/api/chat
import receipt/api/types as api
import receipt/client
import receipt/ctx.{type Ctx}
import receipt/report/block.{Table}
import receipt/seq
import receipt/stats/descriptive
import receipt/stats/robust
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Informational}

const id = 13

pub const probe_prompt = "Reply with the single word: ok"

pub type Shape {
  TooFew
  Bimodal
  Stable
  Variable
  HighVariance
}

/// Classify latencies given in milliseconds.
pub fn classify(latencies_ms: List(Float)) -> Shape {
  case list.length(latencies_ms) < thresholds.latency_probes_min {
    True -> TooFew
    False ->
      case robust.is_bimodal(latencies_ms, thresholds.latency_bimodal_gap) {
        True -> Bimodal
        False ->
          case descriptive.coefficient_of_variation(latencies_ms) {
            Ok(cv) if cv <. thresholds.latency_cv_stable -> Stable
            Ok(cv) if cv <. thresholds.latency_cv_variable -> Variable
            Ok(_) -> HighVariance
            Error(Nil) -> Stable
          }
      }
  }
}

pub fn shape_to_string(shape: Shape) -> String {
  case shape {
    TooFew -> "too_few_samples"
    Bimodal -> "bimodal"
    Stable -> "stable"
    Variable -> "variable"
    HighVariance -> "high_variance"
  }
}

pub fn run(ctx: Ctx) -> StepResult {
  let params =
    api.simple(ctx.target.model, probe_prompt, thresholds.latency_max_tokens)
    |> api.with_temperature(0.0)
  let request = chat.build(ctx.target, params, thresholds.request_timeout_ms)
  let latencies =
    seq.range(1, ctx.latency_probes)
    |> list.filter_map(fn(index) {
      // Single attempts: a retry would fold a failure into the latency.
      case
        client.attempt(
          ctx.net,
          ctx.target.name,
          id,
          "probe/" <> int.to_string(index),
          request,
        )
      {
        Ok(response) if response.status >= 200 && response.status < 300 ->
          case response.timing.done_us {
            Some(done_us) -> Ok(int.to_float(done_us) /. 1000.0)
            None -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  build(latencies, ctx.latency_probes)
}

fn show(value: Result(Float, Nil)) -> String {
  case value {
    Ok(number) -> float.to_string(float.to_precision(number, 1))
    Error(Nil) -> "-"
  }
}

pub fn build(latencies_ms: List(Float), attempted: Int) -> StepResult {
  let shape = classify(latencies_ms)
  let count = list.length(latencies_ms)
  let number = fn(value: Result(Float, Nil)) {
    json.nullable(
      case value {
        Ok(found) -> Some(float.to_precision(found, 3))
        Error(Nil) -> None
      },
      json.float,
    )
  }
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("shape", json.string(shape_to_string(shape)))
    |> step.with_data("samples", json.int(count))
    |> step.with_data("median_ms", number(descriptive.median(latencies_ms)))
    |> step.with_data("mad_ms", number(robust.mad(latencies_ms)))
    |> step.with_data(
      "cv",
      number(descriptive.coefficient_of_variation(latencies_ms)),
    )
    |> step.with_data("robust_cv", number(robust.robust_cv(latencies_ms)))
    |> step.with_details([
      Table(["Measure", "Milliseconds"], [
        ["Samples", int.to_string(count) <> " of " <> int.to_string(attempted)],
        ["Minimum", show(descriptive.minimum(latencies_ms))],
        ["Median", show(descriptive.median(latencies_ms))],
        ["Maximum", show(descriptive.maximum(latencies_ms))],
        ["Mean", show(descriptive.mean(latencies_ms))],
        [
          "Standard deviation",
          show(descriptive.standard_deviation(latencies_ms)),
        ],
        ["Median absolute deviation", show(robust.mad(latencies_ms))],
      ]),
    ])
  }
  case shape {
    TooFew ->
      step.inconclusive(
        id,
        "too_few_samples",
        "Only "
          <> int.to_string(count)
          <> " of "
          <> int.to_string(attempted)
          <> " latency probes succeeded; at least 3 are needed.",
      )
      |> decorate
    Bimodal ->
      step.ran(
        id,
        Informational,
        "Latencies of identical requests fall into two clusters.",
      )
      |> step.with_finding(
        step.Signal,
        "Two latency clusters are consistent with requests reaching different backends, and equally with caching, cold starts or network routing. On its own this shows nothing.",
      )
      |> decorate
    Stable ->
      step.ran(id, Informational, "Latencies of identical requests are stable.")
      |> decorate
    Variable ->
      step.ran(
        id,
        Informational,
        "Latencies of identical requests vary moderately.",
      )
      |> decorate
    HighVariance ->
      step.ran(
        id,
        Informational,
        "Latencies of identical requests vary widely, without two clear clusters.",
      )
      |> decorate
  }
}
