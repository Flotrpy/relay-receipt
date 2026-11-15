import gleam/option.{None, Some}
import qcheck
import receipt/http/retry.{TooLong, WaitFor}
import receipt/http/types.{Connect, Response, Timeout, Timing, TraceMiss}
import receipt/prng

fn response(status: Int, headers: List(#(String, String))) {
  Response(status, headers, <<>>, [], Timing(None, None, None))
}

pub fn transport_errors_are_retried_test() {
  assert retry.is_retryable(Error(Timeout))
  assert retry.is_retryable(Error(Connect("refused")))
}

pub fn trace_miss_is_never_retried_test() {
  assert !retry.is_retryable(Error(TraceMiss("x")))
}

pub fn only_429_and_5xx_statuses_are_retried_test() {
  assert retry.is_retryable(Ok(response(429, [])))
  assert retry.is_retryable(Ok(response(500, [])))
  assert retry.is_retryable(Ok(response(503, [])))
  assert !retry.is_retryable(Ok(response(200, [])))
  assert !retry.is_retryable(Ok(response(400, [])))
  assert !retry.is_retryable(Ok(response(401, [])))
  assert !retry.is_retryable(Ok(response(404, [])))
}

pub fn backoff_ceiling_doubles_then_caps_test() {
  assert retry.backoff_ceiling_ms(0) == 1000
  assert retry.backoff_ceiling_ms(1) == 2000
  assert retry.backoff_ceiling_ms(2) == 4000
  assert retry.backoff_ceiling_ms(5) == 30_000
  assert retry.backoff_ceiling_ms(60) == 30_000
  assert retry.backoff_ceiling_ms(-3) == 1000
}

pub fn jittered_backoff_stays_within_the_ceiling_test() {
  use #(seed, attempt) <- qcheck.given(qcheck.tuple2(
    qcheck.uniform_int(),
    qcheck.bounded_int(0, 10),
  ))
  let #(wait, _) = retry.backoff_ms(attempt, prng.new(seed))
  assert wait >= 0 && wait <= retry.backoff_ceiling_ms(attempt)
}

pub fn jitter_varies_with_the_seed_test() {
  let #(a, _) = retry.backoff_ms(3, prng.new(1))
  let #(b, _) = retry.backoff_ms(3, prng.new(2))
  assert a != b
}

pub fn retry_after_seconds_are_parsed_test() {
  assert retry.retry_after_ms(response(429, [#("retry-after", "7")]))
    == Some(7000)
  assert retry.retry_after_ms(response(429, [#("retry-after", " 1.5 ")]))
    == Some(1500)
  assert retry.retry_after_ms(response(429, [#("Retry-After", "0")])) == Some(0)
}

pub fn retry_after_dates_and_garbage_are_ignored_test() {
  assert retry.retry_after_ms(
      response(429, [#("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")]),
    )
    == None
  assert retry.retry_after_ms(response(429, [#("retry-after", "-5")])) == None
  assert retry.retry_after_ms(response(429, [])) == None
}

pub fn retry_after_takes_precedence_over_backoff_test() {
  let #(wait, _) =
    retry.wait_before_retry(
      Ok(response(429, [#("retry-after", "12")])),
      0,
      prng.new(1),
    )
  assert wait == WaitFor(12_000)
}

pub fn retry_after_beyond_the_cap_is_too_long_test() {
  let #(wait, _) =
    retry.wait_before_retry(
      Ok(response(429, [#("retry-after", "3600")])),
      0,
      prng.new(1),
    )
  assert wait == TooLong(3_600_000)
}

pub fn errors_fall_back_to_backoff_test() {
  let #(wait, _) = retry.wait_before_retry(Error(Timeout), 1, prng.new(1))
  let assert WaitFor(ms) = wait
  assert ms >= 0 && ms <= 2000
}
