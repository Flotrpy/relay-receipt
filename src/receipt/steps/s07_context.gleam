//// Step 7: Context truncation scan.
////
//// Plants five canary markers at even intervals through a long input and
//// asks the model to list them. A relay that silently drops part of a
//// long prompt loses the markers at one end. Missing markers in any other
//// pattern look like an ordinary recall failure and are inconclusive, as
//// are sizes refused for length or rate. Cut-offs: `docs/THRESHOLDS.md`.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/chat
import receipt/api/types as api
import receipt/config.{Full, General}
import receipt/ctx.{type Ctx}
import receipt/prng.{type Prng}
import receipt/report/block.{Table}
import receipt/seq
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Anomaly, Clean}

const id = 7

const filler =
  "The archive keeps one plain record per line so that nothing here needs to be remembered. "

const instruction =
  "The text below contains 5 markers that look like [CANARY-1-a1b2c3d4]. List every marker you can find, one per line, and nothing else.\n\n"

/// Five markers, unique to this request.
pub fn canaries(prng: Prng) -> #(List(String), Prng) {
  seq.range(1, thresholds.context_canaries)
  |> list.fold(#([], prng), fn(acc, number) {
    let #(markers, prng) = acc
    let #(value, prng) = prng.int_below(prng, 0xFFFFFFFF)
    let hex = string.pad_start(string.lowercase(int.to_base16(value)), 8, "0")
    #(
      [#(number, "CANARY-" <> int.to_string(number) <> "-" <> hex), ..markers],
      prng,
    )
  })
  |> fn(pair) { #(list.reverse(pair.0) |> list.map(fn(m) { m.1 }), pair.1) }
}

/// A prompt of about `size` characters with the markers evenly spaced:
/// first at the start, last at the end.
pub fn build_prompt(markers: List(String), size: Int) -> String {
  let gaps = int.max(1, list.length(markers) - 1)
  let marker_chars =
    list.fold(markers, 0, fn(total, marker) {
      total + string.length(marker) + 2
    })
  let gap_chars =
    int.max(0, { size - marker_chars - string.length(instruction) } / gaps)
  let padding =
    string.repeat(filler, gap_chars / string.length(filler) + 1)
    |> string.slice(0, gap_chars)
  let body =
    list.map(markers, fn(marker) { "[" <> marker <> "]" })
    |> string.join(padding)
  instruction <> body
}

/// Zero-based positions of the markers a reply does not contain.
pub fn missing(markers: List(String), reply: String) -> List(Int) {
  list.index_map(markers, fn(marker, index) { #(index, marker) })
  |> list.filter(fn(pair) { !string.contains(reply, pair.1) })
  |> list.map(fn(pair) { pair.0 })
}

pub type Side {
  Head
  Tail
}

/// Whether the missing positions form a block at one end: some, but not
/// all, markers are gone, and they are the first k or the last k.
pub fn edge_block(missing: List(Int), total: Int) -> Option(Side) {
  let count = list.length(missing)
  case count > 0 && count < total {
    False -> None
    True ->
      case
        missing == seq.range(0, count - 1),
        missing == seq.range(total - count, total - 1)
      {
        True, _ -> Some(Head)
        _, True -> Some(Tail)
        False, False -> None
      }
  }
}

pub type Attempt {
  /// A reply, with the positions of the markers it lacks.
  Replied(missing: List(Int), prompt_tokens: Option(Int))
  /// Refused for size or rate.
  Limit(detail: String)
  /// Any other failure.
  Failed(detail: String)
}

pub type Outcome {
  AllFound
  EdgeTruncated(side: Side)
  RecallMiss
  HitLimit
  NoReply
}

/// Classify a size from its first attempt and, when markers were missing,
/// its confirming second attempt.
pub fn classify(first: Attempt, second: Option(Attempt)) -> Outcome {
  let total = thresholds.context_canaries
  case first, second {
    Replied([], _), _ -> AllFound
    Limit(_), _ -> HitLimit
    Failed(_), _ -> NoReply
    Replied(a, _), Some(Replied(b, _)) ->
      case edge_block(a, total), edge_block(b, total) {
        Some(side_a), Some(side_b) if side_a == side_b -> EdgeTruncated(side_a)
        _, _ -> RecallMiss
      }
    Replied(_, _), _ -> RecallMiss
  }
}

/// The sizes to test, largest first removed when above the context cap.
pub fn sizes(
  profile: config.Profile,
  context_window: Option(Int),
) -> List(Int) {
  let ladder = case profile {
    General -> thresholds.context_sizes_general
    Full -> thresholds.context_sizes_full
  }
  case context_window {
    None -> ladder
    Some(tokens) -> {
      let cap =
        float.truncate(
          int.to_float(tokens * thresholds.context_chars_per_token)
          *. thresholds.context_window_fraction,
        )
      list.filter(ladder, fn(size) { size <= cap })
    }
  }
}

fn attempt(ctx: Ctx, size: Int, round: Int, prng: Prng) -> #(Attempt, Prng) {
  let #(markers, prng) = canaries(prng)
  let params =
    api.simple(ctx.target.model, build_prompt(markers, size), 256)
    |> api.with_temperature(0.0)
  let label = int.to_string(size) <> "/" <> int.to_string(round)
  let outcome =
    ctx.chat_within(
      ctx,
      ctx.target,
      id,
      label,
      params,
      thresholds.long_request_timeout_ms,
    )
  #(
    case outcome {
      Ok(completion) ->
        Replied(
          missing(markers, completion.text),
          completion.usage.prompt_tokens,
        )
      Error(error) ->
        case chat.is_size_limit(error) || chat.is_rate_limited(error) {
          True -> Limit(chat.describe(error))
          False -> Failed(chat.describe(error))
        }
    },
    prng,
  )
}

