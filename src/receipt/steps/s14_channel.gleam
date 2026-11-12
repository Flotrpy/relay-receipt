//// Step 14: Upstream channel classifier.
////
//// One authenticated response is examined for markers that identify the
//// serving channel: id prefixes and headers that a provider or cloud adds
//// and a relay often forwards unchanged. Tier 1 markers decide alone;
//// tier 2 markers add weights per channel; tier 3 is a fallback
//// inference. Descriptive only: any channel is a legitimate way to serve
//// a model, and a relay can rewrite every marker.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import receipt/api/chat
import receipt/api/types as api
import receipt/ctx.{type Ctx}
import receipt/http/types as http
import receipt/jsonx
import receipt/report/block.{Table}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Informational}

const id = 14

pub type Signal {
  IdPrefix(prefix: String)
  HeaderPrefix(prefix: String)
  HeaderValuePrefix(name: String, prefix: String)
  Body(text: String)
}

/// Tier 1: one marker is decisive.
pub fn tier1() -> List(#(String, Signal)) {
  [
    #("openrouter", IdPrefix("gen-")),
    #("openrouter", HeaderValuePrefix("x-generation-id", "gen-")),
    #("cloudflare-ai-gateway", HeaderPrefix("cf-aig-")),
    #("groq", HeaderPrefix("x-groq-")),
    #("aws-bedrock", HeaderPrefix("x-amzn-bedrock-")),
    #("aws-bedrock", IdPrefix("msg_bdrk_")),
    #("google-vertex", IdPrefix("msg_vrtx_")),
  ]
}

/// Tier 2: weights accumulate per channel.
pub fn tier2() -> List(#(String, List(#(Signal, Float)))) {
  [
    #("aws-bedrock", [#(Body("bedrock-2023-05-31"), 0.9)]),
    #("google-vertex", [#(Body("vertex-2023-10-16"), 0.9)]),
    #("aws-api-gateway", [
      #(HeaderPrefix("x-amz-apigw-id"), 0.8),
      #(HeaderPrefix("apigw-requestid"), 0.8),
    ]),
    #("anthropic", [
      #(HeaderPrefix("anthropic-ratelimit-"), 0.95),
      #(HeaderPrefix("anthropic-organization-id"), 0.95),
      #(HeaderValuePrefix("request-id", "req_"), 0.6),
    ]),
    #("openai", [
      #(HeaderPrefix("openai-"), 0.9),
      #(HeaderValuePrefix("x-request-id", "req_"), 0.3),
      #(IdPrefix("chatcmpl-"), 0.2),
    ]),
    #("azure-openai", [
      #(HeaderPrefix("apim-request-id"), 0.8),
      #(HeaderPrefix("x-ms-region"), 0.7),
      #(HeaderPrefix("azureml-"), 0.6),
    ]),
    #("google-ai-studio", [
      #(HeaderValuePrefix("server", "scaffolding on httpserver2"), 0.6),
      #(HeaderPrefix("x-gemini-"), 0.6),
    ]),
  ]
}

