//// Step 2: Connectivity.
////
//// Lists the models the endpoint advertises and checks which chat format
//// (OpenAI-compatible, Anthropic-compatible) answers a minimal request.
//// Later steps use the detected format. Descriptive: `informational` when
//// at least one format answers, `inconclusive` otherwise.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/chat.{type ChatError}
import receipt/api/openai
import receipt/api/types.{type ApiFormat, Anthropic, OpenAi} as api
import receipt/api/url
import receipt/ctx.{type Ctx}
import receipt/endpoint
import receipt/http/types as http
import receipt/report/block.{Table}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Informational}

const id = 2

/// The minimal prompt used to check that a format answers.
pub const probe_prompt = "Reply with the single word: ok"

/// Outcome of trying one format.
pub type Attempt {
  Attempt(format: ApiFormat, outcome: Result(Nil, ChatError))
}

pub fn run(ctx: Ctx) -> #(StepResult, Option(ApiFormat)) {
  let models = list_models(ctx)
  let attempts =
    [OpenAi, Anthropic]
    |> list.map(fn(format) {
      let target = endpoint.with_format(ctx.target, format)
      let outcome =
        ctx.chat(
          ctx,
          target,
          id,
          "chat/" <> api.format_to_string(format),
          api.simple(target.model, probe_prompt, 8),
        )
      Attempt(format, case outcome {
        Ok(_) -> Ok(Nil)
        Error(error) -> Error(error)
      })
    })
  build(ctx.target.model, models, attempts)
}

fn list_models(ctx: Ctx) -> Result(List(String), String) {
  let request =
    http.Request(
      http.Get,
      url.models(ctx.target.base_url),
      openai.auth_headers(ctx.target.key),
      "",
      thresholds.request_timeout_ms,
    )
  case ctx.send(ctx, ctx.target, id, "models", request) {
    Error(error) -> Error(http.describe_error(error))
    Ok(response) ->
      case http.is_success(response) {
        False -> Error("HTTP " <> int.to_string(response.status))
        True ->
          case openai.parse_models(http.body_text(response)) {
            Ok(ids) -> Ok(ids)
            Error(Nil) -> Error("unrecognised model list")
          }
      }
  }
}

/// The format later steps should use: OpenAI-compatible when both answer.
pub fn detect(attempts: List(Attempt)) -> Option(ApiFormat) {
  let works = fn(format: ApiFormat) {
    list.any(attempts, fn(attempt) {
      attempt.format == format && attempt.outcome == Ok(Nil)
    })
  }
  case works(OpenAi), works(Anthropic) {
    True, _ -> Some(OpenAi)
    False, True -> Some(Anthropic)
    False, False -> None
  }
}

/// Assemble the result. Separate from `run` so it can be tested directly.
pub fn build(
  model: String,
  models: Result(List(String), String),
  attempts: List(Attempt),
) -> #(StepResult, Option(ApiFormat)) {
  let detected = detect(attempts)
  let rows =
    list.map(attempts, fn(attempt) {
      [
        api.format_to_string(attempt.format),
        case attempt.outcome {
          Ok(Nil) -> "answers"
          Error(error) -> chat.describe(error)
        },
      ]
    })
  let model_note = case models {
    Ok(ids) ->
      case list.contains(ids, model) {
        True ->
          "The model list has "
          <> int.to_string(list.length(ids))
          <> " entries and includes the requested model."
        False ->
          "The model list has "
          <> int.to_string(list.length(ids))
          <> " entries and does not include the requested model name."
      }
    Error(reason) -> "The model list could not be read (" <> reason <> ")."
  }
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data(
      "api_format",
      json.nullable(option.map(detected, api.format_to_string), json.string),
    )
    |> step.with_data(
      "models",
      json.nullable(option.from_result(models), json.array(_, json.string)),
    )
    |> step.with_finding(step.Note, model_note)
    |> step.with_details([Table(["Format", "Minimal chat request"], rows)])
  }
  case detected {
    Some(format) -> #(
      step.ran(
        id,
        Informational,
        "The endpoint answers " <> describe(format) <> " chat requests.",
      )
        |> decorate,
      Some(format),
    )
    None -> #(
      step.inconclusive(
        id,
        "no_format",
        "No chat format answered: "
          <> string.join(
          list.map(rows, fn(row) { string.join(row, " -> ") }),
          "; ",
        ),
      )
        |> decorate,
      None,
    )
  }
}

fn describe(format: ApiFormat) -> String {
  case format {
    OpenAi -> "OpenAI-compatible"
    Anthropic -> "Anthropic-compatible"
  }
}
