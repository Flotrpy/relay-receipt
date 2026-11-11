//// A scripted transport for tests: hands out canned results in order and
//// remembers the requests it saw.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import receipt/client
import receipt/http/types.{
  type Request, type Response, type TransportError, Other, Response, Timing,
}

pub opaque type Script {
  Script(subject: Subject(Message))
}

type Message {
  Next(request: Request, reply: Subject(Result(Response, TransportError)))
  Seen(reply: Subject(List(Request)))
}

type State {
  State(queue: List(Result(Response, TransportError)), seen: List(Request))
}

pub fn start(results: List(Result(Response, TransportError))) -> Script {
  let assert Ok(started) =
    actor.new(State(results, []))
    |> actor.on_message(fn(state: State, message) {
      case message {
        Next(request, reply) -> {
          let #(result, queue) = case state.queue {
            [first, ..rest] -> #(first, rest)
            [] -> #(Error(Other("script exhausted")), [])
          }
          process.send(reply, result)
          actor.continue(State(queue, [request, ..state.seen]))
        }
        Seen(reply) -> {
          process.send(reply, list.reverse(state.seen))
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Script(started.data)
}

pub fn handler(script: Script) -> client.Handler {
  fn(_endpoint, request) {
    process.call(script.subject, 5000, Next(request, _))
  }
}

pub fn seen(script: Script) -> List(Request) {
  process.call(script.subject, 5000, Seen)
}

/// A response with a status, headers and a text body, as one chunk.
pub fn reply(
  status: Int,
  headers: List(#(String, String)),
  body: String,
) -> Result(Response, TransportError) {
  Ok(Response(
    status: status,
    headers: headers,
    body: <<body:utf8>>,
    chunks: [types.Chunk(0, <<body:utf8>>)],
    timing: Timing(None, None, None),
  ))
}

pub fn ok(body: String) -> Result(Response, TransportError) {
  reply(200, [#("content-type", "application/json")], body)
}
