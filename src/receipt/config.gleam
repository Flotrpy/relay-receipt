//// The settings of one audit run.

import gleam/option.{type Option, None}
import receipt/api/types.{type ApiFormat}
import receipt/thresholds
import receipt/verdict.{type Risk}

pub type Profile {
  General
  Full
}

pub type ReportFormat {
  Markdown
  Json
}

/// Resolution preset of Step 16. See `docs/steps/16-upstream-map.md`.
pub type MapPreset {
  Paper
  Coarse
}

/// An endpoint as the user describes it. The key is named, never given.
pub type EndpointSpec {
  EndpointSpec(name: String, base_url: String, model: String, key_env: String)
}

pub type Config {
  Config(
    target: EndpointSpec,
    reference: Option(EndpointSpec),
    /// Extra endpoints for Step 16.
    endpoints: List(EndpointSpec),
    profile: Profile,
    format: ReportFormat,
    output: Option(String),
    record: Option(String),
    replay: Option(String),
    seed: Option(Int),
    rpm: Int,
    /// Steps the user turned off.
    skip: List(Int),
    /// When not empty, only these steps run.
    only: List(Int),
    latency_probes: Int,
    /// The claimed model's context window in tokens, if the user gave it.
    context_window: Option(Int),
    map_preset: MapPreset,
    /// Force an API format instead of detecting it in Step 2.
    api_format: Option(ApiFormat),
    fail_on: Option(Risk),
  )
}

pub const default_key_env = "RECEIPT_API_KEY"

pub const default_reference_key_env = "RECEIPT_REFERENCE_KEY"

/// A configuration with every default, for a target endpoint.
pub fn new(base_url: String, model: String) -> Config {
  Config(
    target: EndpointSpec("target", base_url, model, default_key_env),
    reference: None,
    endpoints: [],
    profile: General,
    format: Markdown,
    output: None,
    record: None,
    replay: None,
    seed: None,
    rpm: thresholds.default_rpm,
    skip: [],
    only: [],
    latency_probes: thresholds.latency_probes,
    context_window: None,
    map_preset: Coarse,
    api_format: None,
    fail_on: None,
  )
}

pub fn profile_to_string(profile: Profile) -> String {
  case profile {
    General -> "general"
    Full -> "full"
  }
}

pub fn profile_from_string(text: String) -> Result(Profile, Nil) {
  case text {
    "general" -> Ok(General)
    "full" -> Ok(Full)
    _ -> Error(Nil)
  }
}

pub fn map_preset_to_string(preset: MapPreset) -> String {
  case preset {
    Paper -> "paper"
    Coarse -> "coarse"
  }
}

pub fn map_preset_from_string(text: String) -> Result(MapPreset, Nil) {
  case text {
    "paper" -> Ok(Paper)
    "coarse" -> Ok(Coarse)
    _ -> Error(Nil)
  }
}
