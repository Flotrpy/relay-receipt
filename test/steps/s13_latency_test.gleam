import gleam/option.{Some}
import gleam/string
import receipt/ctx.{Ctx}
import receipt/http/types as http
import receipt/step
import receipt/steps/s13_latency.{
  Bimodal, HighVariance, Stable, TooFew, Variable,
} as s13
import receipt/verdict.{Inconclusive, Informational}
import support/fake
import support/world

pub fn fewer_than_three_samples_is_too_few_test() {
  assert s13.classify([]) == TooFew
  assert s13.classify([100.0, 110.0]) == TooFew
}

pub fn tight_latencies_are_stable_test() {
  assert s13.classify([500.0, 510.0, 495.0, 505.0, 520.0, 498.0]) == Stable
}

pub fn two_clusters_are_bimodal_test() {
  assert s13.classify([
      500.0,
      510.0,
      495.0,
      505.0,
      1600.0,
      1650.0,
      1620.0,
      1580.0,
    ])
    == Bimodal
}

pub fn a_single_slow_request_is_not_bimodal_test() {
  let shape = s13.classify([500.0, 510.0, 495.0, 505.0, 498.0, 502.0, 4000.0])
  assert shape != Bimodal
  assert shape == HighVariance
}

pub fn moderate_spread_is_variable_test() {
  // CV of about 0.33 with no gap wider than half the median.
  assert s13.classify([300.0, 380.0, 460.0, 540.0, 620.0, 700.0]) == Variable
}

pub fn every_decided_shape_is_informational_test() {
  assert s13.build([500.0, 510.0, 495.0], 3).verdict == Informational
  let bimodal =
    s13.build([500.0, 510.0, 495.0, 505.0, 1600.0, 1650.0, 1620.0, 1580.0], 8)
  assert bimodal.verdict == Informational
  let assert [step.Finding(step.Signal, text)] = bimodal.findings
  assert string.contains(text, "On its own this shows nothing")
}

pub fn too_few_samples_is_inconclusive_test() {
  let result = s13.build([500.0], 10)
  assert result.verdict == Inconclusive
  assert result.reason == Some("too_few_samples")
  assert string.contains(result.summary, "1 of 10")
}

pub fn run_uses_recorded_completion_times_test() {
  // The fake completes every response at 1000 microseconds.
  let result = s13.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Informational
  assert string.contains(result.summary, "stable")
}

pub fn run_honours_the_probe_count_test() {
  let ctx = world.ctx(fake.handler(fake.honest()))
  let result = s13.run(Ctx(..ctx, latency_probes: 4))
  assert string.contains(string.inspect(result.details), "4 of 4")
}

pub fn failures_are_not_counted_as_samples_test() {
  let result = s13.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
}

pub fn shape_names_are_stable_identifiers_test() {
  assert s13.shape_to_string(Bimodal) == "bimodal"
  assert s13.shape_to_string(HighVariance) == "high_variance"
  assert s13.shape_to_string(TooFew) == "too_few_samples"
}
