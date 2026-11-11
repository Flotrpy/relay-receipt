//// Retry policy: which outcomes are retried and how long to wait.
////
//// Pure functions only; the loop that sleeps lives in `receipt/client`.

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/http/types.{type Response, type TransportError, TraceMiss}
import receipt/prng.{type Prng}
import receipt/thresholds

/// Whether an outcome is worth another attempt: transport failures, HTTP
/// 429 and HTTP 5xx. A trace miss is never retried.
pub fn is_retryable(result: Result(Response, TransportError)) -> Bool {
  case result {
    Error(TraceMiss(_)) -> False
    Error(_) -> True
    Ok(response) -> response.status == 429 || response.status >= 500
  }
}

/// The largest wait before retry number `attempt` (0 for the first retry):
/// base times two to the attempt, capped.
pub fn backoff_ceiling_ms(attempt: Int) -> Int {
  let factor = int.bitwise_shift_left(1, int.clamp(attempt, 0, 20))
  int.min(thresholds.backoff_base_ms * factor, thresholds.backoff_cap_ms)
}

/// Full jitter: a wait drawn uniformly between zero and the ceiling.
pub fn backoff_ms(attempt: Int, prng: Prng) -> #(Int, Prng) {
  let #(unit, prng) = prng.float(prng)
  #(float.truncate(unit *. int.to_float(backoff_ceiling_ms(attempt))), prng)
}

/// The wait a `Retry-After` header asks for, in milliseconds. Only the
/// delay-in-seconds form is understood; dates are ignored.
pub fn retry_after_ms(response: Response) -> Option(Int) {
  case types.header(response.headers, "retry-after") {
    Error(Nil) -> None
    Ok(value) -> {
      let value = string.trim(value)
      case int.parse(value), float.parse(value) {
        Ok(seconds), _ if seconds >= 0 -> Some(seconds * 1000)
        _, Ok(seconds) if seconds >=. 0.0 ->
          Some(float.truncate(seconds *. 1000.0))
        _, _ -> None
      }
    }
  }
}

pub type Wait {
  /// Sleep this long, then retry.
  WaitFor(ms: Int)
  /// The endpoint asked for a longer wait than Receipt accepts.
  TooLong(ms: Int)
}

/// How long to wait before the next attempt: the endpoint's `Retry-After`
/// if it sent one, otherwise jittered backoff.
pub fn wait_before_retry(
  result: Result(Response, TransportError),
  attempt: Int,
  prng: Prng,
) -> #(Wait, Prng) {
  let asked = case result {
    Ok(response) -> retry_after_ms(response)
    Error(_) -> None
  }
  case asked {
    Some(ms) if ms > thresholds.retry_after_cap_ms -> #(TooLong(ms), prng)
    Some(ms) -> #(WaitFor(ms), prng)
    None -> {
      let #(ms, prng) = backoff_ms(attempt, prng)
      #(WaitFor(ms), prng)
    }
  }
}
