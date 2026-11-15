import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import qcheck
import receipt/http/types.{Chunk}
import receipt/sse.{CommentItem, Event, EventItem}

fn data_of(parsed: sse.Parsed) -> List(String) {
  sse.events(parsed) |> list.map(fn(event) { event.data })
}

pub fn single_event_test() {
  let parsed = sse.parse_text("data: hello\n\n")
  assert parsed.items == [EventItem(Event("", "hello", None, 0))]
  assert !parsed.incomplete
}

pub fn openai_style_stream_test() {
  let parsed =
    sse.parse_text("data: {\"a\":1}\n\ndata: {\"a\":2}\n\ndata: [DONE]\n\n")
  assert data_of(parsed) == ["{\"a\":1}", "{\"a\":2}", "[DONE]"]
}

pub fn anthropic_style_named_events_test() {
  let parsed =
    sse.parse_text(
      "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: ping\ndata: {}\n\n",
    )
  assert sse.events(parsed) |> list.map(fn(event) { event.name })
    == ["message_start", "ping"]
}

pub fn multiple_data_lines_join_with_newline_test() {
  assert data_of(sse.parse_text("data: a\ndata: b\ndata:\n\n")) == ["a\nb\n"]
}

pub fn only_one_leading_space_is_stripped_test() {
  assert data_of(sse.parse_text("data:  two spaces\n\n")) == [" two spaces"]
  assert data_of(sse.parse_text("data:none\n\n")) == ["none"]
}

pub fn comments_are_kept_as_comment_items_test() {
  let parsed = sse.parse_text(": keep-alive\n\ndata: x\n\n")
  assert parsed.items
    == [CommentItem("keep-alive", 0), EventItem(Event("", "x", None, 0))]
  assert data_of(parsed) == ["x"]
}

pub fn crlf_and_cr_line_endings_test() {
  assert data_of(sse.parse_text("data: a\r\n\r\ndata: b\r\rdata: c\n\n"))
    == ["a", "b", "c"]
}

pub fn id_persists_across_events_test() {
  let parsed = sse.parse_text("id: 7\ndata: a\n\ndata: b\n\n")
  assert sse.events(parsed) |> list.map(fn(event) { event.id })
    == [Some("7"), Some("7")]
}

pub fn blank_lines_without_fields_dispatch_nothing_test() {
  assert sse.parse_text("\n\n\n").items == []
}

pub fn field_without_colon_has_empty_value_test() {
  assert data_of(sse.parse_text("data\n\n")) == [""]
}

pub fn unknown_fields_and_retry_are_ignored_test() {
  assert data_of(sse.parse_text("retry: 100\nfoo: bar\ndata: x\n\n")) == ["x"]
}

pub fn unterminated_event_marks_stream_incomplete_test() {
  let parsed = sse.parse_text("data: a\n\ndata: partial")
  assert data_of(parsed) == ["a"]
  assert parsed.incomplete
  assert sse.parse_text("data: no blank line\n").incomplete
}

pub fn events_take_the_time_of_the_completing_chunk_test() {
  let parsed =
    sse.parse_chunks([
      Chunk(100, <<"data: a\n\nda":utf8>>),
      Chunk(250, <<"ta: b\n":utf8>>),
      Chunk(400, <<"\n":utf8>>),
    ])
  assert sse.events(parsed)
    |> list.map(fn(event) { #(event.data, event.at_us) })
    == [#("a", 100), #("b", 400)]
}

pub fn crlf_split_across_chunks_is_one_line_ending_test() {
  let parsed =
    sse.parse_chunks([
      Chunk(1, <<"data: a\r":utf8>>),
      Chunk(2, <<"\n\r":utf8>>),
      Chunk(3, <<"\ndata: b\n\n":utf8>>),
    ])
  assert data_of(parsed) == ["a", "b"]
}

pub fn multibyte_character_split_across_chunks_test() {
  let assert <<first:bytes-size(8), rest:bytes>> = <<"data: é\n\n":utf8>>
  let parsed = sse.parse_chunks([Chunk(1, first), Chunk(2, rest)])
  assert data_of(parsed) == ["é"]
}

pub fn invalid_utf8_line_still_dispatches_with_marker_test() {
  let parsed =
    sse.parse_chunks([Chunk(1, <<"data: ":utf8, 0xFF, "\n\n":utf8>>)])
  assert data_of(parsed) == ["\u{FFFD}"]
}

fn split_at(data: BitArray, cuts: List(Int)) -> List(BitArray) {
  let size = bit_array.byte_size(data)
  case cuts {
    [] -> [data]
    [cut, ..rest] -> {
      let at = case size {
        0 -> 0
        _ -> cut % { size + 1 }
      }
      let assert Ok(head) = bit_array.slice(data, 0, at)
      let assert Ok(tail) = bit_array.slice(data, at, size - at)
      [head, ..split_at(tail, rest)]
    }
  }
}

pub fn result_does_not_depend_on_chunk_boundaries_test() {
  let stream =
    "event: a\ndata: {\"x\":\"héllo wörld\"}\n\n: ping\r\n\r\ndata: one\ndata: two\r\rid: 9\ndata: [DONE]\n\n"
  let whole = sse.parse_text(stream)
  use cuts <- qcheck.given(qcheck.generic_list(
    qcheck.bounded_int(0, 200),
    qcheck.bounded_int(0, 12),
  ))
  let chunks =
    split_at(bit_array.from_string(stream), cuts)
    |> list.map(fn(data) { Chunk(0, data) })
  let parsed = sse.parse_chunks(chunks)
  assert parsed.items == whole.items
  assert parsed.incomplete == whole.incomplete
}

pub fn generated_events_round_trip_test() {
  let payload = qcheck.string_from(qcheck.alphanumeric_ascii_codepoint())
  use payloads <- qcheck.given(qcheck.generic_list(
    payload,
    qcheck.bounded_int(0, 8),
  ))
  let text =
    payloads
    |> list.map(fn(data) { "data: " <> data <> "\n\n" })
    |> list.fold("", fn(acc, part) { acc <> part })
  assert data_of(sse.parse_text(text)) == payloads
}
