//// Measure error rates of Steps 15 and 17 on the simulated relay.
////
//// gleam run -m tools/simulate -- <runs>
////
//// Every run uses a fresh seed and fresh salts for the simulated models,
//// so runs are independent. These are measurements of Receipt's
//// statistics on a simulator, not on real models. They check that the
//// tests behave as designed (false-positive rates at or below their
//// bounds, power against clear differences); they say nothing about how
//// often a real relay's behaviour differs.

import argv
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import receipt/ctx.{Ctx}
import receipt/seq
import receipt/stats/wilson
import receipt/step.{type StepResult}
import receipt/steps/s15_inflation
import receipt/steps/s17_identity
import receipt/verdict.{Anomaly}
import support/fake.{type Fake, Fake}
import support/world

fn anomalies(results: List(StepResult)) -> Int {
  list.count(results, fn(result) { result.verdict == Anomaly })
}

fn rate_line(label: String, hits: Int, runs: Int) -> String {
  let shown = fn(value: Float) {
    float.to_string(float.to_precision(value *. 100.0, 1)) <> "%"
  }
  let interval = case wilson.interval_95(hits, runs) {
    Ok(found) -> shown(found.lower) <> " to " <> shown(found.upper)
    Error(Nil) -> "-"
  }
  "| "
  <> label
  <> " | "
  <> int.to_string(hits)
  <> " / "
  <> int.to_string(runs)
  <> " | "
  <> shown(int.to_float(hits) /. int.to_float(runs))
  <> " | "
  <> interval
  <> " |"
}

fn inflation_runs(runs: Int, percent: Int) -> Int {
  seq.range(1, runs)
  |> list.map(fn(run) {
    let relay = Fake(..fake.honest(), inflation_percent: percent, salt: run)
    let ctx = Ctx(..world.ctx(fake.handler(relay)), seed: 1000 + run)
    s15_inflation.run(ctx)
  })
  |> anomalies
}

fn identity_runs(runs: Int, target: fn(Int) -> Fake) -> Int {
  seq.range(1, runs)
  |> list.map(fn(run) {
    let reference = Fake(..fake.honest(), salt: 100_000 + run)
    let base =
      world.ctx(world.route(fake.handler(target(run)), fake.handler(reference)))
      |> world.with_reference
    s17_identity.run(Ctx(..base, seed: 5000 + run))
  })
  |> anomalies
}

pub fn main() -> Nil {
  let runs = case argv.load().arguments {
    [count, ..] ->
      case int.parse(count) {
        Ok(found) -> found
        Error(Nil) -> 50
      }
    [] -> 50
  }
  let header =
    "| Condition | Anomalies | Rate | 95% Wilson interval |\n| --- | --- | --- | --- |"
  let fifteen = [
    rate_line("no inflation (false positives)", inflation_runs(runs, 0), runs),
    rate_line("inflation on 25% of requests", inflation_runs(runs, 25), runs),
    rate_line("inflation on 50% of requests", inflation_runs(runs, 50), runs),
    rate_line("inflation on every request", inflation_runs(runs, 100), runs),
  ]
  let seventeen = [
    rate_line(
      "same simulated model (false positives)",
      identity_runs(runs, fn(run) { Fake(..fake.honest(), salt: run) }),
      runs,
    ),
    rate_line(
      "different simulated model",
      identity_runs(runs, fn(run) {
        Fake(..fake.honest(), persona: 1, salt: run)
      }),
      runs,
    ),
    rate_line(
      "same model, tools unsupported on the endpoint",
      identity_runs(runs, fn(run) {
        Fake(..fake.honest(), supports_tools: False, salt: run)
      }),
      runs,
    ),
  ]
  io.println(
    string.join(
      [
        "### Step 15 on the simulated relay ("
          <> int.to_string(runs)
          <> " runs each)",
        "",
        header,
        ..fifteen
      ],
      "\n",
    )
    <> "\n\n"
    <> string.join(
      [
        "### Step 17 on the simulated relay ("
          <> int.to_string(runs)
          <> " runs each, general profile)",
        "",
        header,
        ..seventeen
      ],
      "\n",
    ),
  )
}
