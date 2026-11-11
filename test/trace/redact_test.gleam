import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleam/string
import receipt/http/types.{Chunk, Post, Request, Response, Timing}
import receipt/secret
import receipt/trace/codec.{Exchange}
import receipt/trace/redact

const key = "sk-live-abcdefghijklmnopqrstuvwxyz012345"

fn secrets() {
  [secret.from_string(key)]
}

fn exchange_with(body: BitArray, chunks) {
  Exchange(
    seq: 0,
    endpoint: "target",
    step: 9,
    label: "x",
    request: Request(
      Post,
      "https://relay.example/v1/x?key=" <> key,
      [#("authorization", "Bearer " <> key), #("x-trace", key)],
      "{\"k\":\"" <> key <> "\"}",
      1000,
    ),
    started_us: 0,
    result: Ok(Response(
      status: 401,
      headers: [#("www-authenticate", "key " <> key)],
      body: body,
      chunks: chunks,
      timing: Timing(None, None, None),
    )),
  )
}

pub fn no_part_of_the_encoded_line_contains_the_key_test() {
  let body = bit_array.from_string("{\"error\":\"bad key " <> key <> "\"}")
  let line =
    exchange_with(body, [Chunk(1, body)])
    |> redact.exchange(secrets())
    |> codec.encode_exchange
  assert !string.contains(line, key)
  assert !string.contains(line, "abcdefgh")
}

pub fn auth_headers_become_a_placeholder_test() {
  let redacted = redact.exchange(exchange_with(<<>>, []), secrets())
  assert types.header(redacted.request.headers, "authorization")
    == Ok("[redacted]")
}

pub fn other_headers_get_the_stand_in_test() {
  let redacted = redact.exchange(exchange_with(<<>>, []), secrets())
  assert types.header(redacted.request.headers, "x-trace")
    == Ok(secret.stand_in(string.length(key)))
}

pub fn body_length_and_chunk_sizes_are_preserved_test() {
  let body = bit_array.from_string("prefix " <> key <> " suffix")
  let assert Ok(first) = bit_array.slice(body, 0, 20)
  let assert Ok(second) =
    bit_array.slice(body, 20, bit_array.byte_size(body) - 20)
  let redacted =
    redact.exchange(
      exchange_with(body, [Chunk(1, first), Chunk(2, second)]),
      secrets(),
    )
  let assert Ok(response) = redacted.result
  assert bit_array.byte_size(response.body) == bit_array.byte_size(body)
  assert list.map(response.chunks, fn(c) { bit_array.byte_size(c.data) })
    == [20, bit_array.byte_size(body) - 20]
  let joined =
    list.fold(response.chunks, <<>>, fn(acc, c) { <<acc:bits, c.data:bits>> })
  assert joined == response.body
  let assert Ok(text) = bit_array.to_string(response.body)
  assert !string.contains(text, "abcdefgh")
}

pub fn redacted_exchange_still_round_trips_test() {
  let body = bit_array.from_string("echo " <> key)
  let redacted =
    redact.exchange(exchange_with(body, [Chunk(1, body)]), secrets())
  assert codec.decode_line(codec.encode_exchange(redacted))
    == Ok(codec.ExchangeLine(redacted))
}

pub fn binary_body_is_left_untouched_test() {
  let redacted =
    redact.exchange(
      exchange_with(<<255, 0, 1>>, [Chunk(1, <<255, 0, 1>>)]),
      secrets(),
    )
  let assert Ok(response) = redacted.result
  assert response.body == <<255, 0, 1>>
}

pub fn every_configured_key_is_redacted_test() {
  let other = "gsk_ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210"
  assert redact.text(key <> " " <> other, [
      secret.from_string(key),
      secret.from_string(other),
    ])
    |> string.contains("ZYXWVUTS")
    == False
}
