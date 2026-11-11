import gleam/list
import gleam/string
import receipt/rating.{Rating}
import receipt/step
import receipt/verdict.{
  Anomaly, Clean, HighRisk, Inconclusive, Informational, Low, Medium, MediumRisk,
  NotApplicable, ProfileGated,
}

fn clean_run() {
  [
    step.ran(1, Informational, "x"),
    step.ran(3, Clean, "x"),
    step.ran(5, Clean, "x"),
    step.ran(8, Clean, "x"),
    step.ran(9, Clean, "x"),
    step.ran(10, Clean, "x"),
    step.ran(15, Clean, "x"),
  ]
}

fn replace(results: List(step.StepResult), with: step.StepResult) {
  list.map(results, fn(r) {
    case r.id == with.id {
      True -> with
      False -> r
    }
  })
}

pub fn all_clean_is_low_test() {
  let Rating(risk, rule, reasons) = rating.rate(clean_run())
  assert risk == Low
  assert rule == 6
  assert reasons == []
}

pub fn a_run_that_tested_nothing_is_not_low_test() {
  let Rating(risk, rule, reasons) = rating.rate([])
  assert risk == MediumRisk
  assert rule == 5
  assert reasons == ["No rated step ran, so nothing supports a lower rating."]
}

pub fn only_unrated_steps_running_is_not_low_test() {
  let results = [
    step.ran(1, Informational, "x"),
    step.inconclusive(2, "no_format", "x"),
    step.not_run(3, verdict.Skipped, "no_connectivity"),
    step.not_run(8, verdict.Skipped, "no_connectivity"),
  ]
  assert rating.rate(results).risk == MediumRisk
}

pub fn one_clean_rated_step_is_enough_for_low_test() {
  assert rating.rate([step.ran(3, Clean, "x")]).risk == Low
}

pub fn critical_anomaly_is_high_alone_test() {
  [8, 9, 10]
  |> list.each(fn(id) {
    let rated = rating.rate(replace(clean_run(), step.ran(id, Anomaly, "x")))
    assert rated.risk == HighRisk
    assert rated.rule == 1
  })
}

pub fn one_major_anomaly_is_medium_test() {
  let rated = rating.rate(replace(clean_run(), step.ran(3, Anomaly, "x")))
  assert rated.risk == MediumRisk
  assert rated.rule == 3
  let assert [reason] = rated.reasons
  assert string.contains(reason, "Step 3")
}

pub fn two_major_anomalies_are_high_test() {
  let results =
    clean_run()
    |> replace(step.ran(3, Anomaly, "x"))
    |> replace(step.ran(15, Anomaly, "x"))
  let rated = rating.rate(results)
  assert rated.risk == HighRisk
  assert rated.rule == 2
  assert list.length(rated.reasons) == 2
}

pub fn medium_severity_leak_is_medium_not_high_test() {
  let leak = step.ran(9, Anomaly, "path") |> step.with_severity(Medium)
  let rated = rating.rate(replace(clean_run(), leak))
  assert rated.risk == MediumRisk
  assert rated.rule == 4
}

pub fn rated_inconclusive_raises_to_medium_test() {
  let rated =
    rating.rate(replace(clean_run(), step.inconclusive(10, "no_stream", "x")))
  assert rated.risk == MediumRisk
  assert rated.rule == 5
}

pub fn unrated_inconclusive_does_not_move_rating_test() {
  let results = [
    step.inconclusive(13, "few_samples", "x"),
    step.inconclusive(6, "errors", "x"),
    ..clean_run()
  ]
  assert rating.rate(results).risk == Low
}

pub fn steps_that_did_not_run_do_not_move_rating_test() {
  let results = [
    step.not_run(17, NotApplicable, "no_reference"),
    step.not_run(16, ProfileGated, "full only"),
    ..clean_run()
  ]
  assert rating.rate(results).risk == Low
}

pub fn a_crash_raises_to_medium_even_in_an_unrated_step_test() {
  let rated = rating.rate([step.crashed(13, "boom"), ..clean_run()])
  assert rated.risk == MediumRisk
  assert rated.rule == 5
}

pub fn advisory_anomaly_does_not_move_rating_test() {
  assert rating.rate([step.ran(6, Anomaly, "leak"), ..clean_run()]).risk == Low
}

pub fn informational_anomaly_cannot_move_rating_test() {
  assert rating.rate([step.ran(16, Anomaly, "x"), ..clean_run()]).risk == Low
}

pub fn critical_outranks_everything_else_test() {
  let results =
    clean_run()
    |> replace(step.ran(8, Anomaly, "x"))
    |> replace(step.ran(3, Anomaly, "x"))
    |> replace(step.inconclusive(10, "r", "x"))
  assert rating.rate(results).rule == 1
}

pub fn inconclusive_never_counts_as_clean_test() {
  let rated = rating.rate([step.ran(3, Inconclusive, "x")])
  assert rated.risk != Low
}
