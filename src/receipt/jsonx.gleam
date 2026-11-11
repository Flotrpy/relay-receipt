//// Tolerant JSON field access.
////
//// Relays return many slightly different response shapes. These decoders
//// never fail on a missing key, a `null`, or a value of the wrong type:
//// they yield `None`, and the caller decides what a missing field means
//// (usually: inconclusive).

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None}

/// A value at a path, or `None` if any segment is missing, null or of the
/// wrong type.
pub fn optional_at(
  path: List(String),
  inner: Decoder(a),
) -> Decoder(Option(a)) {
  decode.one_of(decode.optionally_at(path, None, decode.optional(inner)), [
    decode.success(None),
  ])
}

pub fn optional_int(path: List(String)) -> Decoder(Option(Int)) {
  optional_at(path, decode.int)
}

pub fn optional_string(path: List(String)) -> Decoder(Option(String)) {
  optional_at(path, decode.string)
}

/// A string at a path, or the default.
pub fn string_or(path: List(String), default: String) -> Decoder(String) {
  optional_string(path) |> decode.map(option.unwrap(_, default))
}

/// A list at a path, or an empty list. Elements that fail to decode make
/// the whole list empty rather than failing the parent.
pub fn list_or_empty(
  path: List(String),
  inner: Decoder(a),
) -> Decoder(List(a)) {
  optional_at(path, decode.list(inner)) |> decode.map(option.unwrap(_, []))
}
