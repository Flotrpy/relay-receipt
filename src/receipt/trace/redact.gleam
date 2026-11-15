//// Redaction of an exchange before it is written to a trace.
//// See the "Redaction" section of `docs/TRACE_FORMAT.md`.

import gleam/bit_array
import gleam/list
import receipt/http/types.{type Request, type Response, Chunk, Request, Response}
import receipt/secret.{type Secret}
import receipt/trace/codec.{type Exchange, Exchange}

/// Request headers whose values are always replaced.
pub const sensitive_headers = [
  "authorization", "x-api-key", "api-key", "x-goog-api-key",
]

pub const placeholder = "[redacted]"

/// Redact one exchange against every key in use.
pub fn exchange(exchange: Exchange, secrets: List(Secret)) -> Exchange {
  Exchange(
    ..exchange,
    request: request(exchange.request, secrets),
    result: case exchange.result {
      Ok(found) -> Ok(response(found, secrets))
      Error(error) -> Error(error)
    },
  )
}

pub fn text(value: String, secrets: List(Secret)) -> String {
  list.fold(secrets, value, secret.redact)
}

pub fn request(req: Request, secrets: List(Secret)) -> Request {
  Request(
    ..req,
    url: text(req.url, secrets),
    headers: list.map(req.headers, fn(pair) {
      case list.contains(sensitive_headers, pair.0) {
        True -> #(pair.0, placeholder)
        False -> #(pair.0, text(pair.1, secrets))
      }
    }),
    body: text(req.body, secrets),
  )
}

/// The stand-in key has the key's length, so redaction never changes the
/// length of a body and the recorded chunk sizes stay valid.
pub fn response(found: Response, secrets: List(Secret)) -> Response {
  Response(
    ..found,
    headers: list.map(found.headers, fn(pair) {
      #(pair.0, text(pair.1, secrets))
    }),
    body: bytes(found.body, secrets),
    chunks: resplit(bytes(found.body, secrets), found.chunks),
  )
}

fn bytes(data: BitArray, secrets: List(Secret)) -> BitArray {
  case bit_array.to_string(data) {
    Ok(value) -> bit_array.from_string(text(value, secrets))
    // Not text, so it cannot contain a textual key.
    Error(Nil) -> data
  }
}

/// Cut the redacted body at the original chunk sizes, so a key that
/// straddled two chunks is redacted in both.
fn resplit(body: BitArray, chunks: List(types.Chunk)) -> List(types.Chunk) {
  let #(_, out) =
    list.fold(chunks, #(body, []), fn(acc, chunk) {
      let #(remaining, out) = acc
      let size = bit_array.byte_size(chunk.data)
      let total = bit_array.byte_size(remaining)
      case
        bit_array.slice(remaining, 0, size),
        bit_array.slice(remaining, size, total - size)
      {
        Ok(head), Ok(tail) -> #(tail, [Chunk(chunk.at_us, head), ..out])
        _, _ -> #(remaining, [chunk, ..out])
      }
    })
  list.reverse(out)
}
