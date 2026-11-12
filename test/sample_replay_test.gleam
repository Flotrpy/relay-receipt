//// Replays the committed synthetic trace and checks that it reproduces
//// the committed sample report. Runs in CI as the replay test.

import gleam/list
import gleam/option.{Some}
import gleam/regexp
import gleam/string
import receipt/app
import receipt/config.{Config}
import receipt/report/markdown
import receipt/steps
import receipt/verdict.{Anomaly, HighRisk}
import simplifile
import tools/make_sample

fn without_durations(text: String) -> String {
  let assert Ok(pattern) = regexp.from_string("Duration: [0-9]+ ms")
  regexp.replace(pattern, text, "Duration: - ms")
}

fn replayed() {
  let cfg =
    Config(..make_sample.sample_config(), replay: Some(make_sample.trace_path))
  let assert Ok(session) = app.open(cfg, fn(_) { Nil })
  app.run(session, cfg, steps.connect(), steps.all())
}

pub fn the_sample_trace_replays_to_the_committed_report_test() {
  let assert Ok(committed) = simplifile.read(make_sample.report_path)
  assert without_durations(markdown.render(replayed()))
    == without_durations(committed)
}

pub fn the_sample_shows_the_faults_it_was_built_with_test() {
  let report = replayed()
  assert report.rating.risk == HighRisk
  [4, 5, 8, 17]
  |> list.each(fn(id) {
    let assert Ok(result) = list.find(report.steps, fn(r) { r.id == id })
    assert result.verdict == Anomaly
  })
}

pub fn the_sample_trace_contains_no_real_key_or_host_test() {
  let assert Ok(text) = simplifile.read(make_sample.trace_path)
  assert !string.contains(text, "sk-test-Qm7vX2pL9")
  assert !string.contains(text, "groq.com")
  assert !string.contains(text, "openai.com")
}
