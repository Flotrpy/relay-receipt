//// Encoding and decoding of trace lines. See `docs/TRACE_FORMAT.md`.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/anthropic
import receipt/api/openai
import receipt/api/types.{Usage}
import receipt/http/types.{
  type Request, type Response, type TransportError, Chunk, Request, Response,
  Timing,
} as http
import receipt/jsonx
import receipt/sse

pub const format_name = "receipt-trace"

pub const format_version = 1

pub type Header {
  Header(
    tool_version: String,
    created_at: String,
    seed: Int,
    /// Key length per endpoint name.
    key_lengths: List(#(String, Int)),
  )
}

pub type Exchange {
  Exchange(
    seq: Int,
    endpoint: String,
    step: Int,
    label: String,
    request: Request,
    /// Monotonic microseconds since the start of the run.
    started_us: Int,
    result: Result(Response, TransportError),
  )
}

pub type Line {
  HeaderLine(Header)
  ExchangeLine(Exchange)
}

pub type DecodeError {
  NotJson
  UnknownFormat(format: String, version: Int)
  BadLine(detail: String)
}

pub fn encode_header(header: Header) -> String {
  json.object([
    #("type", json.string("header")),
    #("format", json.string(format_name)),
    #("version", json.int(format_version)),
    #("tool_version", json.string(header.tool_version)),
    #("created_at", json.string(header.created_at)),
    #("seed", json.int(header.seed)),
    #(
      "key_lengths",
      json.object(
        list.map(header.key_lengths, fn(pair) { #(pair.0, json.int(pair.1)) }),
      ),
    ),
  ])
  |> json.to_string
}

pub fn encode_exchange(exchange: Exchange) -> String {
  let #(response, sse_events, timing, usage, error) = case exchange.result {
    Ok(response) -> #(
      response_json(response),
      sse_json(response),
      timing_json(exchange.started_us, Some(response.timing)),
      usage_json(response),
      json.null(),
    )
    Error(error) -> #(
      json.null(),
      json.null(),
      timing_json(exchange.started_us, None),
      json.null(),
      json.object([
        #("kind", json.string(http.error_kind(error))),
        #("detail", json.string(http.error_detail(error))),
      ]),
    )
  }
  json.object([
    #("type", json.string("exchange")),
    #("seq", json.int(exchange.seq)),
    #("endpoint", json.string(exchange.endpoint)),
    #("step", json.int(exchange.step)),
    #("label", json.string(exchange.label)),
    #(
      "request",
      json.object([
        #("method", json.string(http.method_to_string(exchange.request.method))),
        #("url", json.string(exchange.request.url)),
        #("headers", pairs_json(exchange.request.headers)),
        #("body", json.string(exchange.request.body)),
        #("timeout_ms", json.int(exchange.request.timeout_ms)),
      ]),
    ),
    #("response", response),
    #("sse", sse_events),
    #("timing", timing),
    #("usage", usage),
    #("error", error),
  ])
  |> json.to_string
}

fn pairs_json(pairs: List(#(String, String))) -> Json {
  json.array(pairs, fn(pair) {
    json.preprocessed_array([json.string(pair.0), json.string(pair.1)])
  })
}

fn response_json(response: Response) -> Json {
  json.object([
    #("status", json.int(response.status)),
    #("headers", pairs_json(response.headers)),
    #("body_b64", json.string(bit_array.base64_encode(response.body, True))),
    #(
      "chunks",
      json.array(response.chunks, fn(chunk) {
        json.object([
          #("at_us", json.int(chunk.at_us)),
          #("bytes", json.int(bit_array.byte_size(chunk.data))),
        ])
      }),
    ),
  ])
}

fn is_event_stream(response: Response) -> Bool {
  case http.header(response.headers, "content-type") {
    Ok(value) -> string.contains(string.lowercase(value), "text/event-stream")
    Error(Nil) -> False
  }
}

fn sse_json(response: Response) -> Json {
  case is_event_stream(response) {
    False -> json.null()
    True ->
      sse.parse_chunks(response.chunks)
      |> sse.events
      |> json.array(fn(event) {
        json.object([
          #("at_us", json.int(event.at_us)),
          #("event", json.string(event.name)),
          #("data", json.string(event.data)),
        ])
      })
  }
}

