//// Serves recorded exchanges in place of the network.
////
//// Requests are matched on endpoint, method, URL and a hash of the body.
//// Exchanges that share a match key are served in recorded order. A
//// request with no match is an error and never reaches the network.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import receipt/http/types.{
  type Request, type Response, type TransportError, TraceMiss,
} as http
import receipt/trace/codec.{type Exchange, type Header, ExchangeLine, HeaderLine}
import simplifile

pub opaque type Replayer {
  Replayer(subject: Subject(Message), header: Header)
}

type Message {
  Take(key: String, reply: Subject(Result(Exchange, Nil)))
  Remaining(reply: Subject(Int))
}

/// The match key of a request.
pub fn match_key(endpoint: String, request: Request) -> String {
  let digest =
    crypto.hash(crypto.Sha256, bit_array.from_string(request.body))
    |> bit_array.base16_encode
  string.join(
    [endpoint, http.method_to_string(request.method), request.url, digest],
    " ",
  )
}

/// Parse the text of a trace file.
pub fn parse(text: String) -> Result(#(Header, List(Exchange)), String) {
  let lines =
    string.split(text, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  case lines {
    [] -> Error("trace is empty")
    [first, ..rest] ->
      case codec.decode_line(first) {
        Ok(HeaderLine(header)) -> {
          use exchanges <- result.try(parse_exchanges(rest, 2, []))
          Ok(#(header, exchanges))
        }
        Ok(ExchangeLine(_)) ->
          Error("line 1: trace does not start with a header")
        Error(error) -> Error("line 1: " <> codec.describe_error(error))
      }
  }
}

fn parse_exchanges(
  lines: List(String),
  number: Int,
  acc: List(Exchange),
) -> Result(List(Exchange), String) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [line, ..rest] ->
      case codec.decode_line(line) {
        Ok(ExchangeLine(exchange)) ->
          parse_exchanges(rest, number + 1, [exchange, ..acc])
        Ok(HeaderLine(_)) ->
          Error(
            "line " <> int.to_string(number) <> ": unexpected second header",
          )
        Error(error) ->
          Error(
            "line "
            <> int.to_string(number)
            <> ": "
            <> codec.describe_error(error),
          )
      }
  }
}

/// Start a replayer over already-parsed exchanges.
pub fn start(
  header: Header,
  exchanges: List(Exchange),
) -> Result(Replayer, String) {
  let queues =
    exchanges
    |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
    |> list.fold(dict.new(), fn(queues: Dict(String, List(Exchange)), exchange) {
      let key = match_key(exchange.endpoint, exchange.request)
      let queue = dict.get(queues, key) |> result.unwrap([])
      dict.insert(queues, key, [exchange, ..queue])
    })
    |> dict.map_values(fn(_, queue) { list.reverse(queue) })
  actor.new(queues)
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Replayer(started.data, header) })
  |> result.map_error(fn(_) { "cannot start the trace replayer" })
}

/// Read a trace file and start a replayer for it.
pub fn load(path: String) -> Result(Replayer, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "cannot read trace file "
      <> path
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  use #(header, exchanges) <- result.try(parse(text))
  start(header, exchanges)
}

fn handle(
  queues: Dict(String, List(Exchange)),
  message: Message,
) -> actor.Next(Dict(String, List(Exchange)), Message) {
  case message {
    Take(key, reply) ->
      case dict.get(queues, key) {
        Ok([next, ..rest]) -> {
          process.send(reply, Ok(next))
          actor.continue(dict.insert(queues, key, rest))
        }
        _ -> {
          process.send(reply, Error(Nil))
          actor.continue(queues)
        }
      }
    Remaining(reply) -> {
      let count =
        dict.fold(queues, 0, fn(total, _, queue) { total + list.length(queue) })
      process.send(reply, count)
      actor.continue(queues)
    }
  }
}

pub fn header(replayer: Replayer) -> Header {
  replayer.header
}

/// Serve the next recorded result for a request.
pub fn send(
  replayer: Replayer,
  endpoint: String,
  request: Request,
) -> Result(Response, TransportError) {
  let key = match_key(endpoint, request)
  case process.call(replayer.subject, 5000, Take(key, _)) {
    Ok(exchange) -> exchange.result
    Error(Nil) ->
      Error(TraceMiss(
        "no recorded exchange for "
        <> endpoint
        <> " "
        <> http.method_to_string(request.method)
        <> " "
        <> request.url,
      ))
  }
}

/// How many recorded exchanges have not been served.
pub fn remaining(replayer: Replayer) -> Int {
  process.call(replayer.subject, 5000, Remaining)
}
