//// Command-line parsing. Pure: it turns arguments into a `Command` or an
//// error message and performs no I/O.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import receipt/api/types as api
import receipt/config.{type Config, type EndpointSpec, Config, EndpointSpec}
import receipt/thresholds
import receipt/verdict

pub type Command {
  Audit(config: Config)
  Help
  Version
}

pub const usage =
  "receipt - local security auditor for AI API relays

Usage:
  receipt audit --url <BASE_URL> --model <MODEL> [options]
  receipt version
  receipt help

The API key is read from an environment variable (default RECEIPT_API_KEY).
There is no option that takes a key.

Target:
  --url <URL>               Base URL of the endpoint to audit
  --model <NAME>            Model name to request
  --key-env <VAR>           Variable holding the key (default RECEIPT_API_KEY)
  --api-format <F>          openai | anthropic (default: detected in Step 2)

Trusted reference (enables the reference method of Step 3, and Step 17):
  --reference-url <URL>
  --reference-model <NAME>
  --reference-key-env <VAR> (default RECEIPT_REFERENCE_KEY)

Extra endpoints for Step 16 (repeatable):
  --endpoint <NAME>=<URL>,<MODEL>,<KEY_VAR>
  --map-preset <P>          coarse | paper (default coarse)

Run:
  --profile <P>             general | full (default general)
  --skip <N,N,...>          Steps to turn off
  --only <N,N,...>          Run only these steps
  --seed <INT>              Seed for shuffles and permutation tests
  --rpm <INT>               Requests per minute per endpoint (default 20)
  --latency-probes <INT>    Probes in Step 13, 3 to 50 (default 10)
  --context-window <INT>    Claimed context window in tokens (Step 7)

Output:
  --format <F>              markdown | json (default markdown)
  --output <FILE>           Write the report to a file
  --record <FILE>           Record every exchange to a trace file
  --replay <FILE>           Run from a trace file, with no network
  --fail-on <LEVEL>         MEDIUM | HIGH: exit 3 at or above this rating

A report lists signals, anomalies and inconclusive results.
It is not a safety certificate.
"

/// Parse the arguments that follow the program name.
pub fn parse(arguments: List(String)) -> Result(Command, String) {
  case arguments {
    [] | ["help", ..] | ["--help", ..] | ["-h", ..] -> Ok(Help)
    ["version", ..] | ["--version", ..] -> Ok(Version)
    ["audit", ..rest] -> parse_audit(rest)
    [other, ..] -> Error("unknown command: " <> other)
  }
}

type Draft {
  Draft(
    url: Option(String),
    model: Option(String),
    key_env: String,
    reference_url: Option(String),
    reference_model: Option(String),
    reference_key_env: String,
    config: Config,
  )
}

fn parse_audit(arguments: List(String)) -> Result(Command, String) {
  let draft =
    Draft(
      url: None,
      model: None,
      key_env: config.default_key_env,
      reference_url: None,
      reference_model: None,
      reference_key_env: config.default_reference_key_env,
      config: config.new("", ""),
    )
  use draft <- result.try(parse_options(arguments, draft))
  use url <- result.try(option.to_result(draft.url, "--url is required"))
  use model <- result.try(option.to_result(draft.model, "--model is required"))
  use reference <- result.try(case draft.reference_url, draft.reference_model {
    Some(url), Some(model) ->
      Ok(Some(EndpointSpec("reference", url, model, draft.reference_key_env)))
    None, None -> Ok(None)
    _, _ ->
      Error("--reference-url and --reference-model must be given together")
  })
  let config =
    Config(
      ..draft.config,
      target: EndpointSpec("target", url, model, draft.key_env),
      reference: reference,
      endpoints: list.reverse(draft.config.endpoints),
    )
  use _ <- result.try(case config.record, config.replay {
    Some(_), Some(_) -> Error("--record and --replay cannot be used together")
    _, _ -> Ok(Nil)
  })
  Ok(Audit(config))
}

fn parse_options(
  arguments: List(String),
  draft: Draft,
) -> Result(Draft, String) {
  case arguments {
    [] -> Ok(draft)
    ["--key", ..] | ["--api-key", ..] | ["--reference-key", ..] ->
      Error(
        "keys are never passed as arguments; set an environment variable and name it with --key-env",
      )
    [flag] -> Error("missing value for " <> flag)
    [flag, value, ..rest] -> {
      use draft <- result.try(apply(draft, flag, value))
      parse_options(rest, draft)
    }
  }
}

