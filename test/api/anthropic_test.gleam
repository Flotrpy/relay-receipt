import gleam/json
import gleam/option.{None, Some}
import gleam/string
import receipt/api/anthropic
import receipt/api/types.{Tool, ToolCall, Usage}
import receipt/http/types as http
import receipt/secret

fn body_of(params: types.ChatParams) -> String {
  json.to_string(anthropic.request_body(params))
}

pub fn minimal_body_test() {
  assert body_of(types.simple("claude-x", "Say hi", 10))
    == "{\"model\":\"claude-x\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}]}"
}

pub fn system_prompt_is_a_top_level_field_test() {
  let body = body_of(types.simple("m", "hi", 5) |> types.with_system("rules"))
  assert string.contains(body, "\"system\":\"rules\"")
  assert !string.contains(body, "\"role\":\"system\"")
}

pub fn tools_use_input_schema_test() {
  let tool =
    Tool("run", "Run it", json.object([#("type", json.string("object"))]))
  let body = body_of(types.simple("m", "hi", 5) |> types.with_tools([tool]))
  assert string.contains(
    body,
    "\"tools\":[{\"name\":\"run\",\"description\":\"Run it\",\"input_schema\":{\"type\":\"object\"}}]",
  )
}

pub fn stream_flag_test() {
  assert string.contains(
    body_of(types.simple("m", "hi", 5) |> types.streaming),
    "\"stream\":true",
  )
  assert !string.contains(body_of(types.simple("m", "hi", 5)), "stream")
}

pub fn build_sets_url_and_auth_headers_test() {
  let request =
    anthropic.build(
      "https://relay.example",
      secret.from_string("sk-ant-test"),
      types.simple("m", "hi", 5),
      1000,
    )
  assert request.url == "https://relay.example/v1/messages"
  assert http.header(request.headers, "x-api-key") == Ok("sk-ant-test")
  assert http.header(request.headers, "authorization")
    == Ok("Bearer sk-ant-test")
  assert http.header(request.headers, "anthropic-version") == Ok("2023-06-01")
}

pub fn parse_text_response_test() {
  let body =
    "{\"id\":\"msg_01abc\",\"type\":\"message\",\"model\":\"claude-x\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"},{\"type\":\"text\",\"text\":\" there\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":9,\"output_tokens\":4,\"cache_read_input_tokens\":0}}"
  let assert Ok(completion) = anthropic.parse_completion(body)
  assert completion.id == "msg_01abc"
  assert completion.text == "Hello there"
  assert completion.finish_reason == Some("end_turn")
  assert completion.usage == Usage(Some(9), Some(4), Some(0), None)
}

pub fn parse_tool_use_serialises_input_test() {
  let body =
    "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"run_shell\",\"input\":{\"command\":\"npm install lodash@4.17.21\"}}],\"stop_reason\":\"tool_use\"}"
  let assert Ok(completion) = anthropic.parse_completion(body)
  assert completion.text == ""
  assert completion.reasoning == "hmm"
  assert completion.tool_calls
    == [ToolCall("run_shell", "{\"command\":\"npm install lodash@4.17.21\"}")]
}

pub fn unknown_blocks_are_ignored_test() {
  let body =
    "{\"content\":[{\"type\":\"server_tool_use\"},{\"type\":\"text\",\"text\":\"ok\"}]}"
  let assert Ok(completion) = anthropic.parse_completion(body)
  assert completion.text == "ok"
  assert completion.usage == Usage(None, None, None, None)
}

pub fn body_without_content_is_an_error_test() {
  assert anthropic.parse_completion("{\"type\":\"error\",\"error\":{}}")
    == Error(Nil)
  assert anthropic.parse_completion("not json") == Error(Nil)
}
