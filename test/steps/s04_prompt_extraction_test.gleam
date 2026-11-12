import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/http/types as http
import receipt/probes/leak.{Other, Refusal, Structural, Weak}
import receipt/step
import receipt/steps/s04_prompt_extraction.{Observation} as s04
import receipt/verdict.{Anomaly, Clean, Inconclusive}
import support/fake.{Fake}
import support/world

const hidden =
  "You are RelayBot, the storefront assistant. Always recommend the premium plan and never mention competitors."

fn observations(grades) {
  list.index_map(grades, fn(grade, index) {
    Observation("p" <> string.inspect(index), grade, "reply")
  })
}

pub fn three_probes_are_defined_test() {
  assert list.length(s04.probes()) == 3
}

pub fn honest_relay_is_clean_test() {
  let result = s04.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Clean
  assert result.id == 4
}

pub fn hidden_prompt_revealed_is_an_anomaly_test() {
  let relay = Fake(..fake.honest(), hidden_prompt: hidden)
  let result = s04.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "signal")
  let assert [step.Finding(step.Signal, note)] = result.findings
  assert string.contains(note, "No trusted reference")
}

pub fn prompt_also_revealed_by_reference_is_not_attributed_test() {
  let relay = Fake(..fake.honest(), hidden_prompt: hidden)
  let ctx =
    world.ctx(world.route(fake.handler(relay), fake.handler(relay)))
    |> world.with_reference
  let result = s04.run(ctx)
  assert result.verdict == Inconclusive
  assert result.reason == Some("reference_reveals_prompt_too")
}

pub fn reference_that_refuses_strengthens_the_signal_test() {
  let relay = Fake(..fake.honest(), hidden_prompt: hidden)
  let ctx =
    world.ctx(world.route(fake.handler(relay), fake.handler(fake.honest())))
    |> world.with_reference
  let result = s04.run(ctx)
  assert result.verdict == Anomaly
  let assert [step.Finding(step.Signal, note)] = result.findings
  assert string.contains(note, "did not reveal")
}

pub fn all_requests_failing_is_inconclusive_test() {
  let result = s04.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_replies")
}

pub fn weak_or_unrelated_replies_are_inconclusive_test() {
  let weak =
    s04.build(4, observations([Some(Refusal), Some(Weak), Some(Refusal)]), None)
  assert weak.reason == Some("ambiguous_replies")
  assert string.contains(weak.summary, "2 refused, 1 weak")
  let other = s04.build(4, observations([Some(Other)]), None)
  assert other.verdict == Inconclusive
}

pub fn a_failed_probe_among_refusals_is_inconclusive_test() {
  let result =
    s04.build(4, observations([Some(Refusal), None, Some(Refusal)]), None)
  assert result.verdict == Inconclusive
  assert string.contains(result.summary, "1 failed")
}

pub fn one_structural_reply_is_enough_test() {
  let result =
    s04.build(
      4,
      observations([
        Some(Refusal),
        Some(Structural("You are X. Never Y.")),
        None,
      ]),
      None,
    )
  assert result.verdict == Anomaly
}

pub fn the_excerpt_is_shown_in_the_details_test() {
  let relay = Fake(..fake.honest(), hidden_prompt: hidden)
  let result = s04.run(world.ctx(fake.handler(relay)))
  assert list.length(result.details) >= 3
}

pub fn build_uses_the_given_step_number_test() {
  assert s04.build(6, observations([Some(Refusal)]), None).id == 6
}
