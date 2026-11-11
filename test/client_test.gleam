import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/client
import receipt/clock
import receipt/http/types.{Get, Request, Timeout, TraceMiss}
import receipt/trace/codec.{Header}
import receipt/trace/recorder
import receipt/trace/replayer
import simplifile
import support/script
import support/server

fn request(path: String) {
  Request(Get, "http://relay.test" <> path, [], "", 1000)
}

pub fn success_is_returned_after_one_attempt_test() {
  let scripted = script.start([script.ok("{}")])
  let net = client.custom(script.handler(scripted), None)
  let assert Ok(response) = client.send(net, "target", 2, "x", request("/a"))
  assert response.status == 200
  assert list.length(script.seen(scripted)) == 1
  assert client.stats(net, 2) == #(1, 0)
}

pub fn retryable_outcomes_are_retried_up_to_twice_test() {
  let scripted =
    script.start([
      Error(Timeout),
      script.reply(503, [], "busy"),
      script.ok("{\"ok\":true}"),
    ])
  let net = client.custom(script.handler(scripted), None)
  let assert Ok(response) = client.send(net, "target", 3, "x", request("/a"))
  assert response.status == 200
  assert list.length(script.seen(scripted)) == 3
  assert client.stats(net, 3) == #(3, 2)
}

pub fn retries_stop_after_the_limit_test() {
  let scripted =
    script.start([
      script.reply(500, [], "1"),
      script.reply(500, [], "2"),
      script.reply(500, [], "3"),
      script.ok("never reached"),
    ])
  let net = client.custom(script.handler(scripted), None)
  let assert Ok(response) = client.send(net, "target", 3, "x", request("/a"))
  assert response.status == 500
  assert list.length(script.seen(scripted)) == 3
}

pub fn client_errors_are_not_retried_test() {
  let scripted = script.start([script.reply(401, [], "no"), script.ok("x")])
  let net = client.custom(script.handler(scripted), None)
  let assert Ok(response) = client.send(net, "target", 3, "x", request("/a"))
  assert response.status == 401
  assert list.length(script.seen(scripted)) == 1
}

pub fn excessive_retry_after_stops_retrying_test() {
  let scripted =
    script.start([
      script.reply(429, [#("retry-after", "86400")], "daily limit"),
      script.ok("x"),
    ])
  let net = client.custom(script.handler(scripted), None)
  let assert Ok(response) = client.send(net, "target", 3, "x", request("/a"))
  assert response.status == 429
  assert list.length(script.seen(scripted)) == 1
}

pub fn attempt_never_retries_test() {
  let scripted = script.start([Error(Timeout), script.ok("x")])
  let net = client.custom(script.handler(scripted), None)
  assert client.attempt(net, "target", 3, "x", request("/a")) == Error(Timeout)
  assert list.length(script.seen(scripted)) == 1
}

pub fn three_rate_limited_sends_in_a_row_exhaust_the_endpoint_test() {
  let limited = script.reply(429, [#("retry-after", "86400")], "limit")
  let scripted = script.start([limited, limited, limited])
  let net = client.custom(script.handler(scripted), None)
  let _ = client.send(net, "target", 3, "x", request("/a"))
  let _ = client.send(net, "target", 3, "x", request("/a"))
  assert !client.rate_limit_exhausted(net, "target")
  let _ = client.send(net, "target", 3, "x", request("/a"))
  assert client.rate_limit_exhausted(net, "target")
  assert !client.rate_limit_exhausted(net, "reference")
}

pub fn a_success_resets_the_rate_limit_streak_test() {
  let limited = script.reply(429, [#("retry-after", "86400")], "limit")
  let scripted = script.start([limited, limited, script.ok("x"), limited])
  let net = client.custom(script.handler(scripted), None)
  let _ = client.send(net, "target", 3, "x", request("/a"))
  let _ = client.send(net, "target", 3, "x", request("/a"))
  let _ = client.send(net, "target", 3, "x", request("/a"))
  let _ = client.send(net, "target", 3, "x", request("/a"))
  assert !client.rate_limit_exhausted(net, "target")
}

pub fn stats_are_kept_per_step_test() {
  let scripted = script.start([script.ok("a"), script.ok("b"), script.ok("c")])
  let net = client.custom(script.handler(scripted), None)
  let _ = client.send(net, "target", 4, "x", request("/a"))
  let _ = client.send(net, "target", 4, "x", request("/b"))
  let _ = client.send(net, "target", 9, "x", request("/c"))
  assert client.stats(net, 4) == #(2, 0)
  assert client.stats(net, 9) == #(1, 0)
  assert client.stats(net, 1) == #(0, 0)
}

pub fn every_attempt_is_recorded_and_replayable_test() {
  let _ = simplifile.create_directory_all("build/test-tmp")
  let path = "build/test-tmp/client_record.trace.jsonl"
  let assert Ok(rec) = recorder.start(path, Header("0.1.0", "t", 1, []), [])
  let scripted = script.start([Error(Timeout), script.ok("{\"n\":1}")])
  let net = client.custom(script.handler(scripted), Some(rec))
  let assert Ok(first) = client.send(net, "target", 5, "probe", request("/a"))
  client.sync(net)
  let assert Ok(text) = simplifile.read(path)
  assert list.length(string.split(string.trim(text), "\n")) == 3

  let assert Ok(rep) = replayer.load(path)
  let replay_net = client.replay(rep)
  let assert Ok(second) =
    client.send(replay_net, "target", 5, "probe", request("/a"))
  assert second == first
  assert replayer.remaining(rep) == 0
}

pub fn replay_miss_is_returned_without_retry_test() {
  let assert Ok(rep) = replayer.start(Header("0.1.0", "t", 1, []), [])
  let net = client.replay(rep)
  let assert Error(TraceMiss(_)) =
    client.send(net, "target", 5, "probe", request("/missing"))
  assert client.stats(net, 5) == #(1, 0)
}

pub fn only_live_mode_is_live_test() {
  let assert Ok(rep) = replayer.start(Header("0.1.0", "t", 1, []), [])
  assert !client.is_live(client.replay(rep))
  assert !client.is_live(client.custom(fn(_, _) { Error(Timeout) }, None))
  assert client.is_live(client.live(20, None))
}

pub fn live_requests_are_paced_per_endpoint_test() {
  server.ensure_started()
  // 300 requests per minute is one every 200 ms.
  let net = client.live(300, None)
  let live_request = Request(Get, server.base_url() <> "/json", [], "", 2000)
  let start = clock.monotonic_us()
  let assert Ok(_) = client.attempt(net, "target", 2, "a", live_request)
  let assert Ok(_) = client.attempt(net, "target", 2, "b", live_request)
  let assert Ok(_) = client.attempt(net, "other", 2, "c", live_request)
  let elapsed_ms = clock.elapsed_us(since: start) / 1000
  assert elapsed_ms >= 190
  // The third request went to another endpoint, so it did not wait again.
  assert elapsed_ms < 390
}
