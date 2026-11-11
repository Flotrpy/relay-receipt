import envoy
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/api/types.{OpenAi}
import receipt/app.{ReplayFailure, Setup}
import receipt/config.{Config, EndpointSpec}
import receipt/secret
import receipt/step
import receipt/trace/codec.{type Header, Header}
import receipt/verdict.{Anomaly, Clean, HighRisk, Informational, MediumRisk}
import simplifile

fn config() {
  Config(
    ..config.new("http://target.test", "m"),
    target: EndpointSpec(
      "target",
      "http://target.test",
      "m",
      "RECEIPT_APP_TEST_KEY",
    ),
  )
}

fn write_trace(name: String, header: Header) -> String {
  let _ = simplifile.create_directory_all("build/test-tmp")
  let path = "build/test-tmp/" <> name
  let assert Ok(Nil) =
    simplifile.write(path, codec.encode_header(header) <> "\n")
  path
}

pub fn missing_key_is_a_setup_failure_naming_the_variable_test() {
  envoy.unset("RECEIPT_APP_TEST_KEY")
  let assert Error(Setup(message)) = app.resolve_keys(config(), None)
  assert string.contains(message, "RECEIPT_APP_TEST_KEY")
  assert string.contains(message, "endpoint target")
  assert app.failure_exit_code(Setup(message)) == 1
}

pub fn keys_are_resolved_for_every_endpoint_test() {
  envoy.set("RECEIPT_APP_TEST_KEY", "sk-aaaaaaaaaaaaaaaaaaaa")
  envoy.set("RECEIPT_APP_TEST_REF", "sk-bbbbbbbbbbbbbbbbbbbbbbbb")
  let with_reference =
    Config(
      ..config(),
      reference: Some(EndpointSpec(
        "reference",
        "u",
        "m",
        "RECEIPT_APP_TEST_REF",
      )),
    )
  let assert Ok(keys) = app.resolve_keys(with_reference, None)
  assert list.map(keys, fn(pair) { #(pair.0, secret.length(pair.1)) })
    == [#("target", 23), #("reference", 27)]
  envoy.unset("RECEIPT_APP_TEST_KEY")
  envoy.unset("RECEIPT_APP_TEST_REF")
}

pub fn replay_uses_stand_in_keys_and_needs_no_environment_test() {
  envoy.unset("RECEIPT_APP_TEST_KEY")
  let header = Header("0.1.0", "2026-01-01T00:00:00Z", 9, [#("target", 30)])
  let assert Ok([#("target", key)]) = app.resolve_keys(config(), Some(header))
  assert secret.expose(key) == secret.stand_in(30)
}

pub fn replay_session_takes_seed_and_time_from_the_trace_test() {
  let header = Header("0.1.0", "2026-01-01T00:00:00Z", 1234, [#("target", 30)])
  let path = write_trace("app_replay.trace.jsonl", header)
  let assert Ok(session) =
    app.open(Config(..config(), replay: Some(path), seed: Some(5)), fn(_) {
      Nil
    })
  assert session.seed == 1234
  assert session.generated_at == "2026-01-01T00:00:00Z"
  assert session.ctx.seed == 1234
}

pub fn unreadable_trace_is_a_replay_failure_test() {
  let assert Error(ReplayFailure(message)) =
    app.open(Config(..config(), replay: Some("build/no/such.jsonl")), fn(_) {
      Nil
    })
  assert string.contains(message, "cannot read trace file")
  assert app.failure_exit_code(ReplayFailure(message)) == 2
}

fn finished_report(steps) {
  let header = Header("0.1.0", "2026-01-01T00:00:00Z", 7, [])
  let path = write_trace("app_run.trace.jsonl", header)
  let cfg = Config(..config(), replay: Some(path))
  let assert Ok(session) = app.open(cfg, fn(_) { Nil })
  app.run(
    session,
    cfg,
    Some(fn(_) { #(step.ran(2, Informational, "ok"), Some(OpenAi)) }),
    steps,
  )
}

pub fn run_assembles_a_complete_report_test() {
  let report = finished_report([#(3, fn(_) { step.ran(3, Clean, "ok") })])
  assert list.length(report.steps) == 17
  assert report.seed == 7
  assert report.generated_at == "2026-01-01T00:00:00Z"
  assert report.target.api_format == Some("openai")
  assert report.profile == "general"
  assert report.rating.risk == verdict.Low
  assert report.limits != []
}

pub fn render_follows_the_requested_format_test() {
  let report = finished_report([])
  assert string.starts_with(
    app.render(report, config.Markdown),
    "# Receipt audit report",
  )
  assert string.starts_with(
    app.render(report, config.Json),
    "{\"schema_version\":1",
  )
  assert string.ends_with(app.render(report, config.Json), "}\n")
}

pub fn exit_code_is_zero_unless_fail_on_is_reached_test() {
  let low = finished_report([#(3, fn(_) { step.ran(3, Clean, "x") })])
  let medium = finished_report([#(3, fn(_) { step.ran(3, Anomaly, "x") })])
  let high = finished_report([#(8, fn(_) { step.ran(8, Anomaly, "x") })])
  assert app.exit_code(high, None) == 0
  assert app.exit_code(low, Some(MediumRisk)) == 0
  assert app.exit_code(medium, Some(MediumRisk)) == 3
  assert app.exit_code(medium, Some(HighRisk)) == 0
  assert app.exit_code(high, Some(HighRisk)) == 3
  assert app.exit_code(high, Some(MediumRisk)) == 3
}

pub fn recording_writes_a_header_with_key_lengths_only_test() {
  envoy.set("RECEIPT_APP_TEST_KEY", "sk-cccccccccccccccccccccccc")
  let _ = simplifile.create_directory_all("build/test-tmp")
  let path = "build/test-tmp/app_record.trace.jsonl"
  let assert Ok(_session) =
    app.open(Config(..config(), record: Some(path), seed: Some(11)), fn(_) {
      Nil
    })
  let assert Ok(text) = simplifile.read(path)
  assert string.contains(text, "\"key_lengths\":{\"target\":27}")
  assert string.contains(text, "\"seed\":11")
  assert !string.contains(text, "cccccccc")
  envoy.unset("RECEIPT_APP_TEST_KEY")
}
