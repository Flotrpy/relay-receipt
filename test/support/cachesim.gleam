//// A simulated provider-side prefix cache with tenant isolation.
////
//// Each endpoint routes its requests round-robin over a list of cache
//// domains. A domain remembers the prompts it has seen and reports, for
//// each new request, how many leading tokens it had already cached
//// (rounded down to a chunk, and only above a minimum length). This is
//// enough to reproduce hits, misses and self-hits, with a topology that
//// is known by construction.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import receipt/client
import receipt/http/types.{type Request, Chunk, Response, Timing}
import receipt/jsonx

pub const chunk = 64

pub const minimum = 1024

type State {
  State(
    routes: Dict(String, List(String)),
    turns: Dict(String, Int),
    caches: Dict(String, List(List(String))),
    silent: List(String),
  )
}

type Message {
  Serve(
    endpoint: String,
    tokens: List(String),
    reply: Subject(#(Int, Int, Bool)),
  )
}

fn common_prefix(a: List(String), b: List(String), count: Int) -> Int {
  case a, b {
    [x, ..rest_a], [y, ..rest_b] if x == y ->
      common_prefix(rest_a, rest_b, count + 1)
    _, _ -> count
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let Serve(endpoint, tokens, reply) = message
  let domains = dict.get(state.routes, endpoint) |> result.unwrap([endpoint])
  let turn = dict.get(state.turns, endpoint) |> result.unwrap(0)
  let domain =
    list.drop(domains, turn % int.max(1, list.length(domains)))
    |> list.first
    |> result.unwrap(endpoint)
  let seen = dict.get(state.caches, domain) |> result.unwrap([])
  let longest =
    list.fold(seen, 0, fn(best, stored) {
      int.max(best, common_prefix(stored, tokens, 0))
    })
  let rounded = longest / chunk * chunk
  let cached = case rounded >= minimum {
    True -> rounded
    False -> 0
  }
  process.send(reply, #(
    list.length(tokens),
    cached,
    !list.contains(state.silent, endpoint),
  ))
  actor.continue(
    State(
      ..state,
      turns: dict.insert(state.turns, endpoint, turn + 1),
      caches: dict.insert(state.caches, domain, [tokens, ..seen]),
    ),
  )
}

/// A handler for a topology: `#(endpoint name, cache domains)`. Endpoints
/// named in `silent` report no cached-token count.
pub fn start(
  topology: List(#(String, List(String))),
  silent: List(String),
) -> client.Handler {
  let assert Ok(started) =
    actor.new(State(dict.from_list(topology), dict.new(), dict.new(), silent))
    |> actor.on_message(handle)
    |> actor.start
  fn(endpoint: String, request: Request) {
    let content =
      json.parse(
        request.body,
        decode.at(["messages"], decode.list(jsonx.string_or(["content"], ""))),
      )
      |> result.unwrap([])
      |> string.join(" ")
    let tokens =
      string.split(content, "\n")
      |> list.flat_map(string.split(_, " "))
      |> list.filter(fn(token) { token != "" })
    let #(prompt_tokens, cached, reports) =
      process.call(started.data, 5000, Serve(endpoint, tokens, _))
    let usage = case reports {
      True ->
        json.object([
          #("prompt_tokens", json.int(prompt_tokens)),
          #("completion_tokens", json.int(1)),
          #(
            "prompt_tokens_details",
            json.object([#("cached_tokens", json.int(cached))]),
          ),
        ])
      False ->
        json.object([
          #("prompt_tokens", json.int(prompt_tokens)),
          #("completion_tokens", json.int(1)),
        ])
    }
    let body =
      json.object([
        #("id", json.string("chatcmpl-sim")),
        #(
          "choices",
          json.preprocessed_array([
            json.object([
              #("message", json.object([#("content", json.string("OK"))])),
              #("finish_reason", json.string("stop")),
            ]),
          ]),
        ),
        #("usage", usage),
      ])
      |> json.to_string
    Ok(Response(
      status: 200,
      headers: [#("content-type", "application/json")],
      body: <<body:utf8>>,
      chunks: [Chunk(1000, <<body:utf8>>)],
      timing: Timing(Some(900), Some(1000), Some(1000)),
    ))
  }
}