pub type Evidence {
  Evidence(
    /// Lower-cased header names and values.
    headers: List(#(String, String)),
    message_id: String,
    /// The first part of the response body.
    body: String,
  )
}

fn fires(signal: Signal, evidence: Evidence) -> Bool {
  case signal {
    IdPrefix(prefix) -> string.starts_with(evidence.message_id, prefix)
    HeaderPrefix(prefix) ->
      list.any(evidence.headers, fn(pair) { string.starts_with(pair.0, prefix) })
    HeaderValuePrefix(name, prefix) ->
      list.any(evidence.headers, fn(pair) {
        pair.0 == name && string.starts_with(pair.1, prefix)
      })
    Body(text) -> string.contains(evidence.body, text)
  }
}

pub type Classification {
  Classification(channel: Option(String), confidence: Float, tier: Int)
}

/// Classify the serving channel from one response's evidence.
pub fn classify(evidence: Evidence) -> Classification {
  case list.find(tier1(), fn(rule) { fires(rule.1, evidence) }) {
    Ok(#(channel, _)) -> Classification(Some(channel), 1.0, 1)
    Error(Nil) -> {
      let scored =
        list.map(tier2(), fn(channel) {
          let score =
            list.fold(channel.1, 0.0, fn(total, weighted) {
              case fires(weighted.0, evidence) {
                True -> total +. weighted.1
                False -> total
              }
            })
          #(channel.0, float.min(1.0, score))
        })
      // The first channel wins ties, so list order is the priority.
      let best =
        list.fold(scored, #("", 0.0), fn(best, candidate) {
          case candidate.1 >. best.1 {
            True -> candidate
            False -> best
          }
        })
      case best.1 >=. thresholds.channel_min_confidence {
        True -> Classification(Some(best.0), float.to_precision(best.1, 2), 2)
        False -> tier3(evidence, best.1)
      }
    }
  }
}

/// A native Anthropic message id with no other marker suggests a
/// pass-through in front of Anthropic's own API.
fn tier3(evidence: Evidence, best_score: Float) -> Classification {
  let assert Ok(native) = regexp.from_string("^msg_01[A-Za-z0-9]{20,}$")
  case regexp.check(native, evidence.message_id) {
    True -> Classification(Some("anthropic-passthrough"), 0.5, 3)
    False -> Classification(None, float.to_precision(best_score, 2), 0)
  }
}

pub fn evidence_from(response: http.Response) -> Evidence {
  let body = string.slice(http.body_text(response), 0, 8192)
  let message_id =
    json.parse(body, jsonx.string_or(["id"], ""))
    |> option.from_result
    |> option.unwrap("")
  Evidence(
    headers: list.map(response.headers, fn(pair) {
      #(string.lowercase(pair.0), string.lowercase(pair.1))
    }),
    message_id: message_id,
    body: body,
  )
}

pub fn run(ctx: Ctx) -> StepResult {
  let params = api.simple(ctx.target.model, "Reply with the single word: ok", 8)
  let request = chat.build(ctx.target, params, thresholds.request_timeout_ms)
  case ctx.send(ctx, ctx.target, id, "channel", request) {
    Ok(response) ->
      case http.is_success(response) {
        True -> build(evidence_from(response))
        False ->
          step.inconclusive(
            id,
            "no_authenticated_response",
            "The request was answered with HTTP "
              <> int.to_string(response.status)
              <> ", so there was no successful response to examine.",
          )
      }
    Error(error) ->
      step.inconclusive(
        id,
        "no_authenticated_response",
        "The request failed: " <> http.describe_error(error) <> ".",
      )
  }
}

pub fn build(evidence: Evidence) -> StepResult {
  let classification = classify(evidence)
  let id_shape = case evidence.message_id {
    "" -> "none"
    message_id -> string.slice(message_id, 0, 12) <> "..."
  }
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data(
      "channel",
      json.nullable(classification.channel, json.string),
    )
    |> step.with_data("confidence", json.float(classification.confidence))
    |> step.with_data("tier", json.int(classification.tier))
    |> step.with_details([
      Table(["Measure", "Value"], [
        ["Channel", option.unwrap(classification.channel, "not recognised")],
        ["Confidence", float.to_string(classification.confidence)],
        ["Decided by tier", int.to_string(classification.tier)],
        ["Response id starts", id_shape],
      ]),
    ])
    |> step.with_finding(
      step.Limit,
      "Channel markers are forwarded or rewritten at the relay's discretion. Their presence describes this response; their absence shows nothing.",
    )
  }
  case classification.channel {
    Some(channel) ->
      step.ran(
        id,
        Informational,
        "The response carries markers of the "
          <> channel
          <> " channel (confidence "
          <> float.to_string(classification.confidence)
          <> ").",
      )
      |> decorate
    None ->
      step.ran(
        id,
        Informational,
        "No serving-channel markers were recognised in the response.",
      )
      |> decorate
  }
}