fn timing_json(started_us: Int, timing: Option(http.Timing)) -> Json {
  let field = fn(pick: fn(http.Timing) -> Option(Int)) {
    json.nullable(option.then(timing, pick), json.int)
  }
  json.object([
    #("started_us", json.int(started_us)),
    #("headers_us", field(fn(t) { t.headers_us })),
    #("first_byte_us", field(fn(t) { t.first_byte_us })),
    #("done_us", field(fn(t) { t.done_us })),
  ])
}

/// Usage as either adapter would read it from a JSON body, or null.
fn usage_json(response: Response) -> Json {
  let body = http.body_text(response)
  let openai = json.parse(body, openai.usage_decoder())
  let anthropic = json.parse(body, anthropic.usage_decoder(["usage"]))
  let usage = case openai, anthropic {
    Ok(Usage(None, None, None, None)), Ok(other) -> Some(other)
    Ok(found), _ -> Some(found)
    Error(_), Ok(other) -> Some(other)
    Error(_), Error(_) -> None
  }
  case usage {
    None | Some(Usage(None, None, None, None)) -> json.null()
    Some(Usage(prompt, completion, cached, reasoning)) ->
      json.object([
        #("prompt_tokens", json.nullable(prompt, json.int)),
        #("completion_tokens", json.nullable(completion, json.int)),
        #("cached_tokens", json.nullable(cached, json.int)),
        #("reasoning_tokens", json.nullable(reasoning, json.int)),
      ])
  }
}

/// Decode one line of a trace file.
pub fn decode_line(line: String) -> Result(Line, DecodeError) {
  case json.parse(line, jsonx.string_or(["type"], "")) {
    Error(_) -> Error(NotJson)
    Ok("header") -> decode_header(line)
    Ok("exchange") ->
      case json.parse(line, exchange_decoder()) {
        Ok(Ok(exchange)) -> Ok(ExchangeLine(exchange))
        Ok(Error(detail)) -> Error(BadLine(detail))
        Error(_) ->
          Error(BadLine("exchange line has missing or mistyped fields"))
      }
    Ok(other) -> Error(BadLine("unknown line type: " <> other))
  }
}

fn decode_header(line: String) -> Result(Line, DecodeError) {
  let decoder = {
    use format <- decode.field("format", decode.string)
    use version <- decode.field("version", decode.int)
    use tool_version <- decode.then(jsonx.string_or(["tool_version"], ""))
    use created_at <- decode.then(jsonx.string_or(["created_at"], ""))
    use seed <- decode.field("seed", decode.int)
    use key_lengths <- decode.then(jsonx.optional_at(
      ["key_lengths"],
      decode.dict(decode.string, decode.int),
    ))
    decode.success(#(
      format,
      version,
      tool_version,
      created_at,
      seed,
      key_lengths,
    ))
  }
  case json.parse(line, decoder) {
    Error(_) -> Error(BadLine("header line has missing or mistyped fields"))
    Ok(#(format, version, tool_version, created_at, seed, key_lengths)) ->
      case format == format_name && version == format_version {
        False -> Error(UnknownFormat(format, version))
        True ->
          Ok(
            HeaderLine(
              Header(
                tool_version: tool_version,
                created_at: created_at,
                seed: seed,
                key_lengths: case key_lengths {
                  Some(lengths) -> dict_to_sorted_list(lengths)
                  None -> []
                },
              ),
            ),
          )
      }
  }
}

