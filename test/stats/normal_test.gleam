import qcheck
import receipt/stats/normal
import support/close

pub fn cdf_known_values_test() {
  assert close.to(normal.cdf(0.0), 0.5, 1.0e-15)
  assert close.to(normal.cdf(1.0), 0.8413447460685429, 1.0e-12)
  assert close.to(normal.cdf(-1.0), 0.15865525393145707, 1.0e-12)
  assert close.to(normal.cdf(1.959963984540054), 0.975, 1.0e-12)
  assert close.to(normal.cdf(-3.0), 0.0013498980316301, 1.0e-12)
}

pub fn quantile_known_values_test() {
  assert close.ok_to(normal.quantile(0.5), 0.0, 1.0e-12)
  assert close.ok_to(normal.quantile(0.975), 1.959963984540054, 1.0e-9)
  assert close.ok_to(normal.quantile(0.95), 1.6448536269514722, 1.0e-9)
  assert close.ok_to(normal.quantile(0.001), -3.090232306167813, 1.0e-9)
  assert close.ok_to(normal.quantile(0.999999), 4.753424308822899, 1.0e-8)
}

pub fn quantile_is_undefined_outside_the_open_unit_interval_test() {
  assert normal.quantile(0.0) == Error(Nil)
  assert normal.quantile(1.0) == Error(Nil)
  assert normal.quantile(-0.1) == Error(Nil)
  assert normal.quantile(1.1) == Error(Nil)
}

pub fn quantile_inverts_the_cdf_test() {
  use p <- qcheck.given(qcheck.bounded_float(0.0001, 0.9999))
  let assert Ok(x) = normal.quantile(p)
  assert close.to(normal.cdf(x), p, 1.0e-9)
}

pub fn cdf_is_symmetric_test() {
  use x <- qcheck.given(qcheck.bounded_float(-6.0, 6.0))
  assert close.to(normal.cdf(x) +. normal.cdf(0.0 -. x), 1.0, 1.0e-12)
}

pub fn cdf_is_monotone_test() {
  use #(a, b) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_float(-6.0, 6.0),
    qcheck.bounded_float(0.0, 3.0),
  ))
  assert normal.cdf(a +. b) >=. normal.cdf(a)
}
