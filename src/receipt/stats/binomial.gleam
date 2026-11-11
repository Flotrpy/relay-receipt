//// Binomial tail probabilities and the sample sizes derived from them.
////
//// Step 16 derives every threshold from a resolution `delta` and a level
//// `alpha` using these functions; see `docs/steps/16-upstream-map.md`.

import gleam/float
import gleam/int
import gleam/result

/// P(X = k) for X ~ Binomial(n, p), for every k from 0 to `up_to`, as a
/// running list. Computed by the stable recurrence
/// `P(k+1) = P(k) * (n-k)/(k+1) * p/(1-p)`.
fn cumulative(n: Int, p: Float, up_to: Int) -> Float {
  case p <=. 0.0, p >=. 1.0 {
    True, _ -> 1.0
    _, True ->
      case up_to >= n {
        True -> 1.0
        False -> 0.0
      }
    False, False -> {
      let first = float.power(1.0 -. p, int.to_float(n)) |> result.unwrap(0.0)
      sum_terms(n, p /. { 1.0 -. p }, up_to, 0, first, 0.0)
    }
  }
}

fn sum_terms(
  n: Int,
  odds: Float,
  up_to: Int,
  k: Int,
  term: Float,
  total: Float,
) -> Float {
  case k > up_to || k > n {
    True -> total
    False ->
      sum_terms(
        n,
        odds,
        up_to,
        k + 1,
        term *. int.to_float(n - k) /. int.to_float(k + 1) *. odds,
        total +. term,
      )
  }
}

/// P(X <= k) for X ~ Binomial(n, p).
pub fn cdf(k: Int, n: Int, p: Float) -> Float {
  case k < 0, k >= n {
    True, _ -> 0.0
    _, True -> 1.0
    False, False -> float.min(1.0, cumulative(n, p, k))
  }
}

/// P(X >= k) for X ~ Binomial(n, p).
pub fn upper_tail(k: Int, n: Int, p: Float) -> Float {
  case k <= 0 {
    True -> 1.0
    False -> float.max(0.0, 1.0 -. cdf(k - 1, n, p))
  }
}

/// The smallest n with `(1 - delta)^n <= alpha`: how many consecutive
/// hits (or misses) rule out, at level alpha, an uncovered (or covered)
/// share of at least delta.
pub fn streak_length(delta: Float, alpha: Float) -> Result(Int, Nil) {
  case delta >. 0.0 && delta <. 1.0 && alpha >. 0.0 && alpha <. 1.0 {
    False -> Error(Nil)
    True -> {
      use ln_alpha <- result.try(float.logarithm(alpha))
      use ln_keep <- result.try(float.logarithm(1.0 -. delta))
      // Guard against a ratio that is an integer up to rounding.
      let exact = ln_alpha /. ln_keep
      Ok(float.truncate(float.ceiling(exact -. 1.0e-12)))
    }
  }
}

/// The smallest N with `P[Binomial(N, delta) <= misses] <= alpha`: how
/// many probes are needed so that seeing at most `misses` misses supports
/// coverage of at least `1 - delta`.
pub fn probes_for_misses(
  misses: Int,
  delta: Float,
  alpha: Float,
) -> Result(Int, Nil) {
  case
    misses >= 0 && delta >. 0.0 && delta <. 1.0 && alpha >. 0.0 && alpha <. 1.0
  {
    False -> Error(Nil)
    True -> Ok(grow_probes(misses + 1, misses, delta, alpha))
  }
}

fn grow_probes(n: Int, misses: Int, delta: Float, alpha: Float) -> Int {
  case cdf(misses, n, delta) <=. alpha || n > 100_000 {
    True -> n
    False -> grow_probes(n + 1, misses, delta, alpha)
  }
}

/// The smallest m with `P[Binomial(n, delta) >= m] <= alpha`: how many
/// misses in n probes reject coverage of at least `1 - delta`.
pub fn misses_to_reject(
  n: Int,
  delta: Float,
  alpha: Float,
) -> Result(Int, Nil) {
  case n > 0 && delta >. 0.0 && delta <. 1.0 && alpha >. 0.0 && alpha <. 1.0 {
    False -> Error(Nil)
    True -> Ok(grow_misses(0, n, delta, alpha))
  }
}

fn grow_misses(m: Int, n: Int, delta: Float, alpha: Float) -> Int {
  case upper_tail(m, n, delta) <=. alpha || m > n {
    True -> m
    False -> grow_misses(m + 1, n, delta, alpha)
  }
}
