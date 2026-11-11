//// The one place requests leave Receipt.
////
//// A `Net` is either live, replaying a trace, or driven by a function
//// (for tests). Whatever the mode, every attempt is paced, counted and,
//// when a recorder is attached, recorded; `send` adds the retry policy.
//// Waiting is real only in live mode.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import receipt/clock
import receipt/http/live
import receipt/http/retry.{TooLong, WaitFor}
import receipt/http/types.{type Request, type Response, type TransportError}
import receipt/prng
import receipt/thresholds
import receipt/trace/codec.{Exchange}
import receipt/trace/recorder.{type Recorder}
import receipt/trace/replayer.{type Replayer}

pub type Handler =
  fn(String, Request) -> Result(Response, TransportError)

type Mode {
  Live
  Replay(replayer: Replayer)
  Custom(handler: Handler)
}

pub opaque type Net {
  Net(
    mode: Mode,
    recorder: Option(Recorder),
    hub: Subject(Message),
    started_us: Int,
    interval_ms: Int,
  )
}

type Message {
  Reserve(endpoint: String, now_ms: Int, interval_ms: Int, reply: Subject(Int))
  Count(step: Int, failed: Bool)
  Final(endpoint: String, rate_limited: Bool)
  Stats(step: Int, reply: Subject(#(Int, Int)))
  Streak(endpoint: String, reply: Subject(Int))
}

type Hub {
  Hub(
    next_free_ms: Dict(String, Int),
    counts: Dict(Int, #(Int, Int)),
    streaks: Dict(String, Int),
  )
}

fn start_hub() -> Subject(Message) {
  let assert Ok(started) =
    actor.new(Hub(dict.new(), dict.new(), dict.new()))
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

fn handle(hub: Hub, message: Message) -> actor.Next(Hub, Message) {
  case message {
    Reserve(endpoint, now_ms, interval_ms, reply) -> {
      let free = dict.get(hub.next_free_ms, endpoint) |> result.unwrap(now_ms)
      let slot = int.max(free, now_ms)
      process.send(reply, slot - now_ms)
      actor.continue(
        Hub(
          ..hub,
          next_free_ms: dict.insert(
            hub.next_free_ms,
            endpoint,
            slot + interval_ms,
          ),
        ),
      )
    }
    Count(step, failed) -> {
      let #(sent, failures) =
        dict.get(hub.counts, step) |> result.unwrap(#(0, 0))
      let failures = case failed {
        True -> failures + 1
        False -> failures
      }
      actor.continue(
        Hub(..hub, counts: dict.insert(hub.counts, step, #(sent + 1, failures))),
      )
    }
    Final(endpoint, rate_limited) -> {
      let streak = case rate_limited {
        True -> { dict.get(hub.streaks, endpoint) |> result.unwrap(0) } + 1
        False -> 0
      }
      actor.continue(
        Hub(..hub, streaks: dict.insert(hub.streaks, endpoint, streak)),
      )
    }
    Stats(step, reply) -> {
      process.send(reply, dict.get(hub.counts, step) |> result.unwrap(#(0, 0)))
      actor.continue(hub)
    }
    Streak(endpoint, reply) -> {
      process.send(reply, dict.get(hub.streaks, endpoint) |> result.unwrap(0))
      actor.continue(hub)
    }
  }
}

fn interval_for(rpm: Int) -> Int {
  case rpm < 1 {
    True -> 0
    False -> 60_000 / rpm
  }
}

/// A net that talks to the network, at most `rpm` requests per minute per
/// endpoint.
pub fn live(rpm: Int, recorder: Option(Recorder)) -> Net {
  Net(Live, recorder, start_hub(), clock.monotonic_us(), interval_for(rpm))
}

/// A net that serves a recorded trace. Nothing waits.
pub fn replay(replayer: Replayer) -> Net {
  Net(Replay(replayer), None, start_hub(), clock.monotonic_us(), 0)
}

/// A net driven by a function. Nothing waits. An optional recorder lets
/// tests and the test bed produce trace fixtures from a simulated relay.
pub fn custom(handler: Handler, recorder: Option(Recorder)) -> Net {
  Net(Custom(handler), recorder, start_hub(), clock.monotonic_us(), 0)
}

pub fn is_live(net: Net) -> Bool {
  case net.mode {
    Live -> True
    Replay(_) | Custom(_) -> False
  }
}

/// Wait, in live mode only.
pub fn sleep(net: Net, ms: Int) -> Nil {
  case is_live(net) && ms > 0 {
    True -> process.sleep(ms)
    False -> Nil
  }
}

/// One attempt: pace, send, count, record.
pub fn attempt(
  net: Net,
  endpoint: String,
  step: Int,
  label: String,
  request: Request,
) -> Result(Response, TransportError) {
  let now_ms = clock.monotonic_us() / 1000
  let wait =
    process.call(net.hub, 5000, Reserve(endpoint, now_ms, net.interval_ms, _))
  sleep(net, wait)
  let seq = option.map(net.recorder, recorder.next_seq)
  let started_us = clock.monotonic_us() - net.started_us
  let result = case net.mode {
    Live -> live.send(request)
    Replay(replayer) -> replayer.send(replayer, endpoint, request)
    Custom(handler) -> handler(endpoint, request)
  }
  process.send(net.hub, Count(step, retry.is_retryable(result)))
  case net.recorder, seq {
    Some(recorder), Some(seq) ->
      recorder.write(
        recorder,
        Exchange(seq, endpoint, step, label, request, started_us, result),
      )
    _, _ -> Nil
  }
  result
}

/// Send with the retry policy of `docs/THRESHOLDS.md`. Each attempt is its
/// own recorded exchange.
pub fn send(
  net: Net,
  endpoint: String,
  step: Int,
  label: String,
  request: Request,
) -> Result(Response, TransportError) {
  let jitter = prng.new(clock.monotonic_us())
  let result = send_loop(net, endpoint, step, label, request, 0, jitter)
  let rate_limited = case result {
    Ok(response) -> response.status == 429
    Error(_) -> False
  }
  process.send(net.hub, Final(endpoint, rate_limited))
  result
}

fn send_loop(
  net: Net,
  endpoint: String,
  step: Int,
  label: String,
  request: Request,
  retries_done: Int,
  jitter: prng.Prng,
) -> Result(Response, TransportError) {
  let result = attempt(net, endpoint, step, label, request)
  case retry.is_retryable(result) && retries_done < thresholds.max_retries {
    False -> result
    True -> {
      let #(wait, jitter) =
        retry.wait_before_retry(result, retries_done, jitter)
      case wait {
        TooLong(_) -> result
        WaitFor(ms) -> {
          sleep(net, ms)
          send_loop(
            net,
            endpoint,
            step,
            label,
            request,
            retries_done + 1,
            jitter,
          )
        }
      }
    }
  }
}

/// Requests attempted and failed (transport error, 429 or 5xx) for a step.
pub fn stats(net: Net, step: Int) -> #(Int, Int) {
  process.call(net.hub, 5000, Stats(step, _))
}

/// Whether the endpoint has answered 429, after retries, to the last
/// `rate_limit_give_up` sends in a row. Steps stop and report
/// inconclusive when this becomes true.
pub fn rate_limit_exhausted(net: Net, endpoint: String) -> Bool {
  process.call(net.hub, 5000, Streak(endpoint, _))
  >= thresholds.rate_limit_give_up
}

/// Wait for the recorder, if any, to finish writing.
pub fn sync(net: Net) -> Nil {
  case net.recorder {
    Some(recorder) -> {
      recorder.sync(recorder)
      Nil
    }
    None -> Nil
  }
}
