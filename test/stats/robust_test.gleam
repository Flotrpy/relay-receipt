import gleam/list
import qcheck
import receipt/stats/descriptive
import receipt/stats/robust.{Gap}
import support/close

pub fn mad_of_known_sample_test() {
  // median 2, absolute deviations 1 1 0 0 2 4 7 -> median 1
  assert robust.mad([1.0, 1.0, 2.0, 2.0, 4.0, 6.0, 9.0]) == Ok(1.0)
  assert robust.mad([]) == Error(Nil)
  assert robust.mad([5.0]) == Ok(0.0)
}

pub fn mad_ignores_a_single_wild_outlier_test() {
  let calm = [10.0, 11.0, 12.0, 13.0, 14.0]
  let wild = [10.0, 11.0, 12.0, 13.0, 9000.0]
  assert robust.mad(calm) == robust.mad(wild)
  let assert Ok(sd_calm) = descriptive.standard_deviation(calm)
  let assert Ok(sd_wild) = descriptive.standard_deviation(wild)
  assert sd_wild >. 100.0 *. sd_calm
}

pub fn iqr_of_known_sample_test() {
  assert close.ok_to(robust.iqr([1.0, 2.0, 3.0, 4.0, 5.0]), 2.0, 1.0e-12)
}

pub fn robust_cv_scales_mad_by_the_median_test() {
  assert close.ok_to(
    robust.robust_cv([8.0, 9.0, 10.0, 11.0, 12.0]),
    1.4826 *. 1.0 /. 10.0,
    1.0e-12,
  )
  assert robust.robust_cv([-1.0, -2.0, -3.0]) == Error(Nil)
}

pub fn trimmed_mean_drops_both_tails_test() {
  let values = [1.0, 2.0, 3.0, 4.0, 100.0]
  assert robust.trimmed_mean(values, 0.2) == Ok(3.0)
  assert close.ok_to(robust.trimmed_mean(values, 0.0), 22.0, 1.0e-12)
  assert robust.trimmed_mean(values, 0.5) == Error(Nil)
  assert robust.trimmed_mean(values, -0.1) == Error(Nil)
}

pub fn widest_gap_respects_the_cluster_minimum_test() {
  let values = [1.0, 1.1, 1.2, 5.0, 5.1, 5.2]
  let assert Ok(Gap(width, below, above)) = robust.widest_gap(values, 2)
  assert close.to(width, 3.8, 1.0e-9)
  assert #(below, above) == #(3, 3)
  // A lone outlier leaves one value above the widest gap, so with a
  // minimum cluster of two that gap is not eligible.
  let outlier = [1.0, 1.1, 1.2, 1.3, 9.0]
  let assert Ok(gap) = robust.widest_gap(outlier, 2)
  assert gap.width <. 0.2
  assert robust.widest_gap([1.0, 2.0, 3.0], 2) == Error(Nil)
}

pub fn two_clusters_are_bimodal_test() {
  assert robust.is_bimodal([0.5, 0.52, 0.55, 0.5, 1.6, 1.7, 1.65, 1.62], 0.5)
}

pub fn one_cluster_with_an_outlier_is_not_bimodal_test() {
  assert !robust.is_bimodal([0.5, 0.52, 0.55, 0.5, 0.51, 0.53, 0.49, 4.0], 0.5)
}

pub fn tight_samples_are_not_bimodal_test() {
  assert !robust.is_bimodal([1.0, 1.05, 1.1, 1.02, 0.98, 1.03], 0.5)
}

pub fn fewer_than_four_values_are_never_bimodal_test() {
  assert !robust.is_bimodal([1.0, 9.0, 9.1], 0.5)
  assert !robust.is_bimodal([], 0.5)
}

pub fn mad_is_never_negative_and_scales_test() {
  use #(values, factor) <- qcheck.given(qcheck.tuple2(
    qcheck.generic_list(
      qcheck.bounded_float(-100.0, 100.0),
      qcheck.bounded_int(1, 30),
    ),
    qcheck.bounded_float(0.1, 10.0),
  ))
  let assert Ok(spread) = robust.mad(values)
  assert spread >=. 0.0
  let assert Ok(scaled) =
    robust.mad(list.map(values, fn(value) { value *. factor }))
  assert close.to(scaled, spread *. factor, 1.0e-6)
}

pub fn trimmed_mean_lies_within_the_sample_range_test() {
  use values <- qcheck.given(qcheck.generic_list(
    qcheck.bounded_float(-100.0, 100.0),
    qcheck.bounded_int(1, 30),
  ))
  let assert Ok(trimmed) = robust.trimmed_mean(values, 0.1)
  let assert Ok(low) = descriptive.minimum(values)
  let assert Ok(high) = descriptive.maximum(values)
  assert trimmed >=. low -. 1.0e-9 && trimmed <=. high +. 1.0e-9
}
