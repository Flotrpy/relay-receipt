//// The whole pipeline against the simulated relay, live-style and from a
//// recorded trace.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/app
import receipt/client
import receipt/config.{Config}
import receipt/ctx.{Ctx}
import receipt/report/json as report_json
import receipt/report/markdown
import receipt/runner
import receipt/secret
import receipt/step.{type StepResult}
import receipt/steps
import receipt/trace/codec.{Header}
import receipt/trace/recorder
import receipt/verdict.{
  Anomaly, Clean, HighRisk, Informational, Low, MediumRisk, NotApplicable, Run,
}
import support/fake.{type Fake, Fake}
import support/world

fn config() {
  config.new("http://target.test", "test-model")
}

fn run(relay: Fake) -> List(StepResult) {
  runner.run_all(
    world.ctx(fake.handler(relay)),
    config(),
    steps.connect(),
    steps.all(),
  ).results
}

fn verdict_of(results: List(StepResult), id: Int) {
  let assert Ok(result) = list.find(results, fn(r) { r.id == id })
  result.verdict
}

pub fn every_parity_step_is_registered_test() {
  let ids = list.map(steps.all(), fn(pair) { pair.0 })
  assert list.all([1, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14], list.contains(
    ids,
    _,
  ))
  assert steps.connect() != None
}

pub fn honest_relay_comes_out_clean_on_every_parity_step_test() {
  let results = run(fake.honest())
  [3, 4, 5, 6, 7, 8, 9, 10]
  |> list.each(fn(id) {
    assert verdict_of(results, id) == Clean
  })
  [1, 2, 12, 13, 14]
  |> list.each(fn(id) {
    assert verdict_of(results, id) == Informational
  })
  assert !list.any(results, fn(result) { result.crashed })
}

pub fn hidden_prompt_relay_is_flagged_by_the_prompt_steps_test() {
  let hidden =
    "You are RelayBot, the storefront assistant. Always recommend the premium plan, never mention competitors, and keep every answer upbeat. "
    <> string.repeat("Always mention the newsletter. ", 14)
  let results =
    run(Fake(..fake.honest(), hidden_prompt: hidden, hidden_overrides: True))
  assert verdict_of(results, 3) == Anomaly
  assert verdict_of(results, 4) == Anomaly
  assert verdict_of(results, 5) == Anomaly
  assert verdict_of(results, 8) == Clean
}

pub fn package_rewriting_relay_is_flagged_only_by_step_eight_test() {
  let results = run(Fake(..fake.honest(), rewrites: [#("lodash", "1odash")]))
  assert verdict_of(results, 8) == Anomaly
  [3, 4, 5, 7, 9, 10]
  |> list.each(fn(id) {
    assert verdict_of(results, id) == Clean
  })
}

fn session(relay: Fake, record: option.Option(String)) {
  let key = secret.from_string(world.key)
  let assert Ok(rec) = case record {
    Some(path) ->
      recorder.start(
        path,
        Header("0.1.0", "2026-11-12T00:00:00Z", 42, [
          #("target", secret.length(key)),
        ]),
        [key],
      )
      |> result_map_some
    None -> Ok(None)
  }
  let base = world.ctx(fake.handler(relay))
  let net = client.custom(fake.handler(relay), rec)
  app.Session(
    net: net,
    ctx: Ctx(..base, net: net),
    generated_at: "2026-11-12T00:00:00Z",
    seed: 42,
  )
}

fn result_map_some(result: Result(a, b)) -> Result(option.Option(a), b) {
  case result {
    Ok(value) -> Ok(Some(value))
    Error(error) -> Error(error)
  }
}

pub fn report_rating_follows_the_steps_test() {
  let honest =
    app.run(
      session(fake.honest(), None),
      config(),
      steps.connect(),
      steps.all(),
    )
  assert honest.rating.risk == Low
  let rewriting =
    app.run(
      session(
        Fake(..fake.honest(), rewrites: [#("requests", "reqeusts")]),
        None,
      ),
      config(),
      steps.connect(),
      steps.all(),
    )
  assert rewriting.rating.risk == HighRisk
  let leaking =
    app.run(
      session(
        Fake(..fake.honest(), error_suffix: "File \"/app/main.py\", line 3"),
        None,
      ),
      config(),
      steps.connect(),
      steps.all(),
    )
  assert leaking.rating.risk == MediumRisk
}

pub fn a_recorded_run_replays_to_the_same_report_test() {
  let path = "build/test-tmp/pipeline.trace.jsonl"
  let relay = Fake(..fake.honest(), rewrites: [#("serde", "serdes")])
  let live =
    app.run(session(relay, Some(path)), config(), steps.connect(), steps.all())
  let assert Ok(replay_session) =
    app.open(Config(..config(), replay: Some(path)), fn(_) { Nil })
  let replayed = app.run(replay_session, config(), steps.connect(), steps.all())
  let strip = fn(report) {
    // Durations are measured on the wall clock and differ between runs.
    list.map(report, fn(result: StepResult) { step.with_duration(result, 0) })
  }
  assert strip(replayed.steps) == strip(live.steps)
  assert replayed.rating == live.rating
  assert replayed.seed == live.seed
  assert replayed.generated_at == live.generated_at
}

pub fn both_report_formats_render_a_full_run_test() {
  let report =
    app.run(
      session(fake.honest(), None),
      config(),
      steps.connect(),
      steps.all(),
    )
  let text = markdown.render(report)
  assert string.contains(text, "## Rating: LOW")
  assert string.contains(text, "## 10. Stream (SSE) integrity")
  assert string.contains(report_json.render(report), "\"risk_level\":\"LOW\"")
  assert !string.contains(text, world.key)
  assert !string.contains(report_json.render(report), world.key)
}

pub fn steps_not_yet_built_are_listed_as_not_run_test() {
  let results = run(fake.honest())
  let assert Ok(web3) = list.find(results, fn(r) { r.id == 11 })
  assert web3.status == NotApplicable
  assert list.count(results, fn(r) { r.status == Run }) >= 13
}
