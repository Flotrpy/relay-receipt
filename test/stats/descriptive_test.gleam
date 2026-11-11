import gleam/float
import gleam/list
import qcheck
import receipt/stats/descriptive as d
import support/close

const sample = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]

fn values_generator() {
  qcheck.generic_list(
    qcheck.bounded_float(-1000.0, 1000.0),
    qcheck.bounded_int(1, 40),
  )
}

pub fn empty_samples_have_no_statistics_test() {
  assert d.mean([]) == Error(Nil)
  assert d.median([]) == Error(Nil)
  assert d.minimum([]) == Error(Nil)
  assert d.variance([]) == Error(Nil)
  assert d.variance([1.0]) == Error(Nil)
  assert d.standard_deviation([3.0]) == Error(Nil)
}

pub fn known_values_test() {
  assert close.ok_to(d.mean(sample), 5.0, 1.0e-12)
  assert close.ok_to(d.variance(sample), 32.0 /. 7.0, 1.0e-12)
  assert close.ok_to(d.standard_deviation(sample), 2.138089935, 1.0e-8)
  assert close.ok_to(d.coefficient_of_variation(sample), 0.427617987, 1.0e-8)
  assert d.minimum(sample) == Ok(2.0)
  assert d.maximum(sample) == Ok(9.0)
}

pub fn median_of_odd_and_even_samples_test() {
  assert d.median([3.0, 1.0, 2.0]) == Ok(2.0)
  assert d.median([4.0, 1.0, 3.0, 2.0]) == Ok(2.5)
  assert d.median([7.0]) == Ok(7.0)
}

pub fn quantiles_interpolate_test() {
  let values = [10.0, 20.0, 30.0, 40.0, 50.0]
  assert d.quantile(values, 0.0) == Ok(10.0)
  assert d.quantile(values, 1.0) == Ok(50.0)
  assert d.quantile(values, 0.25) == Ok(20.0)
  assert close.ok_to(d.quantile(values, 0.1), 14.0, 1.0e-9)
  assert d.quantile(values, 1.5) == Error(Nil)
  assert d.quantile(values, -0.1) == Error(Nil)
}

pub fn cv_is_undefined_for_non_positive_mean_test() {
  assert d.coefficient_of_variation([-1.0, -2.0, -3.0]) == Error(Nil)
  assert d.coefficient_of_variation([-1.0, 1.0]) == Error(Nil)
}

pub fn mean_lies_between_minimum_and_maximum_test() {
  use values <- qcheck.given(values_generator())
  let assert Ok(centre) = d.mean(values)
  let assert Ok(low) = d.minimum(values)
  let assert Ok(high) = d.maximum(values)
  assert centre >=. low -. 1.0e-9 && centre <=. high +. 1.0e-9
}

pub fn median_lies_between_minimum_and_maximum_test() {
  use values <- qcheck.given(values_generator())
  let assert Ok(middle) = d.median(values)
  let assert Ok(low) = d.minimum(values)
  let assert Ok(high) = d.maximum(values)
  assert middle >=. low && middle <=. high
}

pub fn variance_is_never_negative_test() {
  use values <- qcheck.given(qcheck.generic_list(
    qcheck.bounded_float(-1000.0, 1000.0),
    qcheck.bounded_int(2, 40),
  ))
  let assert Ok(spread) = d.variance(values)
  assert spread >=. 0.0
}

pub fn shifting_moves_the_mean_and_keeps_the_variance_test() {
  use #(values, shift) <- qcheck.given(qcheck.tuple2(
    qcheck.generic_list(
      qcheck.bounded_float(-100.0, 100.0),
      qcheck.bounded_int(2, 30),
    ),
    qcheck.bounded_float(-50.0, 50.0),
  ))
  let shifted = list.map(values, fn(value) { value +. shift })
  let assert Ok(mean_before) = d.mean(values)
  let assert Ok(mean_after) = d.mean(shifted)
  let assert Ok(variance_before) = d.variance(values)
  let assert Ok(variance_after) = d.variance(shifted)
  assert close.to(mean_after, mean_before +. shift, 1.0e-6)
  assert close.to(variance_after, variance_before, 1.0e-6)
}

pub fn quantile_is_monotone_in_p_test() {
  use #(values, a, b) <- qcheck.given(qcheck.tuple3(
    values_generator(),
    qcheck.bounded_float(0.0, 1.0),
    qcheck.bounded_float(0.0, 1.0),
  ))
  let assert Ok(low) = d.quantile(values, float.min(a, b))
  let assert Ok(high) = d.quantile(values, float.max(a, b))
  assert low <=. high +. 1.0e-9
}
