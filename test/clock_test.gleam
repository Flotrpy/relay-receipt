import gleam/erlang/process
import gleam/string
import receipt/clock

pub fn monotonic_clock_never_goes_backwards_test() {
  let first = clock.monotonic_us()
  let second = clock.monotonic_us()
  assert second >= first
}

pub fn elapsed_measures_a_sleep_test() {
  let start = clock.monotonic_us()
  process.sleep(20)
  let elapsed = clock.elapsed_us(since: start)
  assert elapsed >= 19_000
  assert elapsed < 2_000_000
}

pub fn utc_timestamp_is_rfc3339_with_z_suffix_test() {
  let now = clock.utc_now_rfc3339()
  assert string.length(now) == 20
  assert string.ends_with(now, "Z")
  assert string.slice(now, 4, 1) == "-"
  assert string.slice(now, 10, 1) == "T"
}

pub fn us_to_ms_rounds_down_test() {
  assert clock.us_to_ms(1999) == 1
  assert clock.us_to_ms(0) == 0
  assert clock.us_to_ms(2_500_000) == 2500
}