pub type SizeResult {
  SizeResult(size: Int, outcome: Outcome, first: Attempt)
}

pub fn run(ctx: Ctx) -> StepResult {
  let #(results, _, _) =
    sizes(ctx.profile, ctx.context_window)
    |> list.fold(#([], ctx.prng(ctx, id), False), fn(acc, size) {
      let #(results, prng, stopped) = acc
      case stopped {
        // A smaller size was already refused; larger ones would be too.
        True -> #(results, prng, True)
        False -> {
          let #(first, prng) = attempt(ctx, size, 1, prng)
          let #(second, prng) = case first {
            Replied([_, ..], _) -> {
              let #(second, prng) = attempt(ctx, size, 2, prng)
              #(Some(second), prng)
            }
            _ -> #(None, prng)
          }
          let outcome = classify(first, second)
          #(
            [SizeResult(size, outcome, first), ..results],
            prng,
            outcome == HitLimit,
          )
        }
      }
    })
  build(list.reverse(results))
}

fn describe(outcome: Outcome) -> String {
  case outcome {
    AllFound -> "all 5 markers recalled"
    EdgeTruncated(Head) -> "markers at the start missing in both attempts"
    EdgeTruncated(Tail) -> "markers at the end missing in both attempts"
    RecallMiss -> "some markers missing, no positional pattern"
    HitLimit -> "refused for size or rate"
    NoReply -> "no reply"
  }
}

pub fn build(results: List(SizeResult)) -> StepResult {
  let rows =
    list.map(results, fn(result) {
      [
        int.to_string(result.size),
        case result.first {
          Replied(_, Some(tokens)) -> int.to_string(tokens)
          _ -> "-"
        },
        describe(result.outcome),
      ]
    })
  let decorate = fn(step_result: StepResult) {
    step_result
    |> step.with_data(
      "sizes",
      json.array(results, fn(result) {
        json.object([
          #("characters", json.int(result.size)),
          #("outcome", json.string(describe(result.outcome))),
        ])
      }),
    )
    |> step.with_details([
      Table(["Characters", "Billed prompt tokens", "Outcome"], rows),
    ])
  }
  let has = fn(wanted: fn(Outcome) -> Bool) {
    list.any(results, fn(result) { wanted(result.outcome) })
  }
  let truncated =
    list.find(results, fn(result) {
      case result.outcome {
        EdgeTruncated(_) -> True
        _ -> False
      }
    })
  let largest_ok =
    list.filter(results, fn(result) { result.outcome == AllFound })
    |> list.map(fn(result) { result.size })
    |> list.reduce(int.max)
  case truncated, results, largest_ok {
    Ok(result), _, _ ->
      step.ran(
        id,
        Anomaly,
        "At "
          <> int.to_string(result.size)
          <> " characters the "
          <> describe(result.outcome)
          <> ": a signal that part of the prompt did not reach the model.",
      )
      |> step.with_finding(
        step.Limit,
        "A model that ignores the start or end of a long input would look the same. Compare with the trusted reference at the same size before drawing conclusions.",
      )
      |> decorate
    Error(Nil), [], _ ->
      step.inconclusive(
        id,
        "no_sizes",
        "No size fits below 60% of the stated context window.",
      )
      |> decorate
    Error(Nil), _, Error(Nil) ->
      step.inconclusive(
        id,
        case has(fn(o) { o == HitLimit }) {
          True -> "size_or_rate_limit"
          False -> "no_replies"
        },
        "No tested size returned all markers.",
      )
      |> decorate
    Error(Nil), _, Ok(size) ->
      case has(fn(o) { o != AllFound }) {
        False ->
          step.ran(
            id,
            Clean,
            "All markers were recalled at every tested size, up to "
              <> int.to_string(size)
              <> " characters.",
          )
          |> step.with_finding(
            step.Limit,
            "Truncation above the largest tested size would not be seen.",
          )
          |> decorate
        True ->
          step.inconclusive(
            id,
            case has(fn(o) { o == HitLimit }) {
              True -> "size_or_rate_limit"
              False -> "recall_miss"
            },
            "Markers were recalled up to "
              <> int.to_string(size)
              <> " characters; a larger size was refused or returned an incomplete list with no positional pattern.",
          )
          |> decorate
      }
  }
}
