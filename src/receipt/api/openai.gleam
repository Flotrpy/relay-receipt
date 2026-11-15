//// OpenAI-compatible chat completions: request building and response
//// parsing.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import receipt/api/types.{
  type ChatParams, type Completion, type ToolCall, type Usage, Completion,
  OpenAi, ToolCall, Usage,
}
import receipt/api/url
import receipt/http/types as http
import receipt/jsonx
import receipt/secret.{type Secret}

/// The JSON body for a chat request.
pub fn request_body(params: ChatParams) -> Json {
  let system = case params.system {
    Some(text) -> [message_json("system", text)]
    None -> []
  }
  let messages =
    list.append(
      system,
      list.map(params.messages, fn(m) { message_json(m.role, m.content) }),
    )
  let base = [
    #("model", json.string(params.model)),
    #("messages", json.preprocessed_array(messages)),
    #("max_tokens", json.int(params.max_tokens)),
  ]
  let temperature = case params.temperature {
    Some(value) -> [#("temperature", json.float(value))]
    None -> []
  }
  let tools = case params.tools {
    [] -> []
    tools -> [
      #(
        "tools",
        json.array(tools, fn(tool) {
          json.object([
            #("type", json.string("function")),
            #(
              "function",
              json.object([
                #("name", json.string(tool.name)),
                #("description", json.string(tool.description)),
                #("parameters", tool.parameters),
              ]),
            ),
          ])
        }),
      ),
    ]
  }
  let stream = case params.stream {
    True -> [
      #("stream", json.bool(True)),
      #("stream_options", json.object([#("include_usage", json.bool(True))])),
    ]
    False -> []
  }
  json.object(list.flatten([base, temperature, tools, stream]))
}

fn message_json(role: String, content: String) -> Json {
  json.object([#("role", json.string(role)), #("content", json.string(content))])
}

/// Authentication headers for an OpenAI-compatible endpoint.
pub fn auth_headers(key: Secret) -> List(#(String, String)) {
  [#("authorization", "Bearer " <> secret.expose(key))]
}

/// A complete chat request.
pub fn build(
  base_url: String,
  key: Secret,
  params: ChatParams,
  timeout_ms: Int,
) -> http.Request {
  http.Request(
    method: http.Post,
    url: url.chat(base_url, OpenAi),
    headers: [#("content-type", "application/json"), ..auth_headers(key)],
    body: json.to_string(request_body(params)),
    timeout_ms: timeout_ms,
  )
}

/// Parse a non-streaming chat completion body.
pub fn parse_completion(body: String) -> Result(Completion, Nil) {
  case json.parse(body, completion_decoder()) {
    Ok(Some(completion)) -> Ok(completion)
    _ -> Error(Nil)
  }
}

fn completion_decoder() -> Decoder(Option(Completion)) {
  use id <- decode.then(jsonx.string_or(["id"], ""))
  use model <- decode.then(jsonx.string_or(["model"], ""))
  use choices <- decode.then(jsonx.optional_at(
    ["choices"],
    decode.list(choice_decoder()),
  ))
  use usage <- decode.then(usage_decoder())
  case choices {
    Some([choice, ..]) ->
      decode.success(
        Some(Completion(
          id: id,
          model: model,
          text: choice.text,
          reasoning: choice.reasoning,
          tool_calls: choice.tool_calls,
          finish_reason: choice.finish_reason,
          usage: usage,
        )),
      )
    _ -> decode.success(None)
  }
}

type Choice {
  Choice(
    text: String,
    reasoning: String,
    tool_calls: List(ToolCall),
    finish_reason: Option(String),
  )
}

fn choice_decoder() -> Decoder(Choice) {
  use text <- decode.then(jsonx.string_or(["message", "content"], ""))
  use reasoning <- decode.then(jsonx.optional_string(["message", "reasoning"]))
  use reasoning_content <- decode.then(
    jsonx.optional_string(["message", "reasoning_content"]),
  )
  use tool_calls <- decode.then(jsonx.list_or_empty(
    ["message", "tool_calls"],
    tool_call_decoder(),
  ))
  use finish_reason <- decode.then(jsonx.optional_string(["finish_reason"]))
  decode.success(Choice(
    text: text,
    reasoning: option.or(reasoning, reasoning_content) |> option.unwrap(""),
    tool_calls: tool_calls,
    finish_reason: finish_reason,
  ))
}

fn tool_call_decoder() -> Decoder(ToolCall) {
  use name <- decode.then(jsonx.string_or(["function", "name"], ""))
  use arguments <- decode.then(jsonx.string_or(["function", "arguments"], ""))
  decode.success(ToolCall(name: name, arguments: arguments))
}

/// Decode the `usage` object of a response or stream chunk.
pub fn usage_decoder() -> Decoder(Usage) {
  use prompt <- decode.then(jsonx.optional_int(["usage", "prompt_tokens"]))
  use completion <- decode.then(
    jsonx.optional_int(["usage", "completion_tokens"]),
  )
  use cached <- decode.then(
    jsonx.optional_int(["usage", "prompt_tokens_details", "cached_tokens"]),
  )
  use reasoning <- decode.then(
    jsonx.optional_int([
      "usage", "completion_tokens_details", "reasoning_tokens",
    ]),
  )
  decode.success(Usage(prompt, completion, cached, reasoning))
}

/// The human-readable message of an error body, or the body itself when it
/// has no recognised shape.
pub fn error_message(body: String) -> String {
  let decoder =
    decode.one_of(decode.at(["error", "message"], decode.string), [
      decode.at(["error"], decode.string),
      decode.at(["message"], decode.string),
      decode.at(["detail"], decode.string),
    ])
  case json.parse(body, decoder) {
    Ok(message) -> message
    Error(_) -> body
  }
}

/// The ids in a model-list response.
pub fn parse_models(body: String) -> Result(List(String), Nil) {
  let decoder = decode.at(["data"], decode.list(jsonx.string_or(["id"], "")))
  case json.parse(body, decoder) {
    Ok(ids) -> Ok(list.filter(ids, fn(id) { id != "" }))
    Error(_) -> Error(Nil)
  }
}
