//// Wires a parsed configuration into a finished report.
////
//// Everything here is callable from tests; only `receipt.gleam` touches
//// the process exit code.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import receipt/api/types.{OpenAi}
import receipt/client.{type Net}
import receipt/clock
import receipt/config.{type Config, type EndpointSpec}
import receipt/ctx.{type Ctx, Ctx}
import receipt/endpoint.{type Endpoint, Endpoint}
import receipt/rating
import receipt/report/json as report_json
import receipt/report/markdown
import receipt/report/model.{type Report, EndpointInfo, Report}
import receipt/runner.{type ConnectFn, type StepFn}
import receipt/secret.{type Secret}
import receipt/trace/codec.{type Header, Header}
import receipt/trace/recorder
import receipt/trace/replayer
import receipt/verdict.{type Risk, HighRisk, Low, MediumRisk}
import receipt/version

pub type Failure {
  /// The audit could not start: bad key, unwritable trace. Exit code 1.
  Setup(message: String)
  /// A trace could not be loaded. Exit code 2.
  ReplayFailure(message: String)
}

/// Key length assumed for an endpoint a trace header does not mention.
const default_stand_in_length = 40

fn specs(config: Config) -> List(EndpointSpec) {
  list.flatten([
    [config.target],
    option.values([config.reference]),
    config.endpoints,
  ])
}

/// Resolve each endpoint's key: from the environment for a live run, the
/// stand-in key for a replay.
pub fn resolve_keys(
  config: Config,
  replay_header: Option(Header),
) -> Result(List(#(String, Secret)), Failure) {
  specs(config)
  |> list.try_map(fn(spec) {
    case replay_header {
      Some(header) -> {
        let length =
          list.key_find(header.key_lengths, spec.name)
          |> result.unwrap(default_stand_in_length)
        Ok(#(spec.name, secret.stand_in_secret(length)))
      }
      None ->
        secret.from_env(spec.key_env)
        |> result.map(fn(key) { #(spec.name, key) })
        |> result.map_error(fn(error) {
          Setup(
            "key for endpoint "
            <> spec.name
            <> ": "
            <> secret.describe_error(error),
          )
        })
    }
  })
}

fn to_endpoint(
  config: Config,
  spec: EndpointSpec,
  keys: List(#(String, Secret)),
) -> Endpoint {
  let key =
    list.key_find(keys, spec.name) |> result.unwrap(secret.from_string(""))
  Endpoint(
    name: spec.name,
    base_url: spec.base_url,
    model: spec.model,
    key: key,
    format: option.unwrap(config.api_format, OpenAi),
  )
}

/// A seed for runs that were not given one.
fn fresh_seed() -> Int {
  int.absolute_value(clock.monotonic_us()) % 2_147_483_647
}

/// Everything needed to run: the net, the context, and the report facts
/// that come from the run rather than from the steps.
pub type Session {
  Session(net: Net, ctx: Ctx, generated_at: String, seed: Int)
}

/// Open a session for a configuration: load or create the trace, resolve
/// keys, build the context.
pub fn open(
  config: Config,
  progress: fn(String) -> Nil,
) -> Result(Session, Failure) {
  use replay <- result.try(case config.replay {
    None -> Ok(None)
    Some(path) ->
      replayer.load(path) |> result.map(Some) |> result.map_error(ReplayFailure)
  })
  let header = option.map(replay, replayer.header)
  use keys <- result.try(resolve_keys(config, header))
  let seed = case header, config.seed {
    Some(header), _ -> header.seed
    None, Some(seed) -> seed
    None, None -> fresh_seed()
  }
  let generated_at = case header {
    Some(header) -> header.created_at
    None -> clock.utc_now_rfc3339()
  }
  use net <- result.try(case replay, config.record {
    Some(replay), _ -> Ok(client.replay(replay))
    None, None -> Ok(client.live(config.rpm, None))
    None, Some(path) -> {
      let trace_header =
        Header(
          tool_version: version.version,
          created_at: generated_at,
          seed: seed,
          key_lengths: list.map(keys, fn(pair) {
            #(pair.0, secret.length(pair.1))
          }),
        )
      recorder.start(path, trace_header, list.map(keys, fn(pair) { pair.1 }))
      |> result.map(fn(recorder) { client.live(config.rpm, Some(recorder)) })
      |> result.map_error(Setup)
    }
  })
  Ok(Session(
    net: net,
    ctx: Ctx(
      net: net,
      target: to_endpoint(config, config.target, keys),
      reference: option.map(config.reference, to_endpoint(config, _, keys)),
      endpoints: list.map(config.endpoints, to_endpoint(config, _, keys)),
      profile: config.profile,
      seed: seed,
      latency_probes: config.latency_probes,
      context_window: config.context_window,
      map_preset: config.map_preset,
      progress: progress,
    ),
    generated_at: generated_at,
    seed: seed,
  ))
}

/// Run the pipeline in an open session and assemble the report.
pub fn run(
  session: Session,
  config: Config,
  connect: Option(ConnectFn),
  steps: List(#(Int, StepFn)),
) -> Report {
  let finished = runner.run_all(session.ctx, config, connect, steps)
  client.sync(session.net)
  let results = finished.results
  let info = fn(spec: EndpointSpec, format: Option(String)) {
    EndpointInfo(spec.name, spec.base_url, spec.model, format)
  }
  let target_format = option.map(finished.api_format, types.format_to_string)
  Report(
    generated_at: session.generated_at,
    tool_version: version.version,
    profile: config.profile_to_string(config.profile),
    seed: session.seed,
    target: info(config.target, target_format),
    reference: option.map(config.reference, info(_, None)),
    endpoints: list.map(config.endpoints, info(_, None)),
    rating: rating.rate(results),
    steps: results,
    limits: model.limits_for(results),
  )
}

pub fn render(report: Report, format: config.ReportFormat) -> String {
  case format {
    config.Markdown -> markdown.render(report)
    config.Json -> report_json.render(report) <> "\n"
  }
}

fn risk_rank(risk: Risk) -> Int {
  case risk {
    Low -> 0
    MediumRisk -> 1
    HighRisk -> 2
  }
}

/// The process exit code for a finished audit. See `docs/REPORT_SCHEMA.md`.
pub fn exit_code(report: Report, fail_on: Option(Risk)) -> Int {
  case fail_on {
    Some(level) ->
      case risk_rank(report.rating.risk) >= risk_rank(level) {
        True -> 3
        False -> 0
      }
    None -> 0
  }
}

pub fn failure_exit_code(failure: Failure) -> Int {
  case failure {
    Setup(_) -> 1
    ReplayFailure(_) -> 2
  }
}

pub fn failure_message(failure: Failure) -> String {
  case failure {
    Setup(message) -> message
    ReplayFailure(message) -> "replay failed: " <> string.trim(message)
  }
}
