//// Builders for test contexts.

import gleam/option.{None, Some}
import receipt/api/types.{OpenAi}
import receipt/client
import receipt/config
import receipt/ctx.{type Ctx, Ctx}
import receipt/endpoint.{type Endpoint, Endpoint}
import receipt/secret

pub const key = "sk-test-Qm7vX2pL9sKd4RtW8yHn3JcF6bZa1EuG"

pub fn endpoint(name: String) -> Endpoint {
  Endpoint(
    name: name,
    base_url: "http://" <> name <> ".test",
    model: "test-model",
    key: secret.from_string(key),
    format: OpenAi,
  )
}

/// A context whose target is served by a handler function.
pub fn ctx(handler: client.Handler) -> Ctx {
  Ctx(
    net: client.custom(handler, None),
    target: endpoint("target"),
    reference: None,
    endpoints: [],
    profile: config.General,
    seed: 42,
    latency_probes: 10,
    context_window: None,
    map_preset: config.Coarse,
    progress: fn(_) { Nil },
  )
}

/// The same context with another base URL for the target.
pub fn with_target_url(ctx: Ctx, base_url: String) -> Ctx {
  Ctx(..ctx, target: Endpoint(..ctx.target, base_url: base_url))
}

/// A context with a trusted reference. The handler receives the endpoint
/// name, so one function can play both sides.
pub fn with_reference(ctx: Ctx) -> Ctx {
  Ctx(..ctx, reference: Some(endpoint("reference")))
}

/// Route requests by endpoint name: `target` to one handler, everything
/// else to another.
pub fn route(
  target: client.Handler,
  reference: client.Handler,
) -> client.Handler {
  fn(name, request) {
    case name {
      "target" -> target(name, request)
      _ -> reference(name, request)
    }
  }
}
