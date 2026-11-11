//// Builders for test contexts.

import gleam/option.{None}
import receipt/api/types.{OpenAi}
import receipt/client
import receipt/config
import receipt/ctx.{type Ctx, Ctx}
import receipt/endpoint.{type Endpoint, Endpoint}
import receipt/secret

pub const key = "sk-test-0123456789abcdefghijklmnopqrstuv"

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
