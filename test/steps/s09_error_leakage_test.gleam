import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/http/types as http
import receipt/secret
import receipt/steps/s09_error_leakage.{Hit, Observation} as s09
import receipt/verdict.{Anomaly, Clean, Critical, High, Inconclusive, Medium}
import support/fake.{Fake}
import support/world

fn key() {
  secret.from_string(world.key)
}

fn kinds(text: String) -> List(String) {
  s09.scan(text, key(), "relay.example") |> list.map(fn(hit) { hit.kind })
}

fn run(relay: fake.Fake) {
  s09.run(world.ctx(fake.handler(relay)))
}

pub fn clean_error_text_has_no_hits_test() {
  assert kinds("{\"error\":{\"message\":\"The model `x` does not exist.\"}}")
    == []
  assert kinds(
      "Invalid API key. Find yours at https://platform.openai.com/account/api-keys",
    )
    == []
}

pub fn full_key_is_critical_and_never_quoted_test() {
  let assert [Hit(kind, severity, evidence)] =
    s09.scan("Incorrect key provided: " <> world.key, key(), "relay.example")
  assert kind == "full API key"
  assert severity == Critical
  assert !string.contains(evidence, string.slice(world.key, 8, 12))
}

pub fn twelve_key_characters_are_high_test() {
  let fragment = string.slice(world.key, 4, 12)
  let assert [Hit("partial API key", High, evidence)] =
    s09.scan("token ..." <> fragment, key(), "relay.example")
  assert string.contains(evidence, "12 of")
  let short = string.slice(world.key, 4, 11)
  assert kinds("token ..." <> short) == []
}

pub fn upstream_host_is_high_unless_it_is_the_audited_host_test() {
  assert kinds("POST https://api.openai.com/v1/chat/completions failed")
    == ["upstream provider host"]
  assert s09.scan("see https://api.groq.com/openai/v1", key(), "api.groq.com")
    == []
}

pub fn secret_variable_names_are_high_test() {
  assert kinds("KeyError: OPENAI_API_KEY is not set")
    == ["secret environment variable name"]
  assert kinds("missing UPSTREAM_TOKEN") == ["secret environment variable name"]
  assert kinds("the API KEY is wrong") == []
  assert kinds("MAX_TOKENS exceeded") == []
}

pub fn paths_and_traces_are_medium_test() {
  let hits =
    s09.scan(
      "Traceback (most recent call last):\n  File \"/app/proxy/server.py\", line 42, in handle",
      key(),
      "relay.example",
    )
  assert list.map(hits, fn(hit) { hit.severity }) == [Medium, Medium]
  assert kinds("at handler (/usr/src/app/index.js:10:5)")
    == ["filesystem path", "stack trace"]
  assert kinds("C:\\Users\\svc\\relay\\main.py") == ["filesystem path"]
  assert kinds("panic: runtime error") == ["stack trace"]
}

pub fn headers_are_scanned_too_test() {
  let response =
    http.Response(
      status: 500,
      headers: [#("x-debug-upstream", "https://api.anthropic.com/v1/messages")],
      body: <<"{}":utf8>>,
      chunks: [],
      timing: http.Timing(None, None, None),
    )
  let assert [Hit("upstream provider host", High, _)] =
    s09.scan_response(response, key(), "relay.example")
}

pub fn five_probes_are_sent_with_auth_test() {
  let probes = s09.probes(world.ctx(fake.handler(fake.honest())))
  assert list.map(probes, fn(probe) { probe.label })
    == [
      "malformed JSON", "unknown model", "wrong content type",
      "missing messages", "unknown path",
    ]
  assert list.all(probes, fn(probe) {
    http.header(probe.request.headers, "authorization") != Error(Nil)
  })
}

pub fn honest_relay_is_clean_test() {
  let result = run(fake.honest())
  assert result.verdict == Clean
  assert result.severity == None
}

pub fn echoed_key_is_a_critical_anomaly_test() {
  let result = run(Fake(..fake.honest(), error_suffix: "Bad credential {key}"))
  assert result.verdict == Anomaly
  assert result.severity == Some(Critical)
  assert string.contains(result.summary, "full API key")
}

pub fn partial_key_is_a_high_anomaly_test() {
  let result =
    run(Fake(..fake.honest(), error_suffix: "key {key16}*** rejected"))
  assert result.severity == Some(High)
}

pub fn stack_trace_is_a_medium_anomaly_test() {
  let result =
    run(
      Fake(
        ..fake.honest(),
        error_suffix: "Traceback (most recent call last): File \"/app/main.py\", line 7",
      ),
    )
  assert result.verdict == Anomaly
  assert result.severity == Some(Medium)
}

pub fn worst_severity_wins_test() {
  let result =
    s09.build([
      Observation("a", Some(400), [Hit("filesystem path", Medium, "/app/x")]),
      Observation("b", Some(500), [
        Hit("upstream provider host", High, "api.openai.com"),
      ]),
    ])
  assert result.severity == Some(High)
}

pub fn swallowed_errors_are_inconclusive_test() {
  let result = run(Fake(..fake.honest(), swallows_errors: True))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_error_surface")
}

pub fn transport_failures_are_inconclusive_test() {
  let result = s09.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
}

pub fn the_report_never_contains_the_key_test() {
  let result = run(Fake(..fake.honest(), error_suffix: "Bad credential {key}"))
  assert !string.contains(
    string.inspect(result),
    string.slice(world.key, 8, 16),
  )
}
