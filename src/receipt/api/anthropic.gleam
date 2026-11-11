//// Anthropic-compatible messages: request building and response parsing.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/types.{
  type ChatParams, type Completion, type ToolCall, Anthropic, Completion,
  ToolCall, Usage,
}
import receipt/api/url
import receipt/http/types as http
import receipt/jsonx
import receipt/secret.{type Secret}

/// The API version header value Receipt sends.
pub const api_version = "2023-06-01"

/// The JSON body for a messages request.
pub fn request_body(params: ChatParams) -> Json {
  let base = [
    #("model", json.string(params.model)),
    #("max_tokens", json.int(params.max_tokens)),
    #(
      "messages",
      json.array(params.messages, fn(m) {
        json.object([
          #("role", json.string(m.role)),
          #("content", json.string(m.content)),
        ])
      }),
    ),
  ]
  let system = case params.system {
    Some(text) -> [#("system", json.string(text))]
    None -> []
  }
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
            #("name", json.string(tool.name)),
            #("description", json.string(tool.description)),
            #("input_schema", tool.parameters),
          ])
        }),
      ),
    ]
  }
  let stream = case params.stream {
    True -> [#("stream", json.bool(True))]
    False -> []
  }
  json.object(list.flatten([base, system, temperature, tools, stream]))
}

/// Authentication headers. Both the native `x-api-key` header and a bearer
/// token are sent, because Anthropic-compatible relays accept either.
pub fn auth_headers(key: Secret) -> List(#(String, String)) {
  [
    #("x-api-key", secret.expose(key)),
    #("authorization", "Bearer " <> secret.expose(key)),
    #("anthropic-version", api_version),
  ]
}

/// A complete messages request.
pub fn build(
  base_url: String,
  key: Secret,
  params: ChatParams,
  timeout_ms: Int,
) -> http.Request {
  http.Request(
    method: http.Post,
    url: url.chat(base_url, Anthropic),
    headers: [#("content-type", "application/json"), ..auth_headers(key)],
    body: json.to_string(request_body(params)),
    timeout_ms: timeout_ms,
  )
}

type Block {
  TextBlock(text: String)
  ThinkingBlock(text: String)
  ToolUseBlock(call: ToolCall)
  UnknownBlock
}

/// Parse a non-streaming messages response body.
pub fn parse_completion(body: String) -> Result(Completion, Nil) {
  case json.parse(body, completion_decoder()) {
    Ok(Some(completion)) -> Ok(completion)
    _ -> Error(Nil)
  }
}

fn completion_decoder() -> Decoder(Option(Completion)) {
  use id <- decode.then(jsonx.string_or(["id"], ""))
  use model <- decode.then(jsonx.string_or(["model"], ""))
  use blocks <- decode.then(jsonx.optional_at(
    ["content"],
    decode.list(block_decoder()),
  ))
  use stop_reason <- decode.then(jsonx.optional_string(["stop_reason"]))
  use usage <- decode.then(usage_decoder(["usage"]))
  case blocks {
    None -> decode.success(None)
    Some(blocks) ->
      decode.success(
        Some(Completion(
          id: id,
          model: model,
          text: collect(blocks, fn(block) {
            case block {
              TextBlock(text) -> Ok(text)
              _ -> Error(Nil)
            }
          }),
          reasoning: collect(blocks, fn(block) {
            case block {
              ThinkingBlock(text) -> Ok(text)
              _ -> Error(Nil)
            }
          }),
          tool_calls: list.filter_map(blocks, fn(block) {
            case block {
              ToolUseBlock(call) -> Ok(call)
              _ -> Error(Nil)
            }
          }),
          finish_reason: stop_reason,
          usage: usage,
        )),
      )
  }
}

fn collect(
  blocks: List(Block),
  pick: fn(Block) -> Result(String, Nil),
) -> String {
  list.filter_map(blocks, pick) |> string.concat
}

fn block_decoder() -> Decoder(Block) {
  use kind <- decode.then(jsonx.string_or(["type"], ""))
  case kind {
    "text" -> jsonx.string_or(["text"], "") |> decode.map(TextBlock)
    "thinking" -> jsonx.string_or(["thinking"], "") |> decode.map(ThinkingBlock)
    "tool_use" -> {
      use name <- decode.then(jsonx.string_or(["name"], ""))
      use input <- decode.then(jsonx.raw_at(["input"]))
      decode.success(
        ToolUseBlock(ToolCall(name: name, arguments: option.unwrap(input, ""))),
      )
    }
    _ -> decode.success(UnknownBlock)
  }
}

/// Decode a usage object found at `path`.
pub fn usage_decoder(path: List(String)) -> Decoder(types.Usage) {
  use prompt <- decode.then(
    jsonx.optional_int(list.append(path, ["input_tokens"])),
  )
  use completion <- decode.then(
    jsonx.optional_int(list.append(path, ["output_tokens"])),
  )
  use cached <- decode.then(
    jsonx.optional_int(list.append(path, ["cache_read_input_tokens"])),
  )
  decode.success(Usage(prompt, completion, cached, None))
}
