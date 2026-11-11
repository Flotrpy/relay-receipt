//// An incremental parser for server-sent events.
////
//// Follows the WHATWG event-stream format: lines end in LF, CRLF or CR;
//// an empty line dispatches the event; `data` lines are joined with a
//// newline; a line starting with `:` is a comment. Input is fed chunk by
//// chunk exactly as it arrived, and each parsed item carries the arrival
//// time of the chunk that completed it. The result does not depend on
//// where chunk boundaries fall.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/http/types.{type Chunk}

pub type Event {
  Event(
    /// The `event:` field, or an empty string when absent.
    name: String,
    data: String,
    id: Option(String),
    /// Arrival time of the chunk that completed this event.
    at_us: Int,
  )
}

pub type Item {
  EventItem(Event)
  /// A comment line (`: text`), often used as a keep-alive.
  CommentItem(text: String, at_us: Int)
}

pub opaque type Parser {
  Parser(
    /// Bytes of the current, not yet terminated line.
    line: BitArray,
    /// The previous byte was CR, so a following LF belongs to it.
    after_cr: Bool,
    name: String,
    data: List(String),
    id: Option(String),
    /// Whether any field has been seen since the last dispatch.
    has_fields: Bool,
  )
}

pub type Parsed {
  Parsed(
    items: List(Item),
    /// True when the stream ended inside an event or a line. A complete
    /// stream ends with a blank line, so this indicates truncation.
    incomplete: Bool,
  )
}

pub fn new() -> Parser {
  Parser(
    line: <<>>,
    after_cr: False,
    name: "",
    data: [],
    id: None,
    has_fields: False,
  )
}

/// Feed one chunk. Returns the advanced parser and the items the chunk
/// completed, in order.
pub fn feed(
  parser: Parser,
  data: BitArray,
  at_us: Int,
) -> #(Parser, List(Item)) {
  let #(parser, items) = scan(parser, data, at_us, [])
  #(parser, list.reverse(items))
}

/// Whether the parser is holding a partial line or an undispatched event.
pub fn is_incomplete(parser: Parser) -> Bool {
  bit_array.byte_size(parser.line) > 0 || parser.has_fields
}

/// Parse a complete response from its chunks.
pub fn parse_chunks(chunks: List(Chunk)) -> Parsed {
  let #(parser, items) =
    list.fold(chunks, #(new(), []), fn(acc, chunk) {
      let #(parser, items) = acc
      let #(parser, more) = feed(parser, chunk.data, chunk.at_us)
      #(parser, list.append(items, more))
    })
  Parsed(items: items, incomplete: is_incomplete(parser))
}

/// Parse a complete body held as text, with every item stamped at time 0.
pub fn parse_text(text: String) -> Parsed {
  let #(parser, items) = feed(new(), bit_array.from_string(text), 0)
  Parsed(items: items, incomplete: is_incomplete(parser))
}

/// Only the events of a parse, dropping comments.
pub fn events(parsed: Parsed) -> List(Event) {
  list.filter_map(parsed.items, fn(item) {
    case item {
      EventItem(event) -> Ok(event)
      CommentItem(..) -> Error(Nil)
    }
  })
}

fn scan(
  parser: Parser,
  data: BitArray,
  at_us: Int,
  items: List(Item),
) -> #(Parser, List(Item)) {
  case data {
    <<>> -> #(parser, items)
    <<10, rest:bytes>> ->
      case parser.after_cr {
        // The LF of a CRLF pair: the line already ended at the CR.
        True -> scan(Parser(..parser, after_cr: False), rest, at_us, items)
        False -> {
          let #(parser, items) = end_line(parser, at_us, items)
          scan(parser, rest, at_us, items)
        }
      }
    <<13, rest:bytes>> -> {
      let #(parser, items) = end_line(parser, at_us, items)
      scan(Parser(..parser, after_cr: True), rest, at_us, items)
    }
    <<byte, rest:bytes>> ->
      scan(
        Parser(..parser, line: <<parser.line:bits, byte>>, after_cr: False),
        rest,
        at_us,
        items,
      )
    _ -> #(parser, items)
  }
}

fn end_line(
  parser: Parser,
  at_us: Int,
  items: List(Item),
) -> #(Parser, List(Item)) {
  let line = case bit_array.to_string(parser.line) {
    Ok(text) -> text
    // Invalid UTF-8 cannot be a field Receipt understands; keep a marker so
    // the event is still dispatched and the anomaly is visible downstream.
    Error(Nil) -> "data: \u{FFFD}"
  }
  let parser = Parser(..parser, line: <<>>, after_cr: False)
  case line {
    "" -> dispatch(parser, at_us, items)
    ":" <> comment -> #(parser, [
      CommentItem(strip_one_space(comment), at_us),
      ..items
    ])
    _ -> #(apply_field(parser, line), items)
  }
}

fn dispatch(
  parser: Parser,
  at_us: Int,
  items: List(Item),
) -> #(Parser, List(Item)) {
  let cleared = Parser(..parser, name: "", data: [], has_fields: False)
  case parser.has_fields {
    False -> #(cleared, items)
    True -> {
      let event =
        Event(
          name: parser.name,
          data: string.join(list.reverse(parser.data), "\n"),
          id: parser.id,
          at_us: at_us,
        )
      #(cleared, [EventItem(event), ..items])
    }
  }
}

fn apply_field(parser: Parser, line: String) -> Parser {
  let #(field, value) = case string.split_once(line, ":") {
    Ok(#(field, value)) -> #(field, strip_one_space(value))
    Error(Nil) -> #(line, "")
  }
  let parser = Parser(..parser, has_fields: True)
  case field {
    "event" -> Parser(..parser, name: value)
    "data" -> Parser(..parser, data: [value, ..parser.data])
    "id" -> Parser(..parser, id: Some(value))
    // `retry` and unknown fields are ignored, as the format requires.
    _ -> parser
  }
}

fn strip_one_space(value: String) -> String {
  case value {
    " " <> rest -> rest
    _ -> value
  }
}
