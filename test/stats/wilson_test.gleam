import gleam/int
import qcheck
import receipt/stats/wilson.{Interval}
import support/close

pub fn matches_the_intervals_reported_in_the_token_count_paper_test() {
  // arXiv:2608.29930 reports, for its 6 eligible holdout pairs, sensitivity
  // 0.50 with a 95% Wilson interval of 0.15-0.85 (2 of 4) and specificity
  // 1.00 with 0.342-1.00 (2 of 2).
  let assert Ok(Interval(lower, upper)) = wilson.interval_95(2, 4)
  assert close.to(lower, 0.15, 0.001)
  assert close.to(upper, 0.85, 0.001)
  let assert Ok(Interval(lower2, upper2)) = wilson.interval_95(2, 2)
  assert close.to(lower2, 0.342, 0.001)
  assert upper2 == 1.0
}

pub fn textbook_value_test() {
  // 10 successes in 20 trials at 95%: 0.2993 to 0.7007.
  let assert Ok(Interval(lower, upper)) = wilson.interval_95(10, 20)
  assert close.to(lower, 0.2993, 0.0001)
  assert close.to(upper, 0.7007, 0.0001)
}

pub fn zero_and_all_successes_touch_the_boundary_test() {
  let assert Ok(none) = wilson.interval_95(0, 20)
  assert none.lower == 0.0
  assert close.to(none.upper, 0.1611, 0.0001)
  let assert Ok(all) = wilson.interval_95(20, 20)
  assert all.upper == 1.0
  assert close.to(all.lower, 0.8389, 0.0001)
}

pub fn invalid_inputs_are_errors_test() {
  assert wilson.interval_95(1, 0) == Error(Nil)
  assert wilson.interval_95(-1, 10) == Error(Nil)
  assert wilson.interval_95(11, 10) == Error(Nil)
  assert wilson.interval(5, 10, 1.0) == Error(Nil)
  assert wilson.interval(5, 10, 0.0) == Error(Nil)
}

fn counts() {
  qcheck.bounded_int(1, 500)
  |> qcheck.bind(fn(trials) {
    qcheck.bounded_int(0, trials)
    |> qcheck.map(fn(successes) { #(successes, trials) })
  })
}

pub fn interval_stays_in_unit_range_and_contains_the_estimate_test() {
  use #(successes, trials) <- qcheck.given(counts())
  let assert Ok(Interval(lower, upper)) = wilson.interval_95(successes, trials)
  let estimate = int.to_float(successes) /. int.to_float(trials)
  assert lower >=. 0.0 && upper <=. 1.0
  assert lower <=. estimate +. 1.0e-12 && estimate <=. upper +. 1.0e-12
}

pub fn higher_confidence_gives_a_wider_interval_test() {
  use #(successes, trials) <- qcheck.given(counts())
  let assert Ok(narrow) = wilson.interval(successes, trials, 0.8)
  let assert Ok(wide) = wilson.interval(successes, trials, 0.99)
  assert wilson.width(wide) >=. wilson.width(narrow) -. 1.0e-12
}

pub fn more_trials_at_the_same_rate_give_a_narrower_interval_test() {
  use #(successes, trials) <- qcheck.given(counts())
  let assert Ok(small) = wilson.interval_95(successes, trials)
  let assert Ok(large) = wilson.interval_95(successes * 4, trials * 4)
  assert wilson.width(large) <=. wilson.width(small) +. 1.0e-12
}

pub fn interval_is_symmetric_under_swapping_success_and_failure_test() {
  use #(successes, trials) <- qcheck.given(counts())
  let assert Ok(a) = wilson.interval_95(successes, trials)
  let assert Ok(b) = wilson.interval_95(trials - successes, trials)
  assert close.to(a.lower, 1.0 -. b.upper, 1.0e-9)
  assert close.to(a.upper, 1.0 -. b.lower, 1.0e-9)
}
