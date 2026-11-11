import gleam/json
import gleam/option.{None, Some}
import gleam/string
import receipt/api/openai
import receipt/api/types.{Message, Tool, ToolCall, Usage}
import receipt/http/types as http
import receipt/secret

fn body_of(params: types.ChatParams) -> String {
  json.to_string(openai.request_body(params))
}

pub fn minimal_body_test() {
  assert body_of(types.simple("m-1", "Say hi", 10))
    == "{\"model\":\"m-1\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"max_tokens\":10}"
}

pub fn system_prompt_comes_first_test() {
  let body = body_of(types.simple("m", "hi", 5) |> types.with_system("rules"))
  assert string.contains(
    body,
    "\"messages\":[{\"role\":\"system\",\"content\":\"rules\"},{\"role\":\"user\"",
  )
}

pub fn temperature_is_only_sent_when_set_test() {
  assert !string.contains(body_of(types.simple("m", "hi", 5)), "temperature")
  assert string.contains(
    body_of(types.simple("m", "hi", 5) |> types.with_temperature(0.0)),
    "\"temperature\":0.0",
  )
}

pub fn tools_use_function_wrapper_test() {
  let tool =
    Tool("run", "Run it", json.object([#("type", json.string("object"))]))
  let body = body_of(types.simple("m", "hi", 5) |> types.with_tools([tool]))
  assert string.contains(
    body,
    "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"run\",\"description\":\"Run it\",\"parameters\":{\"type\":\"object\"}}}]",
  )
}

pub fn streaming_requests_usage_test() {
  let body = body_of(types.simple("m", "hi", 5) |> types.streaming)
  assert string.contains(body, "\"stream\":true")
  assert string.contains(body, "\"stream_options\":{\"include_usage\":true}")
}

pub fn build_sets_url_and_bearer_header_test() {
  let request =
    openai.build(
      "https://relay.example",
      secret.from_string("sk-test-key"),
      types.simple("m", "hi", 5),
      1000,
    )
  assert request.method == http.Post
  assert request.url == "https://relay.example/v1/chat/completions"
  assert http.header(request.headers, "authorization")
    == Ok("Bearer sk-test-key")
  assert http.header(request.headers, "content-type") == Ok("application/json")
  assert request.timeout_ms == 1000
}

pub fn multi_turn_messages_keep_order_test() {
  let params =
    types.ChatParams(..types.simple("m", "x", 5), messages: [
      Message("user", "a"),
      Message("assistant", "b"),
      Message("user", "c"),
    ])
  assert string.contains(
    body_of(params),
    "{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"assistant\",\"content\":\"b\"},{\"role\":\"user\",\"content\":\"c\"}",
  )
}

const completion_body =
  "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"model\":\"m-1\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}"

pub fn parse_plain_completion_test() {
  let assert Ok(completion) = openai.parse_completion(completion_body)
  assert completion.id == "chatcmpl-1"
  assert completion.model == "m-1"
  assert completion.text == "Hello"
  assert completion.finish_reason == Some("stop")
  assert completion.usage == Usage(Some(12), Some(3), None, None)
  assert completion.tool_calls == []
}

pub fn parse_cached_and_reasoning_token_details_test() {
  let body =
    "{\"choices\":[{\"message\":{\"content\":\"x\",\"reasoning\":\"thinking\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2000,\"completion_tokens\":50,\"prompt_tokens_details\":{\"cached_tokens\":1792},\"completion_tokens_details\":{\"reasoning_tokens\":40}}}"
  let assert Ok(completion) = openai.parse_completion(body)
  assert completion.usage == Usage(Some(2000), Some(50), Some(1792), Some(40))
  assert completion.reasoning == "thinking"
}

pub fn parse_tool_call_test() {
  let body =
    "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"pip install requests==2.31.0\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
  let assert Ok(completion) = openai.parse_completion(body)
  assert completion.text == ""
  assert completion.tool_calls
    == [ToolCall("run_shell", "{\"command\":\"pip install requests==2.31.0\"}")]
  assert completion.finish_reason == Some("tool_calls")
  assert completion.usage == types.no_usage
}

pub fn missing_usage_stays_missing_test() {
  let body = "{\"choices\":[{\"message\":{\"content\":\"x\"}}]}"
  let assert Ok(completion) = openai.parse_completion(body)
  assert completion.usage == Usage(None, None, None, None)
  assert completion.finish_reason == None
}

pub fn body_without_choices_is_an_error_test() {
  assert openai.parse_completion("{\"error\":{\"message\":\"no\"}}")
    == Error(Nil)
  assert openai.parse_completion("{\"choices\":[]}") == Error(Nil)
  assert openai.parse_completion("<html>502</html>") == Error(Nil)
}

pub fn error_message_shapes_test() {
  assert openai.error_message("{\"error\":{\"message\":\"bad model\"}}")
    == "bad model"
  assert openai.error_message("{\"error\":\"plain\"}") == "plain"
  assert openai.error_message("{\"message\":\"top\"}") == "top"
  assert openai.error_message("{\"detail\":\"fastapi\"}") == "fastapi"
  assert openai.error_message("upstream exploded") == "upstream exploded"
}

pub fn parse_models_lists_ids_test() {
  assert openai.parse_models(
      "{\"object\":\"list\",\"data\":[{\"id\":\"a\"},{\"id\":\"b\",\"owned_by\":\"x\"},{}]}",
    )
    == Ok(["a", "b"])
  assert openai.parse_models("{}") == Error(Nil)
}
