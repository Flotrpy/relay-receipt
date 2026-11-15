//// Writes exchanges to a trace file as they happen.
////
//// The recorder is a process, so requests issued concurrently (for
//// example the keep-warm workers of Step 16) are serialised into one file.
//// Every exchange is redacted before it is written.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import receipt/secret.{type Secret}
import receipt/trace/codec.{type Exchange, type Header, Observation}
import receipt/trace/redact
import simplifile

pub opaque type Recorder {
  Recorder(subject: Subject(Message))
}

type Message {
  NextSeq(reply: Subject(Int))
  Write(exchange: Exchange)
  Observe(step: Int, key: String, value: String)
  Sync(reply: Subject(Int))
}

type State {
  State(path: String, next_seq: Int, written: Int, secrets: List(Secret))
}

/// Create the trace file with its header and start the recorder.
pub fn start(
  path: String,
  header: Header,
  secrets: List(Secret),
) -> Result(Recorder, String) {
  use _ <- result.try(
    simplifile.write(path, codec.encode_header(header) <> "\n")
    |> result.map_error(fn(error) {
      "cannot write trace file "
      <> path
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  actor.new(State(path: path, next_seq: 0, written: 0, secrets: secrets))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Recorder(started.data) })
  |> result.map_error(fn(_) { "cannot start the trace recorder" })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    NextSeq(reply) -> {
      process.send(reply, state.next_seq)
      actor.continue(State(..state, next_seq: state.next_seq + 1))
    }
    Write(exchange) -> {
      let line =
        redact.exchange(exchange, state.secrets) |> codec.encode_exchange
      // A failed append must not abort the audit; the count shows the gap.
      case simplifile.append(state.path, line <> "\n") {
        Ok(Nil) -> actor.continue(State(..state, written: state.written + 1))
        Error(_) -> actor.continue(state)
      }
    }
    Observe(step, key, value) -> {
      let line =
        Observation(
          seq: state.next_seq,
          step: step,
          key: redact.text(key, state.secrets),
          value: redact.text(value, state.secrets),
        )
        |> codec.encode_observation
      let state = State(..state, next_seq: state.next_seq + 1)
      case simplifile.append(state.path, line <> "\n") {
        Ok(Nil) -> actor.continue(State(..state, written: state.written + 1))
        Error(_) -> actor.continue(state)
      }
    }
    Sync(reply) -> {
      process.send(reply, state.written)
      actor.continue(state)
    }
  }
}

/// Reserve the sequence number for a request that is about to start.
pub fn next_seq(recorder: Recorder) -> Int {
  process.call(recorder.subject, 5000, NextSeq)
}

/// Record a finished exchange.
pub fn write(recorder: Recorder, exchange: Exchange) -> Nil {
  process.send(recorder.subject, Write(exchange))
}

/// Record a non-HTTP lookup.
pub fn observe(
  recorder: Recorder,
  step: Int,
  key: String,
  value: String,
) -> Nil {
  process.send(recorder.subject, Observe(step, key, value))
}

/// Wait until everything sent so far is on disk. Returns the number of
/// lines written after the header.
pub fn sync(recorder: Recorder) -> Int {
  process.call(recorder.subject, 30_000, Sync)
}