fn dict_to_sorted_list(entries: Dict(String, Int)) -> List(#(String, Int)) {
  dict.to_list(entries)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn pairs_decoder() -> Decoder(List(#(String, String))) {
  decode.list({
    use name <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(name, value))
  })
}

fn exchange_decoder() -> Decoder(Result(Exchange, String)) {
  use seq <- decode.field("seq", decode.int)
  use endpoint <- decode.field("endpoint", decode.string)
  use step <- decode.then(jsonx.optional_int(["step"]))
  use label <- decode.then(jsonx.string_or(["label"], ""))
  use method <- decode.subfield(["request", "method"], decode.string)
  use url <- decode.subfield(["request", "url"], decode.string)
  use headers <- decode.subfield(["request", "headers"], pairs_decoder())
  use body <- decode.subfield(["request", "body"], decode.string)
  use timeout_ms <- decode.then(jsonx.optional_int(["request", "timeout_ms"]))
  use started_us <- decode.then(jsonx.optional_int(["timing", "started_us"]))
  use headers_us <- decode.then(jsonx.optional_int(["timing", "headers_us"]))
  use first_byte_us <- decode.then(
    jsonx.optional_int(["timing", "first_byte_us"]),
  )
  use done_us <- decode.then(jsonx.optional_int(["timing", "done_us"]))
  use response <- decode.then(jsonx.optional_at(
    ["response"],
    raw_response_decoder(),
  ))
  use error_kind <- decode.then(jsonx.optional_string(["error", "kind"]))
  use error_detail <- decode.then(jsonx.string_or(["error", "detail"], ""))

  let request = case http.method_from_string(method) {
    Ok(method) ->
      Ok(Request(method, url, headers, body, option.unwrap(timeout_ms, 60_000)))
    Error(Nil) -> Error("unknown method: " <> method)
  }
  let timing = Timing(headers_us, first_byte_us, done_us)
  let result = case response, error_kind {
    Some(raw), _ -> build_response(raw, timing) |> option_ok
    None, Some(kind) -> Ok(Error(error_from(kind, error_detail)))
    None, None -> Error("exchange has neither response nor error")
  }
  case request, result {
    Ok(request), Ok(result) ->
      decode.success(
        Ok(Exchange(
          seq: seq,
          endpoint: endpoint,
          step: option.unwrap(step, 0),
          label: label,
          request: request,
          started_us: option.unwrap(started_us, 0),
          result: result,
        )),
      )
    Error(detail), _ -> decode.success(Error(detail))
    _, Error(detail) -> decode.success(Error(detail))
  }
}

fn option_ok(
  built: Result(Response, String),
) -> Result(Result(Response, TransportError), String) {
  case built {
    Ok(response) -> Ok(Ok(response))
    Error(detail) -> Error(detail)
  }
}

type RawResponse {
  RawResponse(
    status: Int,
    headers: List(#(String, String)),
    body_b64: String,
    chunks: List(#(Int, Int)),
  )
}

fn raw_response_decoder() -> Decoder(RawResponse) {
  use status <- decode.field("status", decode.int)
  use headers <- decode.field("headers", pairs_decoder())
  use body_b64 <- decode.field("body_b64", decode.string)
  use chunks <- decode.field(
    "chunks",
    decode.list({
      use at_us <- decode.field("at_us", decode.int)
      use bytes <- decode.field("bytes", decode.int)
      decode.success(#(at_us, bytes))
    }),
  )
  decode.success(RawResponse(status, headers, body_b64, chunks))
}

/// Rebuild a response, re-splitting the body at the recorded chunk sizes.
fn build_response(
  raw: RawResponse,
  timing: http.Timing,
) -> Result(Response, String) {
  case bit_array.base64_decode(raw.body_b64) {
    Error(Nil) -> Error("body_b64 is not valid base64")
    Ok(body) ->
      case split_chunks(body, raw.chunks, []) {
        Error(detail) -> Error(detail)
        Ok(chunks) ->
          Ok(Response(
            status: raw.status,
            headers: raw.headers,
            body: body,
            chunks: chunks,
            timing: timing,
          ))
      }
  }
}

fn split_chunks(
  body: BitArray,
  sizes: List(#(Int, Int)),
  acc: List(http.Chunk),
) -> Result(List(http.Chunk), String) {
  case sizes {
    [] ->
      case bit_array.byte_size(body) {
        0 -> Ok(list.reverse(acc))
        _ -> Error("chunk sizes do not add up to the body length")
      }
    [#(at_us, size), ..rest] ->
      case bit_array.slice(body, 0, size) {
        Error(Nil) -> Error("chunk sizes do not add up to the body length")
        Ok(data) -> {
          let assert Ok(remaining) =
            bit_array.slice(body, size, bit_array.byte_size(body) - size)
          split_chunks(remaining, rest, [Chunk(at_us, data), ..acc])
        }
      }
  }
}

fn error_from(kind: String, detail: String) -> TransportError {
  case kind {
    "timeout" -> http.Timeout
    "connect" -> http.Connect(detail)
    "tls" -> http.Tls(detail)
    "closed" -> http.Closed(detail)
    "trace_miss" -> http.TraceMiss(detail)
    _ -> http.Other(detail)
  }
}

pub fn describe_error(error: DecodeError) -> String {
  case error {
    NotJson -> "line is not JSON"
    UnknownFormat(format, version) ->
      "unsupported trace format "
      <> format
      <> " version "
      <> string.inspect(version)
    BadLine(detail) -> detail
  }
}
