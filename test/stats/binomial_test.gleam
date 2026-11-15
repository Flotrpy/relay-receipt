import qcheck
import receipt/stats/binomial
import support/close

pub fn cdf_known_values_test() {
  // Binomial(10, 0.5): P(X <= 3) = 176/1024.
  assert close.to(binomial.cdf(3, 10, 0.5), 176.0 /. 1024.0, 1.0e-12)
  assert close.to(binomial.cdf(0, 5, 0.2), 0.32768, 1.0e-12)
  assert binomial.cdf(-1, 10, 0.5) == 0.0
  assert binomial.cdf(10, 10, 0.5) == 1.0
  assert binomial.cdf(12, 10, 0.5) == 1.0
}

pub fn upper_tail_known_values_test() {
  assert close.to(binomial.upper_tail(8, 10, 0.5), 56.0 /. 1024.0, 1.0e-12)
  assert binomial.upper_tail(0, 10, 0.3) == 1.0
  assert close.to(binomial.upper_tail(1, 5, 0.2), 1.0 -. 0.32768, 1.0e-12)
}

pub fn degenerate_probabilities_test() {
  assert binomial.cdf(3, 10, 0.0) == 1.0
  assert binomial.cdf(3, 10, 1.0) == 0.0
  assert binomial.upper_tail(1, 10, 0.0) == 0.0
}

pub fn streak_length_reproduces_the_cachetracer_value_test() {
  // arXiv:2608.20732 Section III-C: N_flood = M_nohit = 59 at
  // delta = alpha = 0.05.
  assert binomial.streak_length(0.05, 0.05) == Ok(59)
  assert binomial.streak_length(0.2, 0.05) == Ok(14)
  assert binomial.streak_length(0.1, 0.05) == Ok(29)
}

pub fn probe_budgets_reproduce_the_cachetracer_table_test() {
  // arXiv:2608.20732 Section III-D: allowing 0, 2, 4, 6 and 8 misses
  // requires 59, 124, 181, 234 and 286 successful probes.
  assert binomial.probes_for_misses(0, 0.05, 0.05) == Ok(59)
  assert binomial.probes_for_misses(2, 0.05, 0.05) == Ok(124)
  assert binomial.probes_for_misses(4, 0.05, 0.05) == Ok(181)
  assert binomial.probes_for_misses(6, 0.05, 0.05) == Ok(234)
  assert binomial.probes_for_misses(8, 0.05, 0.05) == Ok(286)
}

pub fn partial_threshold_reproduces_the_cachetracer_value_test() {
  // arXiv:2608.20732: M_partial = 15 at N_prove = 181.
  assert binomial.misses_to_reject(181, 0.05, 0.05) == Ok(15)
}

pub fn coarse_preset_values_test() {
  assert binomial.probes_for_misses(2, 0.2, 0.05) == Ok(30)
  assert binomial.misses_to_reject(30, 0.2, 0.05) == Ok(11)
}

pub fn invalid_parameters_are_errors_test() {
  assert binomial.streak_length(0.0, 0.05) == Error(Nil)
  assert binomial.streak_length(0.05, 1.0) == Error(Nil)
  assert binomial.probes_for_misses(-1, 0.05, 0.05) == Error(Nil)
  assert binomial.misses_to_reject(0, 0.05, 0.05) == Error(Nil)
}

pub fn cdf_and_upper_tail_are_complementary_test() {
  use #(n, k, p) <- qcheck.given(qcheck.tuple3(
    qcheck.bounded_int(1, 200),
    qcheck.bounded_int(0, 200),
    qcheck.bounded_float(0.01, 0.99),
  ))
  assert close.to(
    binomial.cdf(k, n, p) +. binomial.upper_tail(k + 1, n, p),
    1.0,
    1.0e-9,
  )
}

pub fn cdf_is_monotone_in_k_and_decreasing_in_p_test() {
  use #(n, k, p) <- qcheck.given(qcheck.tuple3(
    qcheck.bounded_int(1, 200),
    qcheck.bounded_int(0, 199),
    qcheck.bounded_float(0.01, 0.9),
  ))
  assert binomial.cdf(k + 1, n, p) >=. binomial.cdf(k, n, p) -. 1.0e-12
  assert binomial.cdf(k, n, p +. 0.05) <=. binomial.cdf(k, n, p) +. 1.0e-12
}

pub fn streak_length_is_the_smallest_that_meets_alpha_test() {
  use #(delta, alpha) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_float(0.01, 0.5),
    qcheck.bounded_float(0.001, 0.2),
  ))
  let assert Ok(n) = binomial.streak_length(delta, alpha)
  // n straight hits have probability at most alpha; n - 1 do not.
  assert binomial.cdf(0, n, delta) <=. alpha +. 1.0e-12
  assert binomial.cdf(0, n - 1, delta) >. alpha -. 1.0e-12
}

pub fn probe_budget_is_the_smallest_that_meets_alpha_test() {
  use #(misses, delta) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(0, 6),
    qcheck.bounded_float(0.03, 0.4),
  ))
  let assert Ok(n) = binomial.probes_for_misses(misses, delta, 0.05)
  assert binomial.cdf(misses, n, delta) <=. 0.05
  assert binomial.cdf(misses, n - 1, delta) >. 0.05
}
