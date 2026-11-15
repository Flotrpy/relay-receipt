//// Time sources.
////
//// Durations and arrival times use Erlang's monotonic clock, which never
//// jumps when the system clock is adjusted. The system clock is used only
//// for the human-readable timestamp of a report or trace.

import gleam/erlang/atom.{type Atom}
import gleam/time/calendar
import gleam/time/timestamp

@external(erlang, "erlang", "monotonic_time")
fn erlang_monotonic_time(unit: Atom) -> Int

/// Monotonic time in microseconds. Only differences are meaningful.
pub fn monotonic_us() -> Int {
  erlang_monotonic_time(atom.create("microsecond"))
}

/// Microseconds elapsed since an earlier `monotonic_us` reading.
pub fn elapsed_us(since start: Int) -> Int {
  monotonic_us() - start
}

/// The current UTC time as an RFC 3339 string with second precision.
pub fn utc_now_rfc3339() -> String {
  let #(seconds, _nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  timestamp.from_unix_seconds(seconds)
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

/// Whole milliseconds in a microsecond duration, rounded down.
pub fn us_to_ms(microseconds: Int) -> Int {
  microseconds / 1000
}
