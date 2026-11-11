import gleam/option.{None, Some}
import gleam/string
import receipt/api/types as api
import receipt/cli.{Audit, Help, Version}
import receipt/config.{EndpointSpec}
import receipt/verdict

fn audit(arguments: List(String)) {
  let assert Ok(Audit(config)) =
    cli.parse([
      "audit",
      "--url",
      "https://r.example",
      "--model",
      "m",
      ..arguments
    ])
  config
}

fn failure(arguments: List(String)) -> String {
  let assert Error(message) = cli.parse(arguments)
  message
}

pub fn no_arguments_or_help_shows_help_test() {
  assert cli.parse([]) == Ok(Help)
  assert cli.parse(["help"]) == Ok(Help)
  assert cli.parse(["--help"]) == Ok(Help)
  assert cli.parse(["version"]) == Ok(Version)
}

pub fn unknown_command_is_an_error_test() {
  assert failure(["frobnicate"]) == "unknown command: frobnicate"
}

pub fn minimal_audit_uses_defaults_test() {
  let config = audit([])
  assert config.target
    == EndpointSpec("target", "https://r.example", "m", "RECEIPT_API_KEY")
  assert config.reference == None
  assert config.profile == config.General
  assert config.format == config.Markdown
  assert config.rpm == 20
  assert config.latency_probes == 10
  assert config.map_preset == config.Coarse
  assert config.skip == []
  assert config.seed == None
}

pub fn url_and_model_are_required_test() {
  assert failure(["audit", "--model", "m"]) == "--url is required"
  assert failure(["audit", "--url", "u"]) == "--model is required"
}

pub fn there_is_no_way_to_pass_a_key_test() {
  let message =
    failure(["audit", "--url", "u", "--model", "m", "--key", "sk-x"])
  assert string.contains(message, "never passed as arguments")
  assert !string.contains(message, "sk-x")
  assert string.contains(
    failure(["audit", "--api-key", "sk-y"]),
    "never passed as arguments",
  )
}

pub fn key_env_names_the_variable_test() {
  assert audit(["--key-env", "MY_RELAY_KEY"]).target.key_env == "MY_RELAY_KEY"
}

pub fn reference_needs_both_url_and_model_test() {
  let config =
    audit(["--reference-url", "https://ref.example", "--reference-model", "m"])
  assert config.reference
    == Some(EndpointSpec(
      "reference",
      "https://ref.example",
      "m",
      "RECEIPT_REFERENCE_KEY",
    ))
  assert string.contains(
    failure(["audit", "--url", "u", "--model", "m", "--reference-url", "x"]),
    "must be given together",
  )
}

pub fn endpoints_are_collected_in_order_test() {
  let config =
    audit([
      "--endpoint", "a=https://a.example,m,KEY_A", "--endpoint",
      "b=https://b.example/v1,m,KEY_B",
    ])
  assert config.endpoints
    == [
      EndpointSpec("a", "https://a.example", "m", "KEY_A"),
      EndpointSpec("b", "https://b.example/v1", "m", "KEY_B"),
    ]
}

pub fn malformed_endpoint_is_rejected_test() {
  let assert Error(_) = cli.parse_endpoint("a=https://a.example,m")
  let assert Error(_) = cli.parse_endpoint("https://a.example,m,KEY")
  let assert Error(_) = cli.parse_endpoint("=u,m,K")
  let assert Error(message) = cli.parse_endpoint("target=u,m,K")
  assert string.contains(message, "reserved")
}

pub fn profile_format_and_presets_test() {
  let config =
    audit([
      "--profile", "full", "--format", "json", "--map-preset", "paper",
      "--api-format", "anthropic",
    ])
  assert config.profile == config.Full
  assert config.format == config.Json
  assert config.map_preset == config.Paper
  assert config.api_format == Some(api.Anthropic)
  assert string.contains(
    failure(["audit", "--profile", "web3"]),
    "general or full",
  )
}

pub fn numeric_options_are_validated_test() {
  let config =
    audit([
      "--seed", "42", "--rpm", "30", "--latency-probes", "5", "--context-window",
      "131072",
    ])
  assert config.seed == Some(42)
  assert config.rpm == 30
  assert config.latency_probes == 5
  assert config.context_window == Some(131_072)
  assert string.contains(failure(["audit", "--rpm", "0"]), "between 1 and 6000")
  assert string.contains(
    failure(["audit", "--latency-probes", "2"]),
    "between 3 and 50",
  )
  assert string.contains(
    failure(["audit", "--seed", "abc"]),
    "needs an integer",
  )
}

pub fn skip_and_only_take_step_lists_test() {
  let config = audit(["--skip", "7, 13", "--only", "15"])
  assert config.skip == [7, 13]
  assert config.only == [15]
  assert string.contains(failure(["audit", "--skip", "18"]), "from 1 to 17")
}

pub fn record_and_replay_are_exclusive_test() {
  assert audit(["--record", "t.jsonl"]).record == Some("t.jsonl")
  assert audit(["--replay", "t.jsonl"]).replay == Some("t.jsonl")
  assert string.contains(
    failure([
      "audit", "--url", "u", "--model", "m", "--record", "a", "--replay", "b",
    ]),
    "cannot be used together",
  )
}

pub fn fail_on_accepts_medium_or_high_test() {
  assert audit(["--fail-on", "high"]).fail_on == Some(verdict.HighRisk)
  assert audit(["--fail-on", "MEDIUM"]).fail_on == Some(verdict.MediumRisk)
  assert string.contains(
    failure(["audit", "--fail-on", "low"]),
    "MEDIUM or HIGH",
  )
}

pub fn unknown_option_and_missing_value_test() {
  assert failure(["audit", "--frob", "x"]) == "unknown option: --frob"
  assert failure(["audit", "--url"]) == "missing value for --url"
}

pub fn usage_states_the_stance_test() {
  assert string.contains(cli.usage, "not a safety certificate")
  assert string.contains(cli.usage, "no option that takes a key")
}
