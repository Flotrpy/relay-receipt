//// Step 10: Stream (SSE) integrity.
////
//// Opens one streaming chat request and checks the event stream against
//// the rule set for its API format. A relay that rewrites or rebuilds a
//// stream often breaks one of these invariants. Rules and verdicts:
//// `docs/THRESHOLDS.md`.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/chat
import receipt/api/types.{Anthropic, OpenAi} as api
import receipt/ctx.{type Ctx}
import receipt/http/types as http
import receipt/jsonx
import receipt/report/block.{Bullets, Table}
import receipt/sse.{type Parsed, CommentItem, EventItem}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Anomaly, Clean}

const id = 10

pub const probe_prompt = "Count from 1 to 5, separated by single spaces."

const anthropic_events = [
  "ping", "message_start", "content_block_start", "content_block_delta",
  "content_block_stop", "message_delta", "message_stop", "error",
]

pub type Analysis {
  Analysis(
    /// Rule violations, in words. Empty when every rule holds.
    violations: List(String),
    events: Int,
    /// The model name the stream carried, if any.
    model: Option(String),
  )
}

type OpenAiChunk {
  OpenAiChunk(
    id: Option(String),
    model: Option(String),
    finishes: List(#(Int, Option(String))),
    prompt_tokens: Option(Int),
    completion_tokens: Option(Int),
    has_usage: Bool,
  )
}

fn openai_chunk(data: String) -> Result(OpenAiChunk, Nil) {
  let decoder = {
    use chunk_id <- decode.then(jsonx.optional_string(["id"]))
    use model <- decode.then(jsonx.optional_string(["model"]))
    use finishes <- decode.then(
      jsonx.list_or_empty(["choices"], {
        use index <- decode.then(jsonx.optional_int(["index"]))
        use finish <- decode.then(jsonx.optional_string(["finish_reason"]))
        decode.success(#(option.unwrap(index, 0), finish))
      }),
    )
    use prompt <- decode.then(jsonx.optional_int(["usage", "prompt_tokens"]))
    use completion <- decode.then(
      jsonx.optional_int(["usage", "completion_tokens"]),
    )
    decode.success(OpenAiChunk(
      id: chunk_id,
      model: model,
      finishes: finishes,
      prompt_tokens: prompt,
      completion_tokens: completion,
      has_usage: prompt != None || completion != None,
    ))
  }
  case json.parse(data, decoder) {
    Ok(chunk) -> Ok(chunk)
    Error(_) -> Error(Nil)
  }
}

fn distinct(values: List(Option(String))) -> List(String) {
  option.values(values) |> list.filter(fn(v) { v != "" }) |> list.unique
}

fn non_decreasing(values: List(Int)) -> Bool {
  list.window_by_2(values) |> list.all(fn(pair) { pair.1 >= pair.0 })
}

/// Check an OpenAI-style stream against rules 1 to 6.
pub fn analyse_openai(parsed: Parsed) -> Analysis {
  let events = sse.events(parsed)
  let payloads = list.map(events, fn(event) { event.data })
  let done_count = list.count(payloads, fn(data) { data == "[DONE]" })
  let after_done =
    list.drop_while(payloads, fn(data) { data != "[DONE]" }) |> list.drop(1)
  let chunks =
    list.filter(payloads, fn(data) { data != "[DONE]" })
    |> list.map(openai_chunk)
  let good = list.filter_map(chunks, fn(chunk) { chunk })
  let bad_json = list.length(chunks) - list.length(good)
  let ids = distinct(list.map(good, fn(chunk) { chunk.id }))
  let models = distinct(list.map(good, fn(chunk) { chunk.model }))
  let finishes =
    list.flat_map(good, fn(chunk) { chunk.finishes })
    |> list.fold(dict.new(), fn(tally, pair) {
      let #(index, finish) = pair
      let add = case finish {
        Some(_) -> 1
        None -> 0
      }
      dict.upsert(tally, index, fn(existing) {
        option.unwrap(existing, 0) + add
      })
    })
  let wrong_finish =
    dict.to_list(finishes) |> list.filter(fn(pair) { pair.1 != 1 })
  let usage = list.filter(good, fn(chunk) { chunk.has_usage })
  let usage_ok =
    non_decreasing(option.values(list.map(usage, fn(c) { c.prompt_tokens })))
    && non_decreasing(
      option.values(list.map(usage, fn(c) { c.completion_tokens })),
    )
  let violations =
    list.flatten([
      rule(
        bad_json > 0,
        "Rule 1: "
          <> int.to_string(bad_json)
          <> " data payload(s) are not valid JSON.",
      ),
      rule(done_count == 0, "Rule 2: the stream has no [DONE] terminator."),
      rule(
        done_count > 1,
        "Rule 2: the stream has more than one [DONE] terminator.",
      ),
      rule(after_done != [], "Rule 2: data follows the [DONE] terminator."),
      rule(
        list.length(ids) > 1,
        "Rule 3: chunks carry "
          <> int.to_string(list.length(ids))
          <> " different ids.",
      ),
      rule(
        list.length(models) > 1,
        "Rule 4: chunks carry different model names: "
          <> string.join(models, ", ")
          <> ".",
      ),
      rule(
        dict.size(finishes) == 0 && good != [],
        "Rule 5: no chunk carries a choice.",
      ),
      rule(
        wrong_finish != [],
        "Rule 5: a choice has no finish_reason, or more than one.",
      ),
      rule(
        !usage_ok,
        "Rule 6: reported token counts decrease during the stream.",
      ),
    ])
  Analysis(
    violations,
    list.length(events),
    list.first(models) |> option.from_result,
  )
}

fn rule(broken: Bool, text: String) -> List(String) {
  case broken {
    True -> [text]
    False -> []
  }
}

type AnthropicEvent {
  AnthropicEvent(
    kind: String,
    model: Option(String),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    delta_type: Option(String),
    signature: Option(String),
  )
}

fn anthropic_event(name: String, data: String) -> AnthropicEvent {
  let decoder = {
    use kind <- decode.then(jsonx.optional_string(["type"]))
    use model <- decode.then(jsonx.optional_string(["message", "model"]))
    use input_a <- decode.then(
      jsonx.optional_int(["message", "usage", "input_tokens"]),
    )
    use input_b <- decode.then(jsonx.optional_int(["usage", "input_tokens"]))
    use output_a <- decode.then(
      jsonx.optional_int(["message", "usage", "output_tokens"]),
    )
    use output_b <- decode.then(jsonx.optional_int(["usage", "output_tokens"]))
    use delta_type <- decode.then(jsonx.optional_string(["delta", "type"]))
    use signature <- decode.then(jsonx.optional_string(["delta", "signature"]))
    decode.success(AnthropicEvent(
      kind: option.unwrap(kind, name),
      model: model,
      input_tokens: option.or(input_a, input_b),
      output_tokens: option.or(output_a, output_b),
      delta_type: delta_type,
      signature: signature,
    ))
  }
  case json.parse(data, decoder) {
    Ok(event) ->
      case name {
        "" -> event
        _ -> AnthropicEvent(..event, kind: name)
      }
    Error(_) -> AnthropicEvent(name, None, None, None, None, None)
  }
}

/// Check an Anthropic-style stream against rules 1 to 5.
pub fn analyse_anthropic(parsed: Parsed) -> Analysis {
  let events =
    sse.events(parsed)
    |> list.map(fn(event) { anthropic_event(event.name, event.data) })
  let kinds = list.map(events, fn(event) { event.kind })
  let unknown =
    list.filter(kinds, fn(kind) { !list.contains(anthropic_events, kind) })
    |> list.unique
  let inputs =
    option.values(list.map(events, fn(e) { e.input_tokens })) |> list.unique
  let outputs = option.values(list.map(events, fn(e) { e.output_tokens }))
  let stops = list.count(kinds, fn(kind) { kind == "message_stop" })
  let before_stop = list.take_while(kinds, fn(kind) { kind != "message_stop" })
  let after_stop =
    list.drop_while(kinds, fn(kind) { kind != "message_stop" })
    |> list.drop(1)
    |> list.filter(fn(kind) { kind != "ping" })
  let empty_signature =
    list.any(events, fn(event) {
      event.delta_type == Some("signature_delta")
      && option.unwrap(event.signature, "") == ""
    })
  let violations =
    list.flatten([
      rule(
        unknown != [],
        "Rule 1: unknown event type(s): " <> string.join(unknown, ", ") <> ".",
      ),
      rule(
        list.length(inputs) > 1,
        "Rule 2: input_tokens changes during the stream.",
      ),
      rule(
        !non_decreasing(outputs),
        "Rule 3: output_tokens decreases during the stream.",
      ),
      rule(stops == 0, "Rule 4: the stream has no message_stop."),
      rule(stops > 1, "Rule 4: the stream has more than one message_stop."),
      rule(
        stops >= 1 && !list.contains(before_stop, "message_start"),
        "Rule 4: message_stop is not preceded by message_start.",
      ),
      rule(
        after_stop != [],
        "Rule 4: events other than ping follow message_stop.",
      ),
      rule(
        empty_signature,
        "Rule 5: a signature_delta carries an empty signature.",
      ),
    ])
  Analysis(
    violations,
    list.length(events),
    list.find_map(events, fn(event) { option.to_result(event.model, Nil) })
      |> option.from_result,
  )
}

pub fn run(ctx: Ctx) -> StepResult {
  let params =
    api.simple(ctx.target.model, probe_prompt, 64)
    |> api.with_temperature(0.0)
    |> api.streaming
  let request = chat.build(ctx.target, params, thresholds.request_timeout_ms)
  let outcome = ctx.send(ctx, ctx.target, id, "stream", request)
  build(ctx.target.format, ctx.target.model, outcome)
}

pub fn build(
  format: api.ApiFormat,
  requested_model: String,
  outcome: Result(http.Response, http.TransportError),
) -> StepResult {
  case outcome {
    Error(error) ->
      step.inconclusive(
        id,
        "stream_failed",
        "The streaming request failed: " <> http.describe_error(error) <> ".",
      )
    Ok(response) ->
      case http.is_success(response) {
        False ->
          step.inconclusive(
            id,
            "stream_refused",
            "The streaming request was answered with HTTP "
              <> int.to_string(response.status)
              <> ".",
          )
        True -> {
          let parsed = sse.parse_chunks(response.chunks)
          let analysis = case format {
            OpenAi -> analyse_openai(parsed)
            Anthropic -> analyse_anthropic(parsed)
          }
          let comments =
            list.count(parsed.items, fn(item) {
              case item {
                CommentItem(..) -> True
                EventItem(_) -> False
              }
            })
          judged(format, requested_model, analysis, comments, parsed.incomplete)
        }
      }
  }
}

fn judged(
  format: api.ApiFormat,
  requested_model: String,
  analysis: Analysis,
  comments: Int,
  incomplete: Bool,
) -> StepResult {
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("format", json.string(api.format_to_string(format)))
    |> step.with_data("events", json.int(analysis.events))
    |> step.with_data(
      "violations",
      json.array(analysis.violations, json.string),
    )
    |> step.with_data(
      "stream_model",
      json.nullable(analysis.model, json.string),
    )
    |> step.with_details(
      list.flatten([
        [
          Table(["Measure", "Value"], [
            ["Rule set", api.format_to_string(format)],
            ["Events", int.to_string(analysis.events)],
            ["Comment lines", int.to_string(comments)],
            ["Model named in stream", option.unwrap(analysis.model, "-")],
          ]),
        ],
        case analysis.violations {
          [] -> []
          violations -> [Bullets(violations)]
        },
      ]),
    )
    |> model_note(requested_model, analysis.model)
  }
  let violations = case incomplete {
    True ->
      list.append(analysis.violations, [
        "The stream ended in the middle of an event.",
      ])
    False -> analysis.violations
  }
  case analysis.events, violations {
    0, _ ->
      step.inconclusive(
        id,
        "no_events",
        "The response contained no server-sent events.",
      )
      |> decorate
    _, [] ->
      step.ran(
        id,
        Clean,
        "The event stream satisfies every rule of its format.",
      )
      |> decorate
    _, [first, ..] ->
      step.ran(
        id,
        Anomaly,
        "The event stream breaks "
          <> int.to_string(list.length(violations))
          <> " rule(s). First: "
          <> first,
      )
      |> decorate
  }
}

fn model_note(
  result: StepResult,
  requested: String,
  streamed: Option(String),
) -> StepResult {
  case streamed {
    Some(name) if name != requested ->
      step.with_finding(
        result,
        step.Note,
        "The stream names the model \""
          <> name
          <> "\" while \""
          <> requested
          <> "\" was requested. Gateways often return canonical names; this is recorded, not judged.",
      )
    _ -> result
  }
}
