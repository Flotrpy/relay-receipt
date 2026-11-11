import gleam/option.{None, Some}
import gleam/string
import qcheck
import receipt/http/types.{
  Chunk, Connect, Get, Post, Request, Response, Timeout, Timing,
}
import receipt/trace/codec.{
  BadLine, Exchange, ExchangeLine, Header, HeaderLine, NotJson, UnknownFormat,
}

fn sample_request() {
  Request(
    Post,
    "https://relay.example/v1/chat/completions",
    [#("content-type", "application/json"), #("authorization", "[redacted]")],
    "{\"model\":\"m\",\"messages\":[]}",
    60_000,
  )
}

fn sample_response() {
  Response(
    status: 200,
    headers: [#("content-type", "application/json"), #("x-request-id", "r-1")],
    body: <<"{\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}":utf8>>,
    chunks: [
      Chunk(1000, <<"{\"usage\":{\"prompt_":utf8>>),
      Chunk(1500, <<"tokens\":7,\"completion_tokens\":2}}":utf8>>),
    ],
    timing: Timing(Some(900), Some(1000), Some(1500)),
  )
}

fn sample_exchange() {
  Exchange(
    seq: 3,
    endpoint: "target",
    step: 15,
    label: "q03/probed",
    request: sample_request(),
    started_us: 123_456,
    result: Ok(sample_response()),
  )
}

pub fn header_round_trips_test() {
  let header =
    Header("0.1.0", "2026-11-10T04:00:00Z", 42, [
      #("reference", 56),
      #("target", 40),
    ])
  assert codec.decode_line(codec.encode_header(header))
    == Ok(HeaderLine(header))
}

pub fn header_names_format_and_version_test() {
  let line = codec.encode_header(Header("0.1.0", "t", 1, []))
  assert string.contains(line, "\"format\":\"receipt-trace\"")
  assert string.contains(line, "\"version\":1")
}

pub fn exchange_round_trips_with_chunk_boundaries_test() {
  let exchange = sample_exchange()
  assert codec.decode_line(codec.encode_exchange(exchange))
    == Ok(ExchangeLine(exchange))
}

pub fn exchange_is_a_single_line_test() {
  assert !string.contains(codec.encode_exchange(sample_exchange()), "\n")
}

pub fn usage_is_extracted_for_inspection_test() {
  let line = codec.encode_exchange(sample_exchange())
  assert string.contains(
    line,
    "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"cached_tokens\":null,\"reasoning_tokens\":null}",
  )
}

pub fn anthropic_usage_is_extracted_too_test() {
  let response =
    Response(
      ..sample_response(),
      body: <<"{\"usage\":{\"input_tokens\":9,\"output_tokens\":4}}":utf8>>,
      chunks: [],
    )
  let line =
    codec.encode_exchange(Exchange(..sample_exchange(), result: Ok(response)))
  assert string.contains(line, "\"prompt_tokens\":9,\"completion_tokens\":4")
}

pub fn body_without_usage_has_null_usage_test() {
  let response = Response(..sample_response(), body: <<"{}":utf8>>, chunks: [])
  let line =
    codec.encode_exchange(Exchange(..sample_exchange(), result: Ok(response)))
  assert string.contains(line, "\"usage\":null")
}

pub fn transport_error_round_trips_test() {
  let timed_out = Exchange(..sample_exchange(), result: Error(Timeout))
  assert codec.decode_line(codec.encode_exchange(timed_out))
    == Ok(ExchangeLine(timed_out))
  let refused =
    Exchange(..sample_exchange(), result: Error(Connect("econnrefused")))
  assert codec.decode_line(codec.encode_exchange(refused))
    == Ok(ExchangeLine(refused))
}

pub fn event_stream_gets_an_sse_list_test() {
  let response =
    Response(
      status: 200,
      headers: [#("content-type", "text/event-stream; charset=utf-8")],
      body: <<"data: a\n\ndata: [DONE]\n\n":utf8>>,
      chunks: [
        Chunk(10, <<"data: a\n\n":utf8>>),
        Chunk(20, <<"data: [DONE]\n\n":utf8>>),
      ],
      timing: Timing(Some(5), Some(10), Some(20)),
    )
  let line =
    codec.encode_exchange(Exchange(..sample_exchange(), result: Ok(response)))
  assert string.contains(
    line,
    "\"sse\":[{\"at_us\":10,\"event\":\"\",\"data\":\"a\"},{\"at_us\":20,\"event\":\"\",\"data\":\"[DONE]\"}]",
  )
}

pub fn non_stream_has_null_sse_test() {
  assert string.contains(
    codec.encode_exchange(sample_exchange()),
    "\"sse\":null",
  )
}

pub fn binary_bodies_survive_test() {
  let response =
    Response(..sample_response(), body: <<0, 255, 128, 10>>, chunks: [
      Chunk(1, <<0, 255>>),
      Chunk(2, <<128, 10>>),
    ])
  let exchange = Exchange(..sample_exchange(), result: Ok(response))
  assert codec.decode_line(codec.encode_exchange(exchange))
    == Ok(ExchangeLine(exchange))
}

pub fn garbage_is_not_json_test() {
  assert codec.decode_line("not json") == Error(NotJson)
}

pub fn unknown_format_or_version_is_refused_test() {
  assert codec.decode_line(
      "{\"type\":\"header\",\"format\":\"receipt-trace\",\"version\":2,\"seed\":1}",
    )
    == Error(UnknownFormat("receipt-trace", 2))
  assert codec.decode_line(
      "{\"type\":\"header\",\"format\":\"other\",\"version\":1,\"seed\":1}",
    )
    == Error(UnknownFormat("other", 1))
}

pub fn unknown_line_type_is_a_bad_line_test() {
  let assert Error(BadLine(_)) = codec.decode_line("{\"type\":\"mystery\"}")
  let assert Error(BadLine(_)) = codec.decode_line("{}")
}

pub fn chunk_sizes_must_match_the_body_test() {
  let line =
    "{\"type\":\"exchange\",\"seq\":0,\"endpoint\":\"target\",\"request\":{\"method\":\"GET\",\"url\":\"http://x\",\"headers\":[],\"body\":\"\"},\"response\":{\"status\":200,\"headers\":[],\"body_b64\":\"YWJj\",\"chunks\":[{\"at_us\":1,\"bytes\":2}]},\"timing\":{\"started_us\":0}}"
  let assert Error(BadLine(detail)) = codec.decode_line(line)
  assert string.contains(detail, "chunk sizes")
}

pub fn exchange_needs_a_response_or_an_error_test() {
  let line =
    "{\"type\":\"exchange\",\"seq\":0,\"endpoint\":\"target\",\"request\":{\"method\":\"GET\",\"url\":\"http://x\",\"headers\":[],\"body\":\"\"},\"response\":null,\"error\":null}"
  let assert Error(BadLine(_)) = codec.decode_line(line)
}

pub fn arbitrary_bodies_and_labels_round_trip_test() {
  use #(body, label, seq) <- qcheck.given(qcheck.tuple3(
    qcheck.byte_aligned_bit_array(),
    qcheck.string(),
    qcheck.small_non_negative_int(),
  ))
  let response =
    Response(
      status: 200,
      headers: [],
      body: body,
      chunks: [Chunk(5, body)],
      timing: Timing(None, Some(5), Some(5)),
    )
  let exchange =
    Exchange(
      seq: seq,
      endpoint: "target",
      step: 1,
      label: label,
      request: Request(Get, "http://x/" <> label, [], label, 1000),
      started_us: 0,
      result: Ok(response),
    )
  assert codec.decode_line(codec.encode_exchange(exchange))
    == Ok(ExchangeLine(exchange))
}
