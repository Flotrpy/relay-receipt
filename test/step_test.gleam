import gleam/json
import gleam/option.{None, Some}
import receipt/step
import receipt/verdict.{
  Anomaly, Clean, Critical, High, Inconclusive, NotApplicable, ProfileGated, Run,
  Skipped,
}

pub fn ran_sets_status_run_test() {
  let result = step.ran(3, Clean, "nothing seen")
  assert result.status == Run
  assert result.verdict == Clean
  assert result.severity == None
  assert !result.crashed
}

pub fn anomaly_defaults_to_high_severity_test() {
  assert step.ran(8, Anomaly, "rewritten").severity == Some(High)
}

pub fn not_run_is_always_inconclusive_test() {
  let gated = step.not_run(16, ProfileGated, "full profile only")
  assert gated.verdict == Inconclusive
  assert gated.status == ProfileGated
  assert gated.reason == Some("full profile only")
  assert step.not_run(11, NotApplicable, "dropped").verdict == Inconclusive
  assert step.not_run(7, Skipped, "user").verdict == Inconclusive
}

pub fn crashed_is_inconclusive_and_flagged_test() {
  let result = step.crashed(9, "badarg")
  assert result.verdict == Inconclusive
  assert result.crashed
  assert result.status == Run
  assert result.reason == Some("crashed")
}

pub fn severity_only_applies_to_anomalies_test() {
  assert step.with_severity(step.ran(9, Anomaly, "x"), Critical).severity
    == Some(Critical)
  assert step.with_severity(step.ran(9, Clean, "x"), Critical).severity == None
}

pub fn builders_append_in_order_test() {
  let result =
    step.ran(15, Clean, "ok")
    |> step.with_finding(step.Note, "first")
    |> step.with_finding(step.Limit, "second")
    |> step.with_data("n", json.int(20))
    |> step.with_requests(sent: 40, failed: 1)
    |> step.with_duration(1200)
  assert result.findings
    == [step.Finding(step.Note, "first"), step.Finding(step.Limit, "second")]
  assert result.requests_sent == 40
  assert result.requests_failed == 1
  assert result.duration_ms == 1200
  let assert [#("n", _)] = result.data
}
