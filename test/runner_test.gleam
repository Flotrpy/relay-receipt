import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/api/types.{Anthropic, OpenAi}
import receipt/config.{Config, EndpointSpec}
import receipt/ctx.{type Ctx}
import receipt/http/types as http
import receipt/runner
import receipt/step
import receipt/verdict.{
  Clean, Inconclusive, Informational, NotApplicable, ProfileGated, Run, Skipped,
}
import support/script
import support/world

fn base_config() {
  config.new("http://target.test", "test-model")
}

fn quiet_ctx() -> Ctx {
  world.ctx(fn(_, _) { Error(http.Timeout) })
}

fn connected(_ctx: Ctx) {
  #(step.ran(2, Informational, "ok"), Some(OpenAi))
}

fn status_of(results: List(step.StepResult), id: Int) {
  let assert Ok(result) = list.find(results, fn(r) { r.id == id })
  #(result.status, result.reason)
}

pub fn web3_step_is_never_applicable_test() {
  let assert Some(result) = runner.gate(base_config(), 11, True)
  assert result.status == NotApplicable
  assert result.reason == Some("dropped_step")
}

pub fn upstream_map_is_profile_gated_in_general_test() {
  let with_endpoints =
    Config(..base_config(), endpoints: [EndpointSpec("b", "u", "m", "K")])
  let assert Some(result) = runner.gate(with_endpoints, 16, True)
  assert result.status == ProfileGated
  assert runner.gate(Config(..with_endpoints, profile: config.Full), 16, True)
    == None
}

pub fn upstream_map_needs_a_second_endpoint_test() {
  let assert Some(result) =
    runner.gate(Config(..base_config(), profile: config.Full), 16, True)
  assert result.status == NotApplicable
  assert result.reason == Some("fewer_than_two_endpoints")
}

pub fn identity_test_needs_a_reference_test() {
  let assert Some(result) = runner.gate(base_config(), 17, True)
  assert result.reason == Some("no_reference")
  let with_reference =
    Config(
      ..base_config(),
      reference: Some(EndpointSpec("reference", "u", "m", "K")),
    )
  assert runner.gate(with_reference, 17, True) == None
}

pub fn skip_and_only_mark_steps_skipped_test() {
  let assert Some(skipped) =
    runner.gate(Config(..base_config(), skip: [7]), 7, True)
  assert #(skipped.status, skipped.reason) == #(Skipped, Some("user_skipped"))
  let assert Some(unselected) =
    runner.gate(Config(..base_config(), only: [15]), 3, True)
  assert unselected.reason == Some("not_selected")
  assert runner.gate(Config(..base_config(), only: [15]), 15, True) == None
}

pub fn every_gated_result_is_inconclusive_test() {
  [11, 16, 17]
  |> list.each(fn(id) {
    let assert Some(result) = runner.gate(base_config(), id, True)
    assert result.verdict == Inconclusive
  })
}

pub fn run_all_returns_all_seventeen_steps_in_order_test() {
  let results =
    runner.run_all(quiet_ctx(), base_config(), Some(connected), [
      #(3, fn(_) { step.ran(3, Clean, "ok") }),
    ])
  assert list.map(results, fn(r) { r.id })
    == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
  assert status_of(results, 3) == #(Run, None)
  assert status_of(results, 4) == #(NotApplicable, Some("not_implemented"))
}

pub fn a_crashing_step_becomes_inconclusive_and_the_run_continues_test() {
  let results =
    runner.run_all(quiet_ctx(), base_config(), Some(connected), [
      #(3, fn(_) { panic as "boom" }),
      #(4, fn(_) { step.ran(4, Clean, "still ran") }),
    ])
  let assert Ok(crashed) = list.find(results, fn(r) { r.id == 3 })
  assert crashed.crashed
  assert crashed.verdict == Inconclusive
  assert string.contains(crashed.summary, "boom")
  assert status_of(results, 4) == #(Run, None)
}

pub fn no_connectivity_skips_chat_steps_but_not_recon_test() {
  let results =
    runner.run_all(
      quiet_ctx(),
      base_config(),
      Some(fn(_) {
        #(step.inconclusive(2, "no_format", "nothing answers"), None)
      }),
      [
        #(1, fn(_) { step.ran(1, Informational, "dns ok") }),
        #(3, fn(_) { step.ran(3, Clean, "should not run") }),
        #(12, fn(_) { step.ran(12, Informational, "fingerprint") }),
      ],
    )
  assert status_of(results, 1) == #(Run, None)
  assert status_of(results, 3) == #(Skipped, Some("no_connectivity"))
  assert status_of(results, 12) == #(Run, None)
}

pub fn detected_format_reaches_later_steps_test() {
  let results =
    runner.run_all(
      quiet_ctx(),
      base_config(),
      Some(fn(_) { #(step.ran(2, Informational, "ok"), Some(Anthropic)) }),
      [
        #(3, fn(ctx: Ctx) {
          case ctx.target.format {
            Anthropic -> step.ran(3, Clean, "saw anthropic")
            OpenAi -> step.ran(3, Inconclusive, "saw openai")
          }
        }),
      ],
    )
  let assert Ok(third) = list.find(results, fn(r) { r.id == 3 })
  assert third.summary == "saw anthropic"
}

pub fn request_counts_and_duration_are_filled_in_test() {
  let scripted = script.start([script.ok("{}"), script.ok("{}")])
  let ctx = world.ctx(script.handler(scripted))
  let results =
    runner.run_all(ctx, base_config(), Some(connected), [
      #(3, fn(ctx: Ctx) {
        let request =
          http.Request(http.Get, "http://target.test/x", [], "", 1000)
        let _ = ctx.send(ctx, ctx.target, 3, "a", request)
        let _ = ctx.send(ctx, ctx.target, 3, "b", request)
        step.ran(3, Clean, "two requests")
      }),
    ])
  let assert Ok(third) = list.find(results, fn(r) { r.id == 3 })
  assert third.requests_sent == 2
  assert third.requests_failed == 0
  assert third.duration_ms >= 0
}

pub fn progress_is_reported_for_each_step_test() {
  let results = runner.run_all(quiet_ctx(), base_config(), None, [])
  assert status_of(results, 2) == #(NotApplicable, Some("not_implemented"))
}
