//// The live network transport: a typed front for the Erlang `httpc` shim.
//// See `docs/adr/0002-http-ffi.md`.

import gleam/list
import gleam/option.{type Option, None, Some}
import receipt/http/types.{
  type Method, type Request, type Response, type TransportError, Chunk, Closed,
  Connect, Other, Response, Timeout, Timing, Tls,
}

type RawResponse =
  #(
    Int,
    List(#(String, String)),
    BitArray,
    List(#(Int, BitArray)),
    Int,
    Int,
    Int,
  )

@external(erlang, "receipt_http_ffi", "request")
fn ffi_request(
  method: Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> Result(RawResponse, #(String, String))

/// Send a request over the network and wait for the complete response.
pub fn send(request: Request) -> Result(Response, TransportError) {
  case
    ffi_request(
      request.method,
      request.url,
      request.headers,
      request.body,
      request.timeout_ms,
    )
  {
    Ok(#(status, headers, body, chunks, headers_us, first_byte_us, done_us)) ->
      Ok(Response(
        status: status,
        headers: headers,
        body: body,
        chunks: list.map(chunks, fn(chunk) { Chunk(chunk.0, chunk.1) }),
        timing: Timing(
          headers_us: optional(headers_us),
          first_byte_us: optional(first_byte_us),
          done_us: optional(done_us),
        ),
      ))
    Error(#(kind, detail)) -> Error(to_error(kind, detail))
  }
}

fn optional(value: Int) -> Option(Int) {
  case value < 0 {
    True -> None
    False -> Some(value)
  }
}

fn to_error(kind: String, detail: String) -> TransportError {
  case kind {
    "timeout" -> Timeout
    "connect" -> Connect(detail)
    "tls" -> Tls(detail)
    "closed" -> Closed(detail)
    _ -> Other(detail)
  }
}
