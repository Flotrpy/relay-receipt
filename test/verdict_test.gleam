import gleam/list
import receipt/verdict.{
  Anomaly, Clean, Critical, High, Inconclusive, Informational, Medium,
  NotApplicable, ProfileGated, Run, Skipped,
}

pub fn verdict_strings_round_trip_test() {
  [Clean, Anomaly, Inconclusive, Informational]
  |> list.each(fn(v) {
    assert verdict.verdict_from_string(verdict.verdict_to_string(v)) == Ok(v)
  })
}

pub fn status_strings_round_trip_test() {
  [Run, Skipped, ProfileGated, NotApplicable]
  |> list.each(fn(s) {
    assert verdict.status_from_string(verdict.status_to_string(s)) == Ok(s)
  })
}

pub fn unknown_words_are_rejected_test() {
  assert verdict.verdict_from_string("safe") == Error(Nil)
  assert verdict.verdict_from_string("Clean") == Error(Nil)
  assert verdict.status_from_string("done") == Error(Nil)
}

pub fn verdict_strings_match_the_documented_vocabulary_test() {
  assert verdict.verdict_to_string(Clean) == "clean"
  assert verdict.verdict_to_string(Anomaly) == "anomaly"
  assert verdict.verdict_to_string(Inconclusive) == "inconclusive"
  assert verdict.verdict_to_string(Informational) == "informational"
  assert verdict.status_to_string(ProfileGated) == "profile_gated"
  assert verdict.status_to_string(NotApplicable) == "not_applicable"
}

pub fn risk_strings_are_upper_case_test() {
  assert verdict.risk_to_string(verdict.Low) == "LOW"
  assert verdict.risk_to_string(verdict.MediumRisk) == "MEDIUM"
  assert verdict.risk_to_string(verdict.HighRisk) == "HIGH"
}

pub fn worst_severity_picks_the_more_serious_test() {
  assert verdict.worst_severity(Medium, Critical) == Critical
  assert verdict.worst_severity(High, Medium) == High
  assert verdict.worst_severity(Medium, Medium) == Medium
}
