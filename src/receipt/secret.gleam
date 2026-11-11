//// API key handling.
////
//// A key enters Receipt only from an environment variable. It is held in
//// an opaque value whose contents cannot be printed by accident, and is
//// revealed only where a request header is built. Everything written to a
//// trace or a report passes through `redact` first.

import envoy
import gleam/list
import gleam/string

/// An API key. The value is kept inside a closure so that inspecting or
/// logging a `Secret` never shows it.
pub opaque type Secret {
  Secret(reveal: fn() -> String, length: Int)
}

pub type KeyError {
  /// The environment variable is not set.
  Missing(variable: String)
  /// The environment variable is set but empty or only whitespace.
  Empty(variable: String)
}

/// Shortest key fragment that is treated as sensitive when redacting.
pub const min_fragment = 8

/// Read a key from an environment variable.
pub fn from_env(variable: String) -> Result(Secret, KeyError) {
  case envoy.get(variable) {
    Error(Nil) -> Error(Missing(variable))
    Ok(value) ->
      case string.trim(value) {
        "" -> Error(Empty(variable))
        trimmed -> Ok(from_string(trimmed))
      }
  }
}

/// Wrap a string as a secret. Used for the stand-in key during replay and
/// in tests; real keys come from `from_env`.
pub fn from_string(value: String) -> Secret {
  Secret(reveal: fn() { value }, length: string.length(value))
}

/// The key itself. Call only where a request is being built.
pub fn expose(secret: Secret) -> String {
  secret.reveal()
}

pub fn length(secret: Secret) -> Int {
  secret.length
}

/// The stand-in key of a given length: `sk-receipt-` followed by repeating
/// hexadecimal digits, cut to length. See `docs/TRACE_FORMAT.md`.
pub fn stand_in(length: Int) -> String {
  let filler = string.repeat("0123456789abcdef", length / 16 + 1)
  string.slice("sk-receipt-" <> filler, 0, length)
}

/// The secret to use when replaying a trace recorded with a key of this
/// length.
pub fn stand_in_secret(length: Int) -> Secret {
  from_string(stand_in(length))
}

/// Replace the key, and any fragment of it of `min_fragment` characters or
/// more, with the same positions of the stand-in key.
pub fn redact(text: String, secret: Secret) -> String {
  let key = secret.reveal()
  case secret.length < min_fragment || !has_fragment(text, key, secret.length) {
    True -> text
    False -> redact_fragments(text, key, stand_in(secret.length), secret.length)
  }
}

/// Whether the text contains any `min_fragment`-character window of the
/// key. Every longer fragment contains such a window, so this is an exact
/// pre-check.
fn has_fragment(text: String, key: String, key_length: Int) -> Bool {
  windows(key, key_length, min_fragment)
  |> list.any(fn(window) { string.contains(text, window.1) })
}

fn windows(key: String, key_length: Int, size: Int) -> List(#(Int, String)) {
  window_loop(key, key_length - size, size, [])
}

fn window_loop(
  key: String,
  start: Int,
  size: Int,
  acc: List(#(Int, String)),
) -> List(#(Int, String)) {
  case start < 0 {
    True -> acc
    False ->
      window_loop(key, start - 1, size, [
        #(start, string.slice(key, start, size)),
        ..acc
      ])
  }
}

fn redact_fragments(
  text: String,
  key: String,
  replacement: String,
  key_length: Int,
) -> String {
  // Longest fragments first, so a long match is not split into short ones.
  redact_size(text, key, replacement, key_length, key_length)
}

fn redact_size(
  text: String,
  key: String,
  replacement: String,
  key_length: Int,
  size: Int,
) -> String {
  case size < min_fragment {
    True -> text
    False -> {
      let text =
        windows(key, key_length, size)
        |> list.fold(text, fn(text, window) {
          let #(start, fragment) = window
          case string.contains(text, fragment) {
            True ->
              string.replace(
                text,
                fragment,
                string.slice(replacement, start, size),
              )
            False -> text
          }
        })
      case has_fragment(text, key, key_length) {
        True -> redact_size(text, key, replacement, key_length, size - 1)
        False -> text
      }
    }
  }
}

/// The length of the longest fragment of the key found in the text.
/// Fragments shorter than `min_fragment` are ordinary text and count as 0.
/// Used by Step 9 to grade a leak.
pub fn longest_fragment(text: String, secret: Secret) -> Int {
  let key = secret.reveal()
  longest_loop(text, key, secret.length, secret.length)
}

fn longest_loop(text: String, key: String, key_length: Int, size: Int) -> Int {
  case size < min_fragment {
    True -> 0
    False ->
      case
        windows(key, key_length, size)
        |> list.any(fn(window) { string.contains(text, window.1) })
      {
        True -> size
        False -> longest_loop(text, key, key_length, size - 1)
      }
  }
}

pub fn describe_error(error: KeyError) -> String {
  case error {
    Missing(variable) -> "environment variable " <> variable <> " is not set"
    Empty(variable) -> "environment variable " <> variable <> " is empty"
  }
}
