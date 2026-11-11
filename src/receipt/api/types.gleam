//// Format-neutral chat types shared by the OpenAI and Anthropic adapters.

import gleam/json.{type Json}
import gleam/option.{type Option, None}

pub type ApiFormat {
  OpenAi
  Anthropic
}

pub type Message {
  Message(role: String, content: String)
}

/// A tool the model may call. `parameters` is a JSON Schema object.
pub type Tool {
  Tool(name: String, description: String, parameters: Json)
}

pub type ChatParams {
  ChatParams(
    model: String,
    system: Option(String),
    messages: List(Message),
    max_tokens: Int,
    temperature: Option(Float),
    tools: List(Tool),
    stream: Bool,
  )
}

/// Token counts as reported by the endpoint. Every field is optional
/// because endpoints omit them, and a missing count must stay visible.
pub type Usage {
  Usage(
    prompt_tokens: Option(Int),
    completion_tokens: Option(Int),
    cached_tokens: Option(Int),
    reasoning_tokens: Option(Int),
  )
}

pub type ToolCall {
  ToolCall(
    name: String,
    /// The arguments exactly as returned: a JSON document in a string.
    arguments: String,
  )
}

pub type Completion {
  Completion(
    id: String,
    model: String,
    text: String,
    /// Reasoning text, when the endpoint returns it separately.
    reasoning: String,
    tool_calls: List(ToolCall),
    finish_reason: Option(String),
    usage: Usage,
  )
}

pub const no_usage = Usage(None, None, None, None)

/// A single user message with common defaults: no system prompt, no tools,
/// no streaming, provider-default temperature.
pub fn simple(model: String, prompt: String, max_tokens: Int) -> ChatParams {
  ChatParams(
    model: model,
    system: None,
    messages: [Message("user", prompt)],
    max_tokens: max_tokens,
    temperature: None,
    tools: [],
    stream: False,
  )
}

pub fn with_system(params: ChatParams, system: String) -> ChatParams {
  ChatParams(..params, system: option.Some(system))
}

pub fn with_temperature(params: ChatParams, temperature: Float) -> ChatParams {
  ChatParams(..params, temperature: option.Some(temperature))
}

pub fn with_tools(params: ChatParams, tools: List(Tool)) -> ChatParams {
  ChatParams(..params, tools: tools)
}

pub fn streaming(params: ChatParams) -> ChatParams {
  ChatParams(..params, stream: True)
}

pub fn format_to_string(format: ApiFormat) -> String {
  case format {
    OpenAi -> "openai"
    Anthropic -> "anthropic"
  }
}

pub fn format_from_string(text: String) -> Result(ApiFormat, Nil) {
  case text {
    "openai" -> Ok(OpenAi)
    "anthropic" -> Ok(Anthropic)
    _ -> Error(Nil)
  }
}

/// Output tokens that correspond to visible text: the reported completion
/// count minus the reported reasoning count, when both are present.
pub fn visible_output_tokens(usage: Usage) -> Option(Int) {
  case usage.completion_tokens, usage.reasoning_tokens {
    option.Some(total), option.Some(reasoning) if reasoning <= total ->
      option.Some(total - reasoning)
    option.Some(total), _ -> option.Some(total)
    None, _ -> None
  }
}
