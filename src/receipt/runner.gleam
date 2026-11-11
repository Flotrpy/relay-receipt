//// Runs the step pipeline.
////
//// The runner decides which steps run (profile, user choices, what the
//// run was given), isolates each step in its own process so that a crash
//// becomes an inconclusive result instead of ending the audit, and fills
//// in each result's duration and request counts.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/types.{type ApiFormat}
import receipt/catalog
import receipt/client
import receipt/clock
import receipt/config.{type Config, General}
import receipt/ctx.{type Ctx, Ctx}
import receipt/endpoint
import receipt/step.{type StepResult}
import receipt/verdict.{NotApplicable, ProfileGated, Skipped}

pub type StepFn =
  fn(Ctx) -> StepResult

/// Step 2 also reports which API format answered.
pub type ConnectFn =
  fn(Ctx) -> #(StepResult, Option(ApiFormat))

pub type Finished {
  Finished(
    results: List(StepResult),
    /// The target's API format: forced by the user or detected by Step 2.
    /// `None` when neither happened.
    api_format: Option(ApiFormat),
  )
}

/// Steps that need a working chat endpoint.
const needs_chat = [3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 15, 16, 17]

/// The reason a step does not run, if it does not.
pub fn gate(config: Config, id: Int, implemented: Bool) -> Option(StepResult) {
  let full_only = case catalog.find(id) {
    Ok(info) -> info.full_only
    Error(Nil) -> False
  }
  let selected = config.only == [] || list.contains(config.only, id)
  case id {
    11 -> Some(step.not_run(11, NotApplicable, "dropped_step"))
    _ if !selected -> Some(step.not_run(id, Skipped, "not_selected"))
    _ if !implemented -> Some(step.not_run(id, NotApplicable, "not_implemented"))
    _ ->
      case list.contains(config.skip, id) {
        True -> Some(step.not_run(id, Skipped, "user_skipped"))
        False ->
          case full_only && config.profile == General {
            True -> Some(step.not_run(id, ProfileGated, "full_profile_only"))
            False ->
              case id {
                17 if config.reference == None ->
                  Some(step.not_run(17, NotApplicable, "no_reference"))
                16 if config.endpoints == [] ->
                  Some(step.not_run(
                    16,
                    NotApplicable,
                    "fewer_than_two_endpoints",
                  ))
                _ -> None
              }
          }
      }
  }
}

/// Run one step in its own process. A crash becomes an inconclusive
/// result with the crash recorded.
pub fn run_isolated(
  ctx: Ctx,
  id: Int,
  run: fn(Ctx) -> a,
  on_crash: fn(StepResult) -> a,
) -> a {
  let reply = process.new_subject()
  let pid = process.spawn_unlinked(fn() { process.send(reply, run(ctx)) })
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, Error)
  case process.selector_receive_forever(selector) {
    Ok(value) -> {
      process.demonitor_process(monitor)
      value
    }
    Error(down) ->
      // The result may have been sent just before the process ended.
      case process.receive(reply, 0) {
        Ok(value) -> value
        Error(Nil) ->
          on_crash(step.crashed(id, string.slice(string.inspect(down), 0, 300)))
      }
  }
}

fn finish(
  ctx: Ctx,
  id: Int,
  started_us: Int,
  result: StepResult,
) -> StepResult {
  let #(sent, failed) = client.stats(ctx.net, id)
  result
  |> step.with_requests(sent: sent, failed: failed)
  |> step.with_duration(clock.us_to_ms(clock.elapsed_us(since: started_us)))
}

fn announce(ctx: Ctx, id: Int, text: String) -> Nil {
  let title = case catalog.find(id) {
    Ok(info) -> info.title
    Error(Nil) -> "step"
  }
  ctx.progress("[" <> int.to_string(id) <> "/17] " <> title <> ": " <> text)
}

/// Run the whole pipeline. `steps` holds the implemented steps other than
/// Step 2, which is passed separately because it also detects the format.
pub fn run_all(
  ctx: Ctx,
  config: Config,
  connect: Option(ConnectFn),
  steps: List(#(Int, StepFn)),
) -> Finished {
  let #(results, final_ctx, connected) =
    catalog.all()
    |> list.fold(#([], ctx, True), fn(acc, info) {
      let #(results, ctx, connected) = acc
      let id = info.id
      let step_fn = list.key_find(steps, id)
      let implemented = case id {
        2 -> connect != None
        _ -> step_fn != Error(Nil)
      }
      let gated = case gate(config, id, implemented) {
        Some(result) -> Some(result)
        None ->
          case !connected && list.contains(needs_chat, id) {
            True -> Some(step.not_run(id, Skipped, "no_connectivity"))
            False -> None
          }
      }
      case gated, id, connect, step_fn {
        Some(result), _, _, _ -> {
          announce(
            ctx,
            id,
            "not run (" <> option.unwrap(result.reason, "") <> ")",
          )
          #([result, ..results], ctx, connected)
        }
        None, 2, Some(connect), _ -> {
          announce(ctx, id, "running")
          let started = clock.monotonic_us()
          let #(result, format) =
            run_isolated(ctx, id, connect, fn(crashed) { #(crashed, None) })
          let result = finish(ctx, id, started, result)
          announce(ctx, id, verdict.verdict_to_string(result.verdict))
          let #(ctx, connected) = case config.api_format, format {
            Some(_), _ -> #(ctx, True)
            None, Some(format) -> #(
              Ctx(..ctx, target: endpoint.with_format(ctx.target, format)),
              True,
            )
            None, None -> #(ctx, False)
          }
          #([result, ..results], ctx, connected)
        }
        None, _, _, Ok(run) -> {
          announce(ctx, id, "running")
          let started = clock.monotonic_us()
          let result =
            run_isolated(ctx, id, run, fn(crashed) { crashed })
            |> finish(ctx, id, started, _)
          announce(ctx, id, verdict.verdict_to_string(result.verdict))
          #([result, ..results], ctx, connected)
        }
        None, _, _, _ -> #(
          [step.not_run(id, NotApplicable, "not_implemented"), ..results],
          ctx,
          connected,
        )
      }
    })
  let step_two_ran =
    list.any(results, fn(result) {
      result.id == 2 && result.status == verdict.Run
    })
  Finished(results: list.reverse(results), api_format: case config.api_format {
    Some(format) -> Some(format)
    None ->
      case connected && step_two_ran {
        True -> Some(final_ctx.target.format)
        False -> None
      }
  })
}
