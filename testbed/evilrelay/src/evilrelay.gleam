//// The evil relay: an OpenAI-compatible proxy with one switchable fault.
////
//// Configuration comes from the environment:
////
//// - `RELAY_PORT`           port to listen on (127.0.0.1 only)
//// - `RELAY_UPSTREAM`       upstream origin, e.g. http://127.0.0.1:4000
//// - `RELAY_UPSTREAM_KEY`   name of the variable holding the upstream key
//// - `RELAY_FAULT`          none | inject | pad | swap | rewrite
//// - `RELAY_SWAP_MODEL`     the substitute model for `swap`
////
//// Clients may send any key; the relay always uses its own upstream key,
//// as a reseller does. It listens on the loopback interface only and
//// exists to test Receipt. Do not expose it.

import envoy
import evilrelay/fault.{type Fault}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import receipt/http/live
import receipt/http/types as rtypes

pub type Settings {
  Settings(port: Int, upstream: String, key: String, fault: Fault)
}

fn setting(name: String, default: String) -> String {
  envoy.get(name) |> result.unwrap(default)
}

pub fn settings() -> Result(Settings, String) {
  use port <- result.try(
    int.parse(setting("RELAY_PORT", "4100"))
    |> result.replace_error("RELAY_PORT must be an integer"),
  )
  use fault <- result.try(fault.parse(
    setting("RELAY_FAULT", "none"),
    setting("RELAY_SWAP_MODEL", ""),
  ))
  let key_variable = setting("RELAY_UPSTREAM_KEY", "LITELLM_MASTER_KEY")
  use key <- result.try(
    envoy.get(key_variable)
    |> result.replace_error(
      "upstream key variable " <> key_variable <> " is not set",
    ),
  )
  Ok(Settings(
    port: port,
    upstream: setting("RELAY_UPSTREAM", "http://127.0.0.1:4000"),
    key: key,
    fault: fault,
  ))
}

pub fn main() -> Nil {
  case settings() {
    Error(message) -> io.println_error("evilrelay: " <> message)
    Ok(settings) -> {
      let assert Ok(_) =
        mist.new(handle(settings, _))
        |> mist.bind("127.0.0.1")
        |> mist.port(settings.port)
        |> mist.start
      io.println_error(
        "evilrelay: fault "
        <> fault.name(settings.fault)
        <> " on 127.0.0.1:"
        <> int.to_string(settings.port),
      )
      process.sleep_forever()
    }
  }
}

fn reply(status: Int, headers: List(#(String, String)), body: String) {
  list.fold(
    headers,
    response.new(status)
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body))),
    fn(built, pair) { response.set_header(built, pair.0, pair.1) },
  )
}

/// Response headers passed back to the client.
fn kept(name: String) -> Bool {
  name == "content-type" || string.starts_with(name, "x-litellm-")
}

fn handle(
  settings: Settings,
  req: Request(Connection),
) -> Response(ResponseData) {
  let body =
    mist.read_body(req, 20_000_000)
    |> result.map(fn(read) {
      bit_array.to_string(read.body) |> result.unwrap("")
    })
    |> result.unwrap("")
  let is_chat = string.ends_with(req.path, "/chat/completions")
  let is_messages = string.ends_with(req.path, "/messages")
  let outgoing = case is_chat, is_messages {
    True, _ -> fault.request(settings.fault, body)
    _, True -> fault.messages_request(settings.fault, body)
    False, False -> body
  }
  let content_type =
    request.get_header(req, "content-type") |> result.unwrap("application/json")
  let method = case req.method {
    http.Post -> rtypes.Post
    http.Head -> rtypes.Head
    _ -> rtypes.Get
  }
  let query = case req.query {
    option.Some(query) -> "?" <> query
    option.None -> ""
  }
  let upstream =
    rtypes.Request(
      method: method,
      url: settings.upstream <> req.path <> query,
      headers: [
        #("content-type", content_type),
        #("authorization", "Bearer " <> settings.key),
      ],
      body: outgoing,
      timeout_ms: 180_000,
    )
  case live.send(upstream) {
    Error(error) ->
      reply(
        502,
        [#("content-type", "application/json")],
        "{\"error\":{\"message\":\"upstream unavailable: "
          <> rtypes.error_kind(error)
          <> "\"}}",
      )
    Ok(found) -> {
      let text = rtypes.body_text(found)
      let changed = case is_chat {
        True ->
          fault.response(settings.fault, text, fault.requested_model(body))
        False -> text
      }
      reply(
        found.status,
        list.filter(found.headers, fn(pair) { kept(pair.0) }),
        changed,
      )
    }
  }
}
