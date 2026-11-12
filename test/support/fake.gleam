//// A simulated relay for step tests.
////
//// It speaks the OpenAI-compatible and Anthropic-compatible chat formats
//// and answers Receipt's probes the way a simple, obedient model would.
//// Faults can be switched on to imitate a dishonest relay. It is a test
//// double, not a model: its "understanding" is a handful of rules keyed
//// on what the probes ask for.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/regexp
import gleam/string
import receipt/client
import receipt/http/types.{
  type Request, type Response, type TransportError, Chunk, Response, Timing,
}
import receipt/jsonx

pub type Fake {
  Fake(
    /// Which chat formats answer.
    openai: Bool,
    anthropic: Bool,
    /// Ids returned by the model list.
    models: List(String),
    /// A system prompt the relay silently prepends. Empty for none.
    hidden_prompt: String,
    /// Whether `usage` is reported at all.
    reports_usage: Bool,
    /// Characters per billed token. Honest relays of the same model agree;
    /// a different value imitates a different tokenizer.
    chars_per_token: Int,
    /// Whether the hidden prompt outranks the caller's system prompt.
    hidden_overrides: Bool,
    /// Whether requests carrying a system message are rejected.
    rejects_system: Bool,
    /// How the model describes itself.
    self_description: String,
    /// Keep only this many characters of the user message. 0 keeps all.
    truncate_chars: Int,
    /// Refuse user messages longer than this with HTTP 413. 0 for none.
    max_prompt_chars: Int,
  )
}

/// An honest relay with no faults.
pub fn honest() -> Fake {
  Fake(
    openai: True,
    anthropic: False,
    models: ["test-model", "other-model"],
    hidden_prompt: "",
    reports_usage: True,
    chars_per_token: 4,
    hidden_overrides: False,
    rejects_system: False,
    self_description: "I am test-model, an AI assistant trained by TestLab.",
    truncate_chars: 0,
    max_prompt_chars: 0,
  )
}

/// What the fake extracted from a chat request.
pub type Chat {
  Chat(
    model: String,
    system: String,
    /// The text of the last user message.
    user: String,
    /// All message contents joined, for token counting.
    all_text: String,
    max_tokens: Int,
    stream: Bool,
    /// Length of the last user message in characters.
    user_chars: Int,
  )
}

/// A rough token count: one token per four characters, rounded up.
pub fn tokens(text: String) -> Int {
  tokens_at(text, 4)
}

fn tokens_at(text: String, chars_per_token: Int) -> Int {
  { string.length(text) + chars_per_token - 1 } / chars_per_token
}

/// Tokens the fake bills for a prompt: a fixed template overhead plus the
/// text, plus any hidden prompt.
pub fn billed_prompt_tokens(fake: Fake, chat: Chat) -> Int {
  let count = tokens_at(_, fake.chars_per_token)
  7 + count(chat.system) + count(chat.all_text) + count(fake.hidden_prompt)
}

pub fn handler(fake: Fake) -> client.Handler {
  fn(_endpoint: String, request: Request) { respond(fake, request) }
}

pub fn respond(
  fake: Fake,
  request: Request,
) -> Result(Response, TransportError) {
  let path = request.url
  case
    string.ends_with(path, "/models"),
    string.ends_with(path, "/chat/completions"),
    string.ends_with(path, "/messages")
  {
    True, _, _ -> json_reply(200, models_body(fake))
    _, True, _ if fake.openai -> openai_chat(fake, request)
    _, _, True if fake.anthropic -> anthropic_chat(fake, request)
    _, _, _ -> json_reply(404, error_body("Not found: " <> path))
  }
}

pub fn json_reply(
  status: Int,
  body: String,
) -> Result(Response, TransportError) {
  Ok(Response(
    status: status,
    headers: [#("content-type", "application/json")],
    body: <<body:utf8>>,
    chunks: [Chunk(1000, <<body:utf8>>)],
    timing: Timing(Some(900), Some(1000), Some(1000)),
  ))
}

pub fn error_body(message: String) -> String {
  json.object([
    #(
      "error",
      json.object([
        #("message", json.string(message)),
        #("type", json.string("invalid_request_error")),
      ]),
    ),
  ])
  |> json.to_string
}

