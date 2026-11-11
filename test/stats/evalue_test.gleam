import gleam/float
import gleam/int
import gleam/list
import qcheck
import receipt/prng
import receipt/seq
import receipt/stats/evalue
import receipt/thresholds
import support/close

pub fn calibrator_known_values_test() {
  assert evalue.calibrate(1.0) == 0.5
  // p = e^-1: (1 - 2/e) / (1/e) = e - 2.
  assert close.to(evalue.calibrate(0.36787944117144233), 0.718281828, 1.0e-8)
  // p = 0.05
  assert close.to(evalue.calibrate(0.05), 1.783, 0.0005)
}

pub fn smallest_permutation_p_value_alone_can_decide_test() {
  // With B = 4999 the smallest p is 1/5000. Its e-value, averaged with a
  // component that contributes 1, must still reach the threshold of 20.
  let smallest = 1.0 /. int.to_float(thresholds.identity_permutations + 1)
  let e = evalue.calibrate(smallest)
  assert e >. 60.0
  assert evalue.rejects(evalue.mean([e, 1.0]), thresholds.alpha)
}

pub fn calibrator_never_exceeds_one_over_p_test() {
  use p <- qcheck.given(qcheck.bounded_float(0.000001, 1.0))
  let e = evalue.calibrate(p)
  assert e >=. 0.0
  assert e <=. 1.0 /. p +. 1.0e-9
}

pub fn calibrator_is_decreasing_in_p_test() {
  use #(p, step) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_float(0.0001, 0.9),
    qcheck.bounded_float(0.0001, 0.09),
  ))
  assert evalue.calibrate(p) >=. evalue.calibrate(p +. step) -. 1.0e-9
}

pub fn calibrator_integrates_to_one_test() {
  // Midpoint rule on a log grid: integral over p in (0, 1] of e(p) dp,
  // substituting p = exp(-t), dp = exp(-t) dt, t from 0 to 60.
  let steps = 60_000
  let width = 60.0 /. int.to_float(steps)
  let integral =
    seq.range(0, steps - 1)
    |> list.fold(0.0, fn(total, index) {
      let t = { int.to_float(index) +. 0.5 } *. width
      let p = float.exponential(0.0 -. t)
      total +. evalue.calibrate(p) *. p *. width
    })
  // The tail beyond t = 60 contributes about 1/60.
  assert close.to(integral, 1.0 -. 1.0 /. 60.0, 0.002)
}

pub fn extreme_p_values_do_not_overflow_test() {
  assert evalue.calibrate(0.0) >. 0.0
  assert evalue.calibrate(-1.0) >. 0.0
  assert evalue.calibrate(2.0) == 0.5
}

pub fn product_and_running_products_test() {
  assert evalue.product([]) == 1.0
  assert evalue.product([2.0, 0.5, 3.0]) == 3.0
  assert evalue.running_products([2.0, 0.5, 3.0]) == [2.0, 1.0, 3.0]
  assert evalue.running_products([]) == []
}

pub fn mean_of_nothing_is_no_evidence_test() {
  assert evalue.mean([]) == 1.0
  assert evalue.mean([40.0, 1.0]) == 20.5
}

pub fn threshold_is_one_over_alpha_test() {
  assert evalue.threshold(0.05) == 20.0
  assert evalue.rejects(20.0, 0.05)
  assert !evalue.rejects(19.99, 0.05)
}

pub fn anytime_p_value_uses_the_running_maximum_test() {
  assert evalue.p_value([2.0, 40.0, 3.0]) == 0.025
  assert evalue.p_value([0.5, 0.9]) == 1.0
  assert evalue.p_value([]) == 1.0
}

/// One null run: up to `batches` uniform p-values, calibrated and
/// multiplied. Returns whether the product ever reached the threshold.
fn null_run_rejects(batches: Int, generator: prng.Prng) -> #(Bool, prng.Prng) {
  let #(p_values, generator) = prng.floats(generator, batches)
  let running = evalue.running_products(list.map(p_values, evalue.calibrate))
  #(list.any(running, evalue.rejects(_, 0.05)), generator)
}

pub fn stopping_at_any_time_keeps_the_false_positive_rate_below_alpha_test() {
  // 20 000 null runs of 5 batches each, the maximum Step 17 uses. By
  // Ville's inequality at most 5% may ever cross 20, however we stop.
  let runs = 20_000
  let #(rejections, _) =
    seq.range(1, runs)
    |> list.fold(#(0, prng.new(1939)), fn(acc, _) {
      let #(rejections, generator) = acc
      let #(rejected, generator) = null_run_rejects(5, generator)
      case rejected {
        True -> #(rejections + 1, generator)
        False -> #(rejections, generator)
      }
    })
  let rate = int.to_float(rejections) /. int.to_float(runs)
  assert rate <. 0.05
}

pub fn averaging_two_null_components_keeps_the_rate_below_alpha_test() {
  let runs = 20_000
  let #(rejections, _) =
    seq.range(1, runs)
    |> list.fold(#(0, prng.new(2021)), fn(acc, _) {
      let #(rejections, generator) = acc
      let #(first, generator) = prng.floats(generator, 5)
      let #(second, generator) = prng.floats(generator, 5)
      let combined =
        list.zip(
          evalue.running_products(list.map(first, evalue.calibrate)),
          evalue.running_products(list.map(second, evalue.calibrate)),
        )
        |> list.map(fn(pair) { evalue.mean([pair.0, pair.1]) })
      case list.any(combined, evalue.rejects(_, 0.05)) {
        True -> #(rejections + 1, generator)
        False -> #(rejections, generator)
      }
    })
  assert int.to_float(rejections) /. int.to_float(runs) <. 0.05
}

pub fn small_p_values_in_every_batch_lead_to_rejection_test() {
  // Two batches at p = 0.01 give 4.45 * 4.45 = 19.8, just short of 20;
  // a third settles it.
  let two = evalue.running_products(list.map([0.01, 0.01], evalue.calibrate))
  assert !list.any(two, evalue.rejects(_, 0.05))
  let three =
    evalue.running_products(list.map([0.01, 0.01, 0.01], evalue.calibrate))
  assert list.any(three, evalue.rejects(_, 0.05))
}
