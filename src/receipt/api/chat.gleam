//// One front for both API formats: build a chat request for an endpoint
//// and interpret whatever came back.

import gleam/option.{None}
import gleam/string
import receipt/api/anthropic
import receipt/api/openai
import receipt/api/types.{
  type ChatParams, type Completion, Anthropic, Completion, OpenAi,
}
import receipt/endpoint.{type Endpoint}
import receipt/http/types as http

/// Why a chat request did not produce a completion.
pub type ChatError {
  /// No HTTP response was received.
  Transport(error: http.TransportError)
  /// The endpoint answered with a non-2xx status.
  Status(status: Int, message: String, body: String)
  /// The endpoint answered 2xx with a body that is not a completion.
  Malformed(body: String)
}

/// Build the chat request for an endpoint in its API format.
pub fn build(
  endpoint: Endpoint,
  params: ChatParams,
  timeout_ms: Int,
) -> http.Request {
  case endpoint.format {
    OpenAi -> openai.build(endpoint.base_url, endpoint.key, params, timeout_ms)
    Anthropic ->
      anthropic.build(endpoint.base_url, endpoint.key, params, timeout_ms)
  }
}

/// Authentication headers for an endpoint, for requests that are not chats.
pub fn auth_headers(endpoint: Endpoint) -> List(#(String, String)) {
  case endpoint.format {
    OpenAi -> openai.auth_headers(endpoint.key)
    Anthropic -> anthropic.auth_headers(endpoint.key)
  }
}

/// Turn a transport result into a completion or a classified error.
pub fn interpret(
  endpoint: Endpoint,
  result: Result(http.Response, http.TransportError),
) -> Result(Completion, ChatError) {
  case result {
    Error(error) -> Error(Transport(error))
    Ok(response) -> {
      let body = http.body_text(response)
      case http.is_success(response) {
        False ->
          Error(Status(response.status, openai.error_message(body), body))
        True -> {
          let parsed = case endpoint.format {
            OpenAi -> openai.parse_completion(body)
            Anthropic -> anthropic.parse_completion(body)
          }
          case parsed {
            Ok(completion) -> Ok(completion)
            Error(Nil) -> Error(Malformed(body))
          }
        }
      }
    }
  }
}

/// Whether the error is the endpoint saying "slow down".
pub fn is_rate_limited(error: ChatError) -> Bool {
  case error {
    Status(429, _, _) -> True
    _ -> False
  }
}

/// Whether the error says the request was too large for the model or the
/// account, as opposed to a failure of the relay.
pub fn is_size_limit(error: ChatError) -> Bool {
  case error {
    Status(413, _, _) -> True
    Status(status, message, _) if status >= 400 && status < 500 -> {
      let text = string.lowercase(message)
      string.contains(text, "context length")
      || string.contains(text, "context window")
      || string.contains(text, "maximum context")
      || string.contains(text, "too large")
      || string.contains(text, "too long")
      || string.contains(text, "reduce the length")
      || string.contains(text, "tokens per minute")
    }
    _ -> False
  }
}

/// A one-line description for reports.
pub fn describe(error: ChatError) -> String {
  case error {
    Transport(error) -> http.describe_error(error)
    Status(status, message, _) ->
      "HTTP " <> string.inspect(status) <> ": " <> string.slice(message, 0, 200)
    Malformed(body) ->
      "unrecognised response body: " <> string.slice(body, 0, 120)
  }
}

/// An empty completion, for tests and as a neutral starting value.
pub fn empty_completion() -> Completion {
  Completion(
    id: "",
    model: "",
    text: "",
    reasoning: "",
    tool_calls: [],
    finish_reason: None,
    usage: types.no_usage,
  )
}
