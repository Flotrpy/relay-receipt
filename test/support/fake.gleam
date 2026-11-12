//// A simulated relay for step tests.
////
//// It speaks the OpenAI-compatible and Anthropic-compatible chat formats
//// and answers Receipt's probes the way a simple, obedient model would.
//// Faults can be switched on to imitate a dishonest relay. It is a test
//// double, not a model: its "understanding" is a handful of rules keyed
//// on what the probes ask for.

import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/regexp
import gleam/result
import gleam/string
import receipt/client
import receipt/http/types.{
  type Request, type Response, type TransportError, Chunk, Response, Timing,
} as http
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
    /// Replacements the relay applies to everything the model returns.
    rewrites: List(#(String, String)),
    /// Whether tool definitions are honoured.
    supports_tools: Bool,
    /// Text appended to every error message. `{key}` is replaced by the
    /// caller's key and `{key16}` by its first 16 characters.
    error_suffix: String,
    /// Answer every request, however broken, with HTTP 200.
    swallows_errors: Bool,
    /// A defect in streamed responses: "", "no_done", "two_ids",
    /// "double_finish", "after_done", "bad_json" or "model_switch".
    stream_fault: String,
    /// Share of requests (0 to 100) on which answers are padded, imitating
    /// provider-side token inflation.
    inflation_percent: Int,
    /// Cut every answer at `max_tokens` and say so.
    always_truncates: Bool,
    /// Which simulated model answers tool-choice and short-text probes.
    /// Two relays with the same persona behave alike; different personas
    /// prefer different tool names and different words.
    persona: Int,
    /// Sequence number of the request, set by `handler`.
    call: Int,
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
    rewrites: [],
    supports_tools: True,
    error_suffix: "",
    swallows_errors: False,
    stream_fault: "",
    inflation_percent: 0,
    always_truncates: False,
    persona: 0,
    call: 0,
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
    /// Names of the tools offered.
    tools: List(String),
    /// The model name is one Receipt made up to provoke an error.
    unknown_model: Bool,
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

/// A handler for the fake. Requests are numbered so that repeated
/// identical requests can get different (but reproducible) answers.
pub fn handler(fake: Fake) -> client.Handler {
  let assert Ok(counter) =
    actor.new(0)
    |> actor.on_message(fn(count: Int, reply: Subject(Int)) {
      process.send(reply, count)
      actor.continue(count + 1)
    })
    |> actor.start
  fn(_endpoint: String, request: Request) {
    let call = process.call(counter.data, 5000, fn(reply) { reply })
    respond(Fake(..fake, call: call), request)
  }
}

pub fn respond(
  fake: Fake,
  request: Request,
) -> Result(Response, TransportError) {
  case route(fake, request) {
    Ok(response) if response.status >= 400 ->
      case fake.swallows_errors {
        True -> json_reply(200, "{\"ok\":true}")
        False -> Ok(with_error_suffix(fake, request, response))
      }
    other -> other
  }
}

fn caller_key(request: Request) -> String {
  case http.header(request.headers, "authorization") {
    Ok("Bearer " <> key) -> key
    _ -> ""
  }
}

fn with_error_suffix(
  fake: Fake,
  request: Request,
  response: Response,
) -> Response {
  case fake.error_suffix {
    "" -> response
    suffix -> {
      let key = caller_key(request)
      let suffix =
        suffix
        |> string.replace("{key16}", string.slice(key, 0, 16))
        |> string.replace("{key}", key)
      let body = error_body("Request failed. " <> suffix)
      Response(..response, body: <<body:utf8>>, chunks: [
        Chunk(1000, <<body:utf8>>),
      ])
    }
  }
}

fn route(fake: Fake, request: Request) -> Result(Response, TransportError) {
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
    use tools <- decode.then(jsonx.list_or_empty(
      ["tools"],
      decode.one_of(decode.at(["function", "name"], decode.string), [
        decode.at(["name"], decode.string),
      ]),
    ))
    decode.success(#(model, messages, top_system, max_tokens, stream, tools))
  }
  case json.parse(body, decoder) {
    Error(_) -> Error(Nil)
    Ok(#(model, messages, top_system, max_tokens, stream, tools)) -> {
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
        tools: tools,
        unknown_model: string.starts_with(model, "receipt-nonexistent-model-"),
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

const reasoning_filler =
  "First consider what the question asks. Then compare each option with what is known. The option that fits the facts is the one to choose. "

const padding_filler =
  "It is worth noting some background before answering, since context always helps the reader appreciate the topic more fully. "

/// A stable pseudo-random percentage for a prompt, so that partial
/// inflation hits the same requests on every run.
fn percent_of(text: String) -> Int {
  string.to_utf_codepoints(text)
  |> list.fold(7, fn(hash, codepoint) {
    { hash * 31 + string.utf_codepoint_to_int(codepoint) } % 1_000_003
  })
  |> fn(hash) { hash % 100 }
}

/// A short answer normally; a longer one when asked to show reasoning.
/// Under inflation the answer is long already, and the probe adds little.
fn multiple_choice_answer(fake: Fake, user: String) -> String {
  let probed =
    string.contains(user, "reasoning steps")
    || string.contains(user, "derivation step by step")
  let inflated = percent_of(user) < fake.inflation_percent
  case inflated, probed {
    True, False -> string.repeat(padding_filler, 8) <> "Answer: B"
    True, True ->
      string.repeat(padding_filler, 8) <> reasoning_filler <> "Answer: B"
    False, False -> "Answer: B"
    False, True -> string.repeat(reasoning_filler, 3) <> "Answer: B"
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
  use <- bool.guard(
    string.contains(chat.user, "Answer: <letter>"),
    multiple_choice_answer(fake, chat.user),
  )
  use <- bool.guard(
    string.starts_with(chat.user, "Repeat the following line exactly"),
    string.split(chat.user, "\n") |> list.last |> result.unwrap(""),
  )
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
          case string.contains(lower, "2 + 2"), chat.max_tokens == 30 {
            True, _ -> "2 + 2 equals 4."
            False, True -> persona_sentence(fake, chat.user)
            False, False -> "ok"
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
    Ok(chat) if chat.unknown_model ->
      json_reply(
        404,
        error_body("The model `" <> chat.model <> "` does not exist."),
      )
    Ok(chat) if chat.stream -> Ok(openai_stream(fake, chat))
    Ok(chat) if fake.rejects_system && chat.system != "" ->
      json_reply(422, error_body("System messages are not supported."))
    Ok(chat) -> {
      let text = rewrite(fake, answer(fake, chat))
      let shell = fake.supports_tools && list.contains(chat.tools, "run_shell")
      let tool_call = case shell, fake.supports_tools, chat.tools {
        True, _, _ ->
          string.split_once(chat.user, "command set to exactly: ")
          |> option.from_result
          |> option.map(fn(pair) {
            #(
              "run_shell",
              json.to_string(
                json.object([
                  #("command", json.string(rewrite(fake, pair.1))),
                ]),
              ),
            )
          })
        False, True, [_, ..] -> Some(#(preferred_tool(fake, chat), "{}"))
        _, _, _ -> None
      }
      let #(message, finish) = case tool_call {
        Some(#(tool_name, tool_arguments)) -> #(
          json.object([
            #("role", json.string("assistant")),
            #("content", json.null()),
            #(
              "tool_calls",
              json.preprocessed_array([
                json.object([
                  #("id", json.string("call_fake_1")),
                  #("type", json.string("function")),
                  #(
                    "function",
                    json.object([
                      #("name", json.string(tool_name)),
                      #("arguments", json.string(tool_arguments)),
                    ]),
                  ),
                ]),
              ]),
            ),
          ]),
          "tool_calls",
        )
        None -> #(
          json.object([
            #("role", json.string("assistant")),
            #("content", json.string(text)),
          ]),
          case fake.always_truncates {
            True -> "length"
            False -> "stop"
          },
        )
      }
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
                #("message", message),
                #("finish_reason", json.string(finish)),
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

fn stream_chunk(
  id: String,
  model: String,
  content: String,
  finish: json.Json,
) -> String {
  json.object([
    #("id", json.string(id)),
    #("object", json.string("chat.completion.chunk")),
    #("model", json.string(model)),
    #(
      "choices",
      json.preprocessed_array([
        json.object([
          #("index", json.int(0)),
          #("delta", json.object([#("content", json.string(content))])),
          #("finish_reason", finish),
        ]),
      ]),
    ),
  ])
  |> json.to_string
}

/// A streamed OpenAI-style answer, one event per network chunk.
fn openai_stream(fake: Fake, chat: Chat) -> Response {
  let fault = fake.stream_fault
  let id = "chatcmpl-fake-stream"
  let second_id = case fault {
    "two_ids" -> "chatcmpl-other"
    _ -> id
  }
  let second_model = case fault {
    "model_switch" -> "cheaper-model"
    _ -> chat.model
  }
  let stop = json.string("stop")
  let payloads =
    list.flatten([
      [
        stream_chunk(id, chat.model, "1 2 ", json.null()),
        case fault {
          "bad_json" -> "{\"id\": broken"
          _ -> stream_chunk(second_id, second_model, "3 4 5", json.null())
        },
        stream_chunk(id, chat.model, "", stop),
      ],
      case fault {
        "double_finish" -> [stream_chunk(id, chat.model, "", stop)]
        _ -> []
      },
      case fault {
        "no_done" -> []
        _ -> ["[DONE]"]
      },
      case fault {
        "after_done" -> [stream_chunk(id, chat.model, " and more", json.null())]
        _ -> []
      },
    ])
  let chunks =
    list.index_map(payloads, fn(payload, index) {
      Chunk(100_000 + index * 20_000, <<
        "data: ":utf8,
        payload:utf8,
        "\n\n":utf8,
      >>)
    })
  Response(
    status: 200,
    headers: [#("content-type", "text/event-stream")],
    body: list.fold(chunks, <<>>, fn(acc, chunk) {
      <<acc:bits, chunk.data:bits>>
    }),
    chunks: chunks,
    timing: Timing(Some(90_000), Some(100_000), Some(200_000)),
  )
}

/// The tool a persona picks: its favourite (the alphabetically first
/// name for persona 0, the last for any other) three times in four,
/// otherwise another one. The pick does not depend on the order in which
/// the tools were offered.
fn preferred_tool(fake: Fake, chat: Chat) -> String {
  let sorted = list.sort(chat.tools, string.compare)
  let ranked = case fake.persona {
    0 -> sorted
    _ -> list.reverse(sorted)
  }
  let roll = percent_of(chat.user <> int.to_string(fake.call))
  case ranked {
    [favourite, ..others] ->
      case roll < 75, others {
        True, _ | False, [] -> favourite
        False, others ->
          list.drop(others, roll % list.length(others))
          |> list.first
          |> result.unwrap(favourite)
      }
    [] -> ""
  }
}

const plain_words = [
  "the",
  "a",
  "good",
  "way",
  "is",
  "to",
  "try",
  "it",
  "and",
  "you",
  "can",
  "be",
  "sure",
  "of",
  "that",
]

const ornate_words = [
  "verily",
  "henceforth",
  "splendid",
  "contrivance",
  "behold",
  "wherefore",
  "luminous",
  "quixotic",
  "ephemeral",
  "labyrinth",
  "zephyr",
  "obsidian",
]

/// A short sentence in the persona's vocabulary, varying with the call.
fn persona_sentence(fake: Fake, user: String) -> String {
  let words = case fake.persona {
    0 -> plain_words
    _ -> ornate_words
  }
  [1, 2, 3, 4, 5, 6, 7]
  |> list.map(fn(position) {
    let roll =
      percent_of(
        user <> int.to_string(fake.call) <> "/" <> int.to_string(position),
      )
    list.drop(words, roll % list.length(words))
    |> list.first
    |> result.unwrap("so")
  })
  |> string.join(" ")
}

/// Apply the relay's return-path replacements.
fn rewrite(fake: Fake, text: String) -> String {
  list.fold(fake.rewrites, text, fn(text, pair) {
    string.replace(text, pair.0, pair.1)
  })
}

fn anthropic_chat(
  fake: Fake,
  request: Request,
) -> Result(Response, TransportError) {
  case parse_chat(request.body) {
    Error(Nil) -> bad_request()
    Ok(chat) -> {
      let text = rewrite(fake, answer(fake, chat))
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
