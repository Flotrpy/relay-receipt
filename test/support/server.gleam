//// A local HTTP server for transport tests. Started at most once per test
//// run; later calls find the port already bound and do nothing.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import receipt/http/live
import receipt/http/types.{Get, Request}

pub const port = 18_471

pub fn base_url() -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

/// Make sure the server is listening. The server runs under its own
/// unlinked process so it outlives the test that first asked for it.
pub fn ensure_started() -> Nil {
  case is_up() {
    True -> Nil
    False -> {
      process.spawn_unlinked(fn() {
        let _ =
          mist.new(handle)
          |> mist.bind("127.0.0.1")
          |> mist.port(port)
          |> mist.start
        process.sleep_forever()
      })
      wait_until_up(100)
    }
  }
}

fn is_up() -> Bool {
  case live.send(Request(Get, base_url() <> "/json", [], "", 500)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn wait_until_up(attempts: Int) -> Nil {
  case attempts <= 0 || is_up() {
    True -> Nil
    False -> {
      process.sleep(20)
      wait_until_up(attempts - 1)
    }
  }
}

fn handle(req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["json"] -> text(200, "application/json", "{\"ok\":true}")
    ["status", code] ->
      text(
        int.parse(code) |> result.unwrap(500),
        "application/json",
        "{\"error\":{\"message\":\"status " <> code <> "\"}}",
      )
    ["echo"] -> echo_request(req)
    ["slow"] -> {
      process.sleep(1500)
      text(200, "text/plain", "late")
    }
    ["stream"] -> stream(req)
    ["dup-headers"] ->
      text(200, "text/plain", "x")
      |> response.prepend_header("x-tag", "one")
      |> response.prepend_header("x-tag", "two")
    _ -> text(404, "application/json", "{\"error\":\"not found\"}")
  }
}

fn text(status: Int, content_type: String, body: String) {
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn echo_request(req: Request(Connection)) -> Response(ResponseData) {
  let headers =
    req.headers
    |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
    |> string.join("\n")
  let body = case mist.read_body(req, 10_000_000) {
    Ok(read) -> bit_array.to_string(read.body) |> result.unwrap("<binary>")
    Error(_) -> "<unreadable>"
  }
  text(200, "text/plain", headers <> "\n\n" <> body)
}

type StreamMessage {
  Emit(index: Int)
}

/// Three server-sent events, 60 ms apart, then the terminator.
fn stream(req: Request(Connection)) -> Response(ResponseData) {
  mist.chunked(
    request: req,
    response: response.new(200)
      |> response.set_header("content-type", "text/event-stream"),
    init: fn(subject) {
      process.send_after(subject, 10, Emit(0))
      subject
    },
    loop: fn(subject, message, connection) {
      let Emit(index) = message
      case index < 3 {
        True -> {
          let payload = "data: {\"n\":" <> int.to_string(index) <> "}\n\n"
          let _ = mist.send_chunk(connection, bit_array.from_string(payload))
          process.send_after(subject, 60, Emit(index + 1))
          mist.chunk_continue(subject)
        }
        False -> {
          let _ =
            mist.send_chunk(
              connection,
              bit_array.from_string("data: [DONE]\n\n"),
            )
          mist.chunk_stop()
        }
      }
    },
  )
}
