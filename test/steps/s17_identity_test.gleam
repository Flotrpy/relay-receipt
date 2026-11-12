import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/config
import receipt/ctx.{type Ctx, Ctx}
import receipt/http/types as http
import receipt/identity/sequential.{BatchResult}
import receipt/prng
import receipt/step
import receipt/steps/s17_identity.{Run} as s17
import receipt/verdict.{Anomaly, Clean, Inconclusive, NotApplicable}
import support/fake.{type Fake, Fake}
import support/world

fn ctx_with(target: Fake, reference: Fake) -> Ctx {
  world.ctx(world.route(fake.handler(target), fake.handler(reference)))
  |> world.with_reference
}

pub fn without_a_reference_the_step_does_not_apply_test() {
  let result = s17.run(world.ctx(fake.handler(fake.honest())))
  assert result.status == NotApplicable
  assert result.reason == Some("no_reference")
}

pub fn the_same_model_on_both_sides_is_same_test() {
  let result = s17.run(ctx_with(fake.honest(), fake.honest()))
  assert result.verdict == Clean
  assert string.starts_with(result.summary, "same:")
  assert string.contains(result.summary, "2 batch(es)")
  let assert Some(rate) = result.error_rate
  assert rate.kind == "miss"
  assert string.contains(rate.basis, "the paper's figures")
}

pub fn a_different_model_is_different_and_stops_early_test() {
  let other = Fake(..fake.honest(), persona: 1)
  let result =
    s17.run(Ctx(..ctx_with(other, fake.honest()), profile: config.Full))
  assert result.verdict == Anomaly
  assert string.starts_with(result.summary, "different:")
  // Up to five batches were allowed; one was enough.
  assert string.contains(result.summary, "1 batch(es)")
  let assert Some(rate) = result.error_rate
  assert rate.kind == "false_positive"
  assert rate.bound == 0.05
  assert string.contains(rate.basis, "anytime-valid")
}

pub fn different_states_that_the_cause_is_unknown_test() {
  let other = Fake(..fake.honest(), persona: 1)
  let result = s17.run(ctx_with(other, fake.honest()))
  let assert [step.Finding(step.Signal, text)] = result.findings
  assert string.contains(text, "does not say why")
  assert string.contains(text, "Step 3")
}

pub fn unreachable_reference_is_insufficient_data_test() {
  let ctx =
    world.ctx(
      world.route(fake.handler(fake.honest()), fn(_, _) { Error(http.Timeout) }),
    )
    |> world.with_reference
  let result = s17.run(ctx)
  assert result.verdict == Inconclusive
  assert result.reason == Some("insufficient_data")
}

pub fn an_endpoint_without_tools_can_still_be_judged_on_text_test() {
  let no_tools = Fake(..fake.honest(), supports_tools: False)
  // Both sides lack tools: every tool sample is "_no_call" on both.
  let same = s17.run(ctx_with(no_tools, no_tools))
  assert same.verdict == Clean
  // The target answers in another vocabulary: text alone decides.
  let other = Fake(..no_tools, persona: 1)
  let different =
    s17.run(Ctx(..ctx_with(other, no_tools), profile: config.Full))
  assert different.verdict == Anomaly
}

pub fn a_tool_less_target_against_a_tool_using_reference_differs_test() {
  let no_tools = Fake(..fake.honest(), supports_tools: False)
  let result = s17.run(ctx_with(no_tools, fake.honest()))
  assert result.verdict == Anomaly
}

pub fn the_per_template_table_appears_only_for_different_test() {
  let same = s17.run(ctx_with(fake.honest(), fake.honest()))
  assert list.length(same.details) == 2
  let different =
    s17.run(ctx_with(Fake(..fake.honest(), persona: 1), fake.honest()))
  assert list.length(different.details) == 4
}

pub fn build_reports_insufficient_data_with_valid_batch_counts_test() {
  let invalid = BatchResult(False, None, 1.0)
  let progress =
    sequential.start()
    |> sequential.add(invalid, BatchResult(True, Some(0.5), 0.72))
  let result = s17.build(Run(progress, [], 2), prng.new(1))
  assert result.verdict == Inconclusive
  let assert [step.Finding(step.Note, note)] = result.findings
  assert string.contains(note, "tool choice 0, rank uniformity 1")
}

pub fn results_are_reproducible_for_a_seed_test() {
  let first = s17.run(ctx_with(fake.honest(), fake.honest()))
  let second = s17.run(ctx_with(fake.honest(), fake.honest()))
  assert first.data == second.data
}
