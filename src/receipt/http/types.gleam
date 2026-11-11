//// Plain data types for one HTTP exchange.
////
//// Everything Receipt observes about a relay arrives as a `Response` or a
//// `TransportError`. Bodies are kept as raw bytes and every network chunk
//// keeps its arrival time, so later analysis and trace replay see exactly
//// what was received.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type Method {
  Get
  Post
  Head
}

pub type Request {
  Request(
    method: Method,
    url: String,
    /// Header names are expected in lower case.
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

/// One chunk of response body as it arrived from the network.
pub type Chunk {
  Chunk(
    /// Monotonic microseconds since the request started.
    at_us: Int,
    data: BitArray,
  )
}

/// When things happened, in monotonic microseconds since the request
/// started. `None` means the event did not happen.
pub type Timing {
  Timing(
    headers_us: Option(Int),
    first_byte_us: Option(Int),
    done_us: Option(Int),
  )
}

pub type Response {
  Response(
    status: Int,
    /// Names in lower case; repeated headers appear once per occurrence.
    headers: List(#(String, String)),
    body: BitArray,
    chunks: List(Chunk),
    timing: Timing,
  )
}

pub type TransportError {
  Timeout
  Connect(detail: String)
  Tls(detail: String)
  Closed(detail: String)
  Other(detail: String)
  /// Replay only: no recorded exchange matches the request.
  TraceMiss(detail: String)
}

/// The function shape every transport has: live network, recorder, replayer.
pub type Transport =
  fn(Request) -> Result(Response, TransportError)

pub fn method_to_string(method: Method) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Head -> "HEAD"
  }
}

pub fn method_from_string(text: String) -> Result(Method, Nil) {
  case text {
    "GET" -> Ok(Get)
    "POST" -> Ok(Post)
    "HEAD" -> Ok(Head)
    _ -> Error(Nil)
  }
}

/// The first value of a header, matched case-insensitively.
pub fn header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  let wanted = string.lowercase(name)
  list.find_map(headers, fn(pair) {
    case string.lowercase(pair.0) == wanted {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

/// The body as text. Invalid UTF-8 yields an empty string: Receipt only
/// interprets textual bodies, and the raw bytes remain available.
pub fn body_text(response: Response) -> String {
  case bit_array.to_string(response.body) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

/// Whether the status is in the 2xx range.
pub fn is_success(response: Response) -> Bool {
  response.status >= 200 && response.status < 300
}

pub fn error_kind(error: TransportError) -> String {
  case error {
    Timeout -> "timeout"
    Connect(_) -> "connect"
    Tls(_) -> "tls"
    Closed(_) -> "closed"
    Other(_) -> "other"
    TraceMiss(_) -> "trace_miss"
  }
}

pub fn error_detail(error: TransportError) -> String {
  case error {
    Timeout -> ""
    Connect(detail)
    | Tls(detail)
    | Closed(detail)
    | Other(detail)
    | TraceMiss(detail) -> detail
  }
}

/// A one-line description for progress output and reports.
pub fn describe_error(error: TransportError) -> String {
  case error_detail(error) {
    "" -> error_kind(error)
    detail -> error_kind(error) <> ": " <> detail
  }
}