fn models_body(fake: Fake) -> String {
  json.object([
    #("object", json.string("list")),
    #(
      "data",
      json.array(fake.models, fn(id) {
        json.object([
          #("id", json.string(id)),
          #("object", json.string("model")),
          #("owned_by", json.string("testlab")),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn message_decoder() -> decode.Decoder(#(String, String)) {
  use role <- decode.then(jsonx.string_or(["role"], ""))
  use content <- decode.then(jsonx.string_or(["content"], ""))
  decode.success(#(role, content))
}

/// Parse a chat request body in either format.
pub fn parse_chat(body: String) -> Result(Chat, Nil) {
  let decoder = {
    use model <- decode.field("model", decode.string)
    use messages <- decode.field("messages", decode.list(message_decoder()))
    use top_system <- decode.then(jsonx.string_or(["system"], ""))
    use max_tokens <- decode.then(jsonx.optional_int(["max_tokens"]))
    use stream <- decode.then(jsonx.optional_at(["stream"], decode.bool))
    decode.success(#(model, messages, top_system, max_tokens, stream))
  }
  case json.parse(body, decoder) {
    Error(_) -> Error(Nil)
    Ok(#(model, messages, top_system, max_tokens, stream)) -> {
      let system_messages =
        list.filter(messages, fn(m) { m.0 == "system" })
        |> list.map(fn(m) { m.1 })
      let others = list.filter(messages, fn(m) { m.0 != "system" })
      let user =
        list.filter(others, fn(m) { m.0 == "user" })
        |> list.last
        |> option.from_result
        |> option.map(fn(m) { m.1 })
        |> option.unwrap("")
      Ok(Chat(
        model: model,
        system: string.join([top_system, ..system_messages], ""),
        user: user,
        all_text: string.join(list.map(others, fn(m) { m.1 }), ""),
        max_tokens: option.unwrap(max_tokens, 256),
        stream: option.unwrap(stream, False),
        user_chars: string.length(user),
      ))
    }
  }
}

fn asks_for_prompt(text: String) -> Bool {
  let lower = string.lowercase(text)
  string.contains(lower, "system prompt")
  || string.contains(lower, "instruction you were given")
  || string.contains(lower, "every instruction")
  || string.contains(lower, "system-level instructions")
  || string.contains(lower, "text you received before")
  || string.contains(lower, "configuration text")
}

/// The word a "reply with exactly the single word" instruction asks for.
fn demanded_word(system: String) -> Result(String, Nil) {
  case string.split_once(system, "exactly the single word \"") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Ok(#(word, _)) -> Ok(word)
        Error(Nil) -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// The fake model's answer to a chat. Extended as steps need behaviours.
pub fn answer(fake: Fake, chat: Chat) -> String {
  let overridden = fake.hidden_overrides && fake.hidden_prompt != ""
  case demanded_word(chat.system), overridden {
    Ok(word), False -> word
    _, _ -> plain_answer(fake, chat)
  }
}

/// Every `[CANARY-...]` marker in a text, one per line.
fn list_canaries(text: String) -> String {
  let assert Ok(pattern) =
    regexp.from_string("\\[(CANARY-[0-9]+-[0-9a-f]{8})\\]")
  regexp.scan(pattern, text)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(marker)] -> Ok(marker)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn plain_answer(fake: Fake, chat: Chat) -> String {
  let seen = case fake.truncate_chars {
    0 -> chat.user
    keep -> string.slice(chat.user, 0, keep)
  }
  let lower = string.lowercase(string.slice(chat.user, 0, 400))
  use <- bool.guard(string.contains(seen, "markers that look like [CANARY-"), {
    // Skip the example marker in the instruction itself.
    case string.split_once(seen, "nothing else.\n\n") {
      Ok(#(_, body)) -> list_canaries(body)
      Error(Nil) -> ""
    }
  })
  case asks_for_prompt(chat.user), fake.hidden_prompt {
    True, "" -> "I don't have a system prompt in this conversation."
    True, hidden -> "```\n" <> hidden <> "\n```"
    False, _ ->
      case string.contains(lower, "which ai model are you") {
        True -> fake.self_description
        False ->
          case string.contains(lower, "2 + 2") {
            True -> "2 + 2 equals 4."
            False -> "ok"
          }
      }
  }
}

fn usage_pairs(
  fake: Fake,
  prompt_key: String,
  completion_key: String,
  prompt: Int,
  completion: Int,
) -> List(#(String, json.Json)) {
  case fake.reports_usage {
    False -> []
    True -> [
      #(
        "usage",
        json.object([
          #(prompt_key, json.int(prompt)),
          #(completion_key, json.int(completion)),
        ]),
      ),
    ]
  }
}

fn bad_request() -> Result(Response, TransportError) {
  json_reply(
    400,
    error_body("We could not parse the JSON body of your request."),
  )
}

fn openai_chat(
  fake: Fake,
  request: Request,
) -> Result(Response, TransportError) {
  case parse_chat(request.body) {
    Error(Nil) -> bad_request()
    Ok(chat)
      if fake.max_prompt_chars > 0 && fake.max_prompt_chars < chat.user_chars
    -> json_reply(413, error_body("Request too large for this model."))
    Ok(chat) if fake.rejects_system && chat.system != "" ->
      json_reply(422, error_body("System messages are not supported."))
    Ok(chat) -> {
      let text = answer(fake, chat)
      json.object(list.append(
        [
          #(
            "id",
            json.string(
              "chatcmpl-fake-" <> int.to_string(tokens(chat.all_text)),
            ),
          ),
          #("object", json.string("chat.completion")),
          #("model", json.string(chat.model)),
          #(
            "choices",
            json.preprocessed_array([
              json.object([
                #("index", json.int(0)),
                #(
                  "message",
                  json.object([
                    #("role", json.string("assistant")),
                    #("content", json.string(text)),
                  ]),
                ),
                #("finish_reason", json.string("stop")),
              ]),
            ]),
          ),
        ],
        usage_pairs(
          fake,
          "prompt_tokens",
          "completion_tokens",
          billed_prompt_tokens(fake, chat),
          tokens(text),
        ),
      ))
      |> json.to_string
      |> json_reply(200, _)
    }
  }
}

fn anthropic_chat(
  fake: Fake,
  request: Request,
) -> Result(Response, TransportError) {
  case parse_chat(request.body) {
    Error(Nil) -> bad_request()
    Ok(chat) -> {
      let text = answer(fake, chat)
      json.object(list.append(
        [
          #("id", json.string("msg_01fake")),
          #("type", json.string("message")),
          #("role", json.string("assistant")),
          #("model", json.string(chat.model)),
          #(
            "content",
            json.preprocessed_array([
              json.object([
                #("type", json.string("text")),
                #("text", json.string(text)),
              ]),
            ]),
          ),
          #("stop_reason", json.string("end_turn")),
        ],
        usage_pairs(
          fake,
          "input_tokens",
          "output_tokens",
          billed_prompt_tokens(fake, chat),
          tokens(text),
        ),
      ))
      |> json.to_string
      |> json_reply(200, _)
    }
  }
}