fn apply(draft: Draft, flag: String, value: String) -> Result(Draft, String) {
  let config = draft.config
  let set = fn(config: Config) { Ok(Draft(..draft, config: config)) }
  case flag {
    "--url" -> Ok(Draft(..draft, url: Some(value)))
    "--model" -> Ok(Draft(..draft, model: Some(value)))
    "--key-env" -> Ok(Draft(..draft, key_env: value))
    "--reference-url" -> Ok(Draft(..draft, reference_url: Some(value)))
    "--reference-model" -> Ok(Draft(..draft, reference_model: Some(value)))
    "--reference-key-env" -> Ok(Draft(..draft, reference_key_env: value))
    "--endpoint" -> {
      use spec <- result.try(parse_endpoint(value))
      set(Config(..config, endpoints: [spec, ..config.endpoints]))
    }
    "--profile" ->
      config.profile_from_string(value)
      |> result.replace_error("--profile must be general or full")
      |> result.try(fn(profile) { set(Config(..config, profile: profile)) })
    "--format" ->
      case value {
        "markdown" | "md" -> set(Config(..config, format: config.Markdown))
        "json" -> set(Config(..config, format: config.Json))
        _ -> Error("--format must be markdown or json")
      }
    "--api-format" ->
      api.format_from_string(value)
      |> result.replace_error("--api-format must be openai or anthropic")
      |> result.try(fn(format) {
        set(Config(..config, api_format: Some(format)))
      })
    "--map-preset" ->
      config.map_preset_from_string(value)
      |> result.replace_error("--map-preset must be coarse or paper")
      |> result.try(fn(preset) { set(Config(..config, map_preset: preset)) })
    "--output" -> set(Config(..config, output: Some(value)))
    "--record" -> set(Config(..config, record: Some(value)))
    "--replay" -> set(Config(..config, replay: Some(value)))
    "--seed" -> {
      use seed <- result.try(integer(flag, value))
      set(Config(..config, seed: Some(seed)))
    }
    "--rpm" -> {
      use rpm <- result.try(integer(flag, value))
      case rpm >= 1 && rpm <= 6000 {
        True -> set(Config(..config, rpm: rpm))
        False -> Error("--rpm must be between 1 and 6000")
      }
    }
    "--latency-probes" -> {
      use count <- result.try(integer(flag, value))
      case
        count >= thresholds.latency_probes_min
        && count <= thresholds.latency_probes_max
      {
        True -> set(Config(..config, latency_probes: count))
        False -> Error("--latency-probes must be between 3 and 50")
      }
    }
    "--context-window" -> {
      use tokens <- result.try(integer(flag, value))
      case tokens > 0 {
        True -> set(Config(..config, context_window: Some(tokens)))
        False -> Error("--context-window must be positive")
      }
    }
    "--skip" -> {
      use steps <- result.try(step_list(flag, value))
      set(Config(..config, skip: steps))
    }
    "--only" -> {
      use steps <- result.try(step_list(flag, value))
      set(Config(..config, only: steps))
    }
    "--fail-on" ->
      case string.uppercase(value) {
        "MEDIUM" -> set(Config(..config, fail_on: Some(verdict.MediumRisk)))
        "HIGH" -> set(Config(..config, fail_on: Some(verdict.HighRisk)))
        _ -> Error("--fail-on must be MEDIUM or HIGH")
      }
    _ -> Error("unknown option: " <> flag)
  }
}

fn integer(flag: String, value: String) -> Result(Int, String) {
  int.parse(value)
  |> result.replace_error(flag <> " needs an integer, got: " <> value)
}

fn step_list(flag: String, value: String) -> Result(List(Int), String) {
  string.split(value, ",")
  |> list.try_map(fn(part) {
    case int.parse(string.trim(part)) {
      Ok(step) if step >= 1 && step <= 17 -> Ok(step)
      _ -> Error(flag <> " needs step numbers from 1 to 17, got: " <> part)
    }
  })
}

/// Parse `NAME=URL,MODEL,KEY_VAR`.
pub fn parse_endpoint(value: String) -> Result(EndpointSpec, String) {
  let problem =
    "--endpoint must look like NAME=URL,MODEL,KEY_VAR, got: " <> value
  case string.split_once(value, "=") {
    Error(Nil) -> Error(problem)
    Ok(#(name, rest)) ->
      case string.split(rest, ",") {
        [url, model, key_env] ->
          case name == "" || url == "" || model == "" || key_env == "" {
            True -> Error(problem)
            False ->
              case name == "target" || name == "reference" {
                True -> Error("endpoint name " <> name <> " is reserved")
                False -> Ok(EndpointSpec(name, url, model, key_env))
              }
          }
        _ -> Error(problem)
      }
  }
}
