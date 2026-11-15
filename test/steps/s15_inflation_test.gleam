import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import receipt/http/types as http
import receipt/report/model
import receipt/seq
import receipt/step
import receipt/steps/s15_inflation.{
  Evidence, NoSignal, Pair, Signal, Tokens, Truncated, Unavailable, Undecided,
} as s15
import receipt/verdict.{Anomaly, Clean, Inconclusive}
import support/close
import support/fake.{type Fake, Fake}
import support/world

fn pair(l0: Int, l1: Int) {
  Pair("q", "A", Tokens(l0), Tokens(l1))
}

fn run(relay: Fake) {
  s15.run(world.ctx(fake.handler(relay)))
}

pub fn a_large_gain_scores_zero_test() {
  // Algorithm 1: delta 90, R = 90/11 > 0.6.
  let Evidence(delta, gain, score) = s15.evidence(10, 100)
  assert delta == 90
  assert close.to(gain, 90.0 /. 11.0, 1.0e-12)
  assert score == 0
}

pub fn a_small_positive_gain_scores_one_test() {
  // delta 30, R = 30/101 = 0.297 <= 0.6.
  assert s15.evidence(100, 130) == Evidence(30, 30.0 /. 101.0, 1)
}

pub fn no_gain_scores_two_test() {
  assert s15.evidence(100, 100).score == 2
  assert s15.evidence(100, 80) == Evidence(-20, 0.0, 2)
}

pub fn tau_boundary_is_inclusive_test() {
  // L0 = 9: R = delta / 10, so delta 6 gives exactly 0.6.
  assert s15.evidence(9, 15).score == 1
  assert s15.evidence(9, 16).score == 0
}

pub fn top_k_sum_takes_the_largest_test() {
  assert s15.top_k_sum([0, 2, 1, 0, 2, 1], 3) == 5
  assert s15.top_k_sum([1], 3) == 1
  assert s15.top_k_sum([], 3) == 0
}

pub fn one_strong_question_cannot_raise_a_signal_alone_test() {
  // The maximum question score is 2 and H is 3.
  let pairs = [pair(100, 50), ..list.repeat(pair(10, 100), 19)]
  assert s15.statistic(pairs) == 2
  assert s15.decide(pairs, True) == NoSignal(2)
}

pub fn two_questions_can_raise_a_signal_test() {
  let pairs = [pair(100, 50), pair(100, 120), ..list.repeat(pair(10, 100), 18)]
  assert s15.decide(pairs, True) == Signal(3)
}

pub fn invalid_pairs_are_excluded_not_scored_test() {
  let invalid = [
    Pair("a", "A", Truncated, Tokens(5)),
    Pair("b", "B", Tokens(5), Unavailable),
  ]
  assert s15.valid_count(invalid) == 0
  assert s15.statistic(invalid) == 0
  assert s15.pair_evidence(Pair("a", "A", Truncated, Truncated)) == None
}

pub fn clean_needs_sixteen_valid_pairs_and_a_finished_run_test() {
  let good = list.repeat(pair(10, 100), 16)
  let bad = list.repeat(Pair("x", "A", Unavailable, Tokens(3)), 4)
  assert s15.decide(list.append(good, bad), True) == NoSignal(0)
  assert s15.decide(list.append(list.drop(good, 1), [pair(10, 100)]), False)
    == Undecided(0, 16)
  assert s15.decide(list.append(list.drop(good, 1), bad), True)
    == Undecided(0, 15)
}

pub fn a_signal_does_not_need_a_finished_run_test() {
  assert s15.decide([pair(100, 100), pair(100, 100)], False) == Signal(4)
}

pub fn the_statistic_never_decreases_as_pairs_are_added_test() {
  let lengths =
    qcheck.generic_list(
      qcheck.tuple2(qcheck.bounded_int(1, 400), qcheck.bounded_int(1, 400)),
      qcheck.bounded_int(1, 20),
    )
  use observed <- qcheck.given(lengths)
  let pairs = list.map(observed, fn(l) { pair(l.0, l.1) })
  seq.range(1, list.length(pairs))
  |> list.each(fn(count) {
    assert s15.statistic(list.take(pairs, count))
      >= s15.statistic(list.take(pairs, count - 1))
  })
}

pub fn score_is_zero_one_or_two_test() {
  use #(l0, l1) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 5000),
    qcheck.bounded_int(0, 5000),
  ))
  let score = s15.evidence(l0, l1).score
  assert score >= 0 && score <= 2
}

pub fn honest_relay_is_clean_after_the_full_run_test() {
  let result = run(fake.honest())
  assert result.verdict == Clean
  assert string.contains(result.summary, "20 valid question pairs")
  assert string.contains(string.inspect(result.data), "\"n\"")
}

pub fn inflating_relay_raises_the_signal_and_stops_early_test() {
  let result = run(Fake(..fake.honest(), inflation_percent: 100))
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "PTIA-consistent signal")
  // One block of five questions is enough.
  assert string.contains(result.summary, "over 5 valid question pairs")
}

pub fn partial_inflation_is_still_found_test() {
  let result = run(Fake(..fake.honest(), inflation_percent: 40))
  assert result.verdict == Anomaly
}

pub fn missing_usage_is_inconclusive_test() {
  let result = run(Fake(..fake.honest(), reports_usage: False))
  assert result.verdict == Inconclusive
  assert result.reason == Some("too_few_valid_pairs")
}

pub fn truncated_replies_are_inconclusive_test() {
  let result = run(Fake(..fake.honest(), always_truncates: True))
  assert result.verdict == Inconclusive
}

pub fn failing_endpoint_is_inconclusive_test() {
  assert run_with_timeout().verdict == Inconclusive
}

fn run_with_timeout() {
  s15.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
}

pub fn every_result_states_the_two_limits_test() {
  [run(fake.honest()), run(Fake(..fake.honest(), inflation_percent: 100))]
  |> list.each(fn(result) {
    let limits =
      list.filter(result.findings, fn(f) { f.level == step.Limit })
      |> list.map(fn(f) { f.text })
    assert list.any(limits, string.contains(
      _,
      "misreported without the visible text changing",
    ))
    assert list.any(limits, string.contains(
      _,
      "hidden reasoning tokens cannot be detected black-box",
    ))
  })
}

pub fn the_report_carries_the_papers_error_rate_as_the_papers_test() {
  let assert Some(rate) = run(fake.honest()).error_rate
  assert rate.kind == "false_positive"
  assert string.contains(rate.basis, "arXiv:2609.20370")
  assert string.contains(rate.basis, "not re-measured")
}

pub fn report_limits_include_the_step_fifteen_sentences_test() {
  let limits = model.limits_for([run(fake.honest())])
  assert list.any(limits, string.contains(_, "arXiv:2510.05181"))
}

pub fn the_same_seed_asks_the_same_questions_test() {
  let first = run(fake.honest())
  let second = run(fake.honest())
  assert first.data == second.data
}
