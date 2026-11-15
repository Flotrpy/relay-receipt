//// A function that returns the next item of a list on each call, for
//// driving state machines in tests.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub opaque type Sequence(a) {
  Sequence(subject: Subject(Message(a)))
}

type Message(a) {
  Next(reply: Subject(#(a, Int)))
  Count(reply: Subject(Int))
}

/// Items are served in order; after the last, `fallback` is served.
pub fn start(items: List(a), fallback: a) -> Sequence(a) {
  let assert Ok(started) =
    actor.new(#(items, 0))
    |> actor.on_message(fn(state: #(List(a), Int), message) {
      let #(queue, served) = state
      case message {
        Next(reply) -> {
          let #(item, rest) = case queue {
            [first, ..rest] -> #(first, rest)
            [] -> #(fallback, [])
          }
          process.send(reply, #(item, served))
          actor.continue(#(rest, served + 1))
        }
        Count(reply) -> {
          process.send(reply, served)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Sequence(started.data)
}

pub fn next(sequence: Sequence(a)) -> a {
  process.call(sequence.subject, 5000, Next).0
}

/// How many items have been served.
pub fn served(sequence: Sequence(a)) -> Int {
  process.call(sequence.subject, 5000, Count)
}
