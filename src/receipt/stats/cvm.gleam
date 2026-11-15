//// The Cramér-von Mises test of uniformity on [0, 1].
////
//// This is the test the rank-uniformity paper (arXiv:2506.06975) applies
//// to its rank statistics. The null distribution of the statistic is
//// simulated with a seeded generator rather than taken from asymptotic
//// tables, so the p-value is valid for the small samples Receipt uses.

import gleam/float
import gleam/int
import gleam/list
import receipt/prng.{type Prng}
import receipt/stats/permutation

/// `omega^2 = 1/(12n) + sum_i ((2i - 1)/(2n) - r_(i))^2` over the sorted
/// values. Zero for an empty sample.
pub fn statistic(values: List(Float)) -> Float {
  let count = list.length(values)
  case count {
    0 -> 0.0
    _ -> {
      let n = int.to_float(count)
      list.sort(values, float.compare)
      |> list.index_fold(1.0 /. { 12.0 *. n }, fn(total, value, index) {
        let expected = int.to_float(2 * index + 1) /. { 2.0 *. n }
        let difference = expected -. value
        total +. difference *. difference
      })
    }
  }
}

pub type TestResult {
  TestResult(statistic: Float, p_value: Float)
}

/// Test whether the values look like independent draws from Uniform[0, 1].
/// Large statistics are extreme.
pub fn uniformity_test(
  values: List(Float),
  simulations: Int,
  prng: Prng,
) -> #(TestResult, Prng) {
  let observed = statistic(values)
  let count = list.length(values)
  let #(simulated, prng) = simulate(count, simulations, prng, [])
  #(TestResult(observed, permutation.p_value(observed, simulated)), prng)
}

fn simulate(
  count: Int,
  remaining: Int,
  prng: Prng,
  acc: List(Float),
) -> #(List(Float), Prng) {
  case remaining <= 0 {
    True -> #(acc, prng)
    False -> {
      let #(draws, prng) = prng.floats(prng, count)
      simulate(count, remaining - 1, prng, [statistic(draws), ..acc])
    }
  }
}
