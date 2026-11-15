import gleam/option.{None}
import receipt/api/chat.{Malformed, Status, Transport}
import receipt/api/types.{Anthropic, OpenAi}
import receipt/endpoint.{Endpoint}
import receipt/http/types as http
import receipt/secret

fn endpoint(format: types.ApiFormat) {
  Endpoint(
    "target",
    "https://relay.example",
    "m",
    secret.from_string("k"),
    format,
  )
}

fn response(status: Int, body: String) {
  Ok(http.Response(
    status: status,
    headers: [],
    body: <<body:utf8>>,
    chunks: [],
    timing: http.Timing(None, None, None),
  ))
}

pub fn build_follows_the_endpoint_format_test() {
  let params = types.simple("m", "hi", 5)
  assert chat.build(endpoint(OpenAi), params, 100).url
    == "https://relay.example/v1/chat/completions"
  assert chat.build(endpoint(Anthropic), params, 100).url
    == "https://relay.example/v1/messages"
}

pub fn success_is_parsed_in_the_endpoint_format_test() {
  let assert Ok(openai) =
    chat.interpret(
      endpoint(OpenAi),
      response(200, "{\"choices\":[{\"message\":{\"content\":\"a\"}}]}"),
    )
  assert openai.text == "a"
  let assert Ok(anthropic) =
    chat.interpret(
      endpoint(Anthropic),
      response(200, "{\"content\":[{\"type\":\"text\",\"text\":\"b\"}]}"),
    )
  assert anthropic.text == "b"
}

pub fn transport_error_is_passed_through_test() {
  assert chat.interpret(endpoint(OpenAi), Error(http.Timeout))
    == Error(Transport(http.Timeout))
}

pub fn error_status_carries_message_and_body_test() {
  let body = "{\"error\":{\"message\":\"model not found\"}}"
  assert chat.interpret(endpoint(OpenAi), response(404, body))
    == Error(Status(404, "model not found", body))
}

pub fn success_status_with_wrong_shape_is_malformed_test() {
  assert chat.interpret(endpoint(OpenAi), response(200, "{\"ok\":true}"))
    == Error(Malformed("{\"ok\":true}"))
}

pub fn rate_limit_is_only_status_429_test() {
  assert chat.is_rate_limited(Status(429, "slow down", ""))
  assert !chat.is_rate_limited(Status(503, "busy", ""))
  assert !chat.is_rate_limited(Transport(http.Timeout))
}

pub fn size_limit_detection_test() {
  assert chat.is_size_limit(Status(413, "", ""))
  assert chat.is_size_limit(Status(
    400,
    "This model's maximum context length is 8192 tokens",
    "",
  ))
  assert chat.is_size_limit(Status(
    429,
    "Request too large for model: tokens per minute (TPM) limit 6000",
    "",
  ))
  assert !chat.is_size_limit(Status(400, "invalid api key", ""))
  assert !chat.is_size_limit(Status(500, "context length", ""))
  assert !chat.is_size_limit(Malformed("x"))
}

pub fn describe_is_bounded_and_one_line_test() {
  assert chat.describe(Status(404, "model not found", ""))
    == "HTTP 404: model not found"
  assert chat.describe(Transport(http.Timeout)) == "timeout"
}
