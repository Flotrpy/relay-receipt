import gleam/list
import gleam/option.{Some}
import gleam/string
import receipt/http/types.{
  Chunk, Get, Post, Request, Response, Timeout, Timing, TraceMiss,
}
import receipt/secret
import receipt/trace/codec.{Exchange, Header}
import receipt/trace/recorder
import receipt/trace/replayer
import simplifile

const key = "sk-live-abcdefghijklmnopqrstuvwxyz012345"

fn header() {
  Header("0.1.0", "2026-11-10T00:00:00Z", 7, [#("target", 40)])
}

fn request(body: String) {
  Request(
    Post,
    "http://relay.test/v1/chat/completions",
    [#("authorization", "Bearer " <> key)],
    body,
    1000,
  )
}

fn response(text: String) {
  Response(
    status: 200,
    headers: [#("content-type", "application/json")],
    body: <<text:utf8>>,
    chunks: [Chunk(10, <<text:utf8>>)],
    timing: Timing(Some(5), Some(10), Some(10)),
  )
}

fn exchange(seq: Int, body: String, reply: String) {
  Exchange(
    seq,
    "target",
    3,
    "probe",
    request(body),
    seq * 100,
    Ok(response(reply)),
  )
}

fn temp_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test-tmp")
  "build/test-tmp/" <> name
}

pub fn recorded_file_starts_with_header_and_has_one_line_per_exchange_test() {
  let path = temp_path("record_basic.trace.jsonl")
  let assert Ok(rec) = recorder.start(path, header(), [secret.from_string(key)])
  recorder.write(rec, exchange(recorder.next_seq(rec), "a", "one"))
  recorder.write(rec, exchange(recorder.next_seq(rec), "b", "two"))
  assert recorder.sync(rec) == 2
  let assert Ok(text) = simplifile.read(path)
  let lines = string.split(string.trim(text), "\n")
  assert list.length(lines) == 3
  let assert [first, ..] = lines
  assert string.contains(first, "\"type\":\"header\"")
}

pub fn recorded_file_never_contains_the_key_test() {
  let path = temp_path("record_redacted.trace.jsonl")
  let assert Ok(rec) = recorder.start(path, header(), [secret.from_string(key)])
  recorder.write(rec, exchange(recorder.next_seq(rec), key, "echo " <> key))
  recorder.sync(rec)
  let assert Ok(text) = simplifile.read(path)
  assert !string.contains(text, key)
  assert !string.contains(text, "abcdefgh")
}

pub fn sequence_numbers_increase_from_zero_test() {
  let path = temp_path("record_seq.trace.jsonl")
  let assert Ok(rec) = recorder.start(path, header(), [])
  assert [
      recorder.next_seq(rec),
      recorder.next_seq(rec),
      recorder.next_seq(rec),
    ]
    == [0, 1, 2]
}

pub fn unwritable_path_is_an_error_test() {
  let assert Error(message) =
    recorder.start("build/no-such-dir/x/y.jsonl", header(), [])
  assert string.contains(message, "cannot write trace file")
}

pub fn replay_serves_recorded_responses_test() {
  let assert Ok(rep) =
    replayer.start(header(), [exchange(0, "a", "one"), exchange(1, "b", "two")])
  assert replayer.send(rep, "target", request("b")) == Ok(response("two"))
  assert replayer.send(rep, "target", request("a")) == Ok(response("one"))
  assert replayer.remaining(rep) == 0
}

pub fn identical_requests_are_served_in_recorded_order_test() {
  let assert Ok(rep) =
    replayer.start(header(), [
      exchange(2, "same", "third"),
      exchange(0, "same", "first"),
      exchange(1, "same", "second"),
    ])
  assert replayer.send(rep, "target", request("same")) == Ok(response("first"))
  assert replayer.send(rep, "target", request("same")) == Ok(response("second"))
  assert replayer.send(rep, "target", request("same")) == Ok(response("third"))
}

pub fn unmatched_request_is_a_trace_miss_test() {
  let assert Ok(rep) = replayer.start(header(), [exchange(0, "a", "one")])
  let assert Error(TraceMiss(detail)) =
    replayer.send(rep, "target", request("never recorded"))
  assert string.contains(detail, "relay.test")
}

pub fn exhausted_queue_is_a_trace_miss_test() {
  let assert Ok(rep) = replayer.start(header(), [exchange(0, "a", "one")])
  let assert Ok(_) = replayer.send(rep, "target", request("a"))
  let assert Error(TraceMiss(_)) = replayer.send(rep, "target", request("a"))
}

pub fn endpoint_name_is_part_of_the_match_test() {
  let assert Ok(rep) = replayer.start(header(), [exchange(0, "a", "one")])
  let assert Error(TraceMiss(_)) = replayer.send(rep, "reference", request("a"))
}

pub fn recorded_errors_are_replayed_as_errors_test() {
  let failed =
    Exchange(0, "target", 3, "probe", request("x"), 0, Error(Timeout))
  let assert Ok(rep) = replayer.start(header(), [failed])
  assert replayer.send(rep, "target", request("x")) == Error(Timeout)
}

pub fn record_then_replay_round_trip_through_a_file_test() {
  let path = temp_path("round_trip.trace.jsonl")
  let secret_key = secret.from_string(key)
  let assert Ok(rec) = recorder.start(path, header(), [secret_key])
  recorder.write(rec, exchange(recorder.next_seq(rec), "hello", "world"))
  recorder.sync(rec)
  let assert Ok(rep) = replayer.load(path)
  assert replayer.header(rep) == header()
  // The replayed request carries the stand-in key, as a replay run would.
  let stand_in = secret.stand_in(40)
  let replay_request =
    Request(..request("hello"), headers: [
      #("authorization", "Bearer " <> stand_in),
    ])
  assert replayer.send(rep, "target", replay_request) == Ok(response("world"))
}

pub fn parse_reports_the_failing_line_test() {
  let text = codec.encode_header(header()) <> "\n{\"type\":\"exchange\"}\n"
  let assert Error(message) = replayer.parse(text)
  assert string.starts_with(message, "line 2:")
}

pub fn parse_requires_a_leading_header_test() {
  let assert Error(message) =
    replayer.parse(codec.encode_exchange(exchange(0, "a", "b")) <> "\n")
  assert string.contains(message, "does not start with a header")
  assert replayer.parse("") == Error("trace is empty")
}

pub fn match_key_ignores_headers_test() {
  let a = Request(Get, "http://x/", [#("authorization", "one")], "", 1)
  let b = Request(Get, "http://x/", [#("authorization", "two")], "", 99)
  assert replayer.match_key("t", a) == replayer.match_key("t", b)
  assert replayer.match_key("t", a)
    != replayer.match_key("t", Request(..a, body: "x"))
}

pub fn observations_are_recorded_redacted_and_replayed_test() {
  let path = temp_path("observation.trace.jsonl")
  let assert Ok(rec) = recorder.start(path, header(), [secret.from_string(key)])
  recorder.observe(rec, 1, "dns:relay.test", "A 203.0.113.7")
  recorder.observe(rec, 1, "leaky", "saw " <> key)
  assert recorder.sync(rec) == 2
  let assert Ok(text) = simplifile.read(path)
  assert !string.contains(text, "abcdefgh")
  let assert Ok(rep) = replayer.load(path)
  assert replayer.observation(rep, 1, "dns:relay.test") == "A 203.0.113.7"
  assert replayer.observation(rep, 1, "tls:relay.test") == replayer.not_recorded
  assert replayer.observation(rep, 2, "dns:relay.test") == replayer.not_recorded
}

pub fn observation_line_round_trips_test() {
  let observation =
    codec.Observation(4, 1, "tls:host", "subject CN=host\nissuer X")
  assert codec.decode_line(codec.encode_observation(observation))
    == Ok(codec.ObservationLine(observation))
}
