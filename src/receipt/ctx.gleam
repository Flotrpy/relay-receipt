//// What a step is given to work with.

import gleam/option.{type Option}
import receipt/api/chat.{type ChatError}
import receipt/api/types.{type ChatParams, type Completion}
import receipt/client.{type Net}
import receipt/config.{type MapPreset, type Profile}
import receipt/endpoint.{type Endpoint}
import receipt/http/types.{type Request, type Response, type TransportError} as http
import receipt/prng.{type Prng}
import receipt/thresholds

pub type Ctx {
  Ctx(
    net: Net,
    target: Endpoint,
    reference: Option(Endpoint),
    /// Extra endpoints for Step 16.
    endpoints: List(Endpoint),
    profile: Profile,
    seed: Int,
    latency_probes: Int,
    context_window: Option(Int),
    map_preset: MapPreset,
    /// Progress output for the person watching the run.
    progress: fn(String) -> Nil,
  )
}

/// The random stream of a step. Each step has its own, derived from the
/// run seed, so results do not depend on which other steps ran.
pub fn prng(ctx: Ctx, step: Int) -> Prng {
  prng.fork(prng.new(ctx.seed), step)
}

/// Send a raw request with retries.
pub fn send(
  ctx: Ctx,
  endpoint: Endpoint,
  step: Int,
  label: String,
  request: Request,
) -> Result(Response, TransportError) {
  client.send(ctx.net, endpoint.name, step, label, request)
}

/// Send a chat request with retries and interpret the answer.
pub fn chat(
  ctx: Ctx,
  endpoint: Endpoint,
  step: Int,
  label: String,
  params: ChatParams,
) -> Result(Completion, ChatError) {
  chat_within(ctx, endpoint, step, label, params, thresholds.request_timeout_ms)
}

/// As `chat`, with an explicit timeout.
pub fn chat_within(
  ctx: Ctx,
  endpoint: Endpoint,
  step: Int,
  label: String,
  params: ChatParams,
  timeout_ms: Int,
) -> Result(Completion, ChatError) {
  let request = chat.build(endpoint, params, timeout_ms)
  chat.interpret(endpoint, send(ctx, endpoint, step, label, request))
}

/// Whether the endpoint has been rate limiting so persistently that the
/// step should stop and report inconclusive.
pub fn rate_limited_out(ctx: Ctx, endpoint: Endpoint) -> Bool {
  client.rate_limit_exhausted(ctx.net, endpoint.name)
}
