//// The Wilson score interval for a binomial proportion.
////
//// Used wherever Receipt reports a rate from a small number of trials
//// (detection rates in the validation tables, adherence in Step 5). Unlike
//// the plain "p plus or minus" interval it stays inside [0, 1] and behaves
//// sensibly at 0 and n successes.

import gleam/float
import gleam/int
import gleam/result
import receipt/stats/normal

pub type Interval {
  Interval(lower: Float, upper: Float)
}

/// The interval at a confidence level such as 0.95. Errors when `trials`
/// is not positive, `successes` is out of range, or the level is not
/// strictly between 0 and 1.
pub fn interval(
  successes: Int,
  trials: Int,
  confidence: Float,
) -> Result(Interval, Nil) {
  case
    trials > 0
    && successes >= 0
    && successes <= trials
    && confidence >. 0.0
    && confidence <. 1.0
  {
    False -> Error(Nil)
    True -> {
      use z <- result.try(normal.quantile(1.0 -. { 1.0 -. confidence } /. 2.0))
      let n = int.to_float(trials)
      let p = int.to_float(successes) /. n
      let z2 = z *. z
      let denominator = 1.0 +. z2 /. n
      let centre = { p +. z2 /. { 2.0 *. n } } /. denominator
      use root <- result.try(float.square_root(
        p *. { 1.0 -. p } /. n +. z2 /. { 4.0 *. n *. n },
      ))
      let margin = z *. root /. denominator
      // At the boundaries the exact limits are 0 and 1; clamp rounding.
      let lower = case successes {
        0 -> 0.0
        _ -> float.max(0.0, centre -. margin)
      }
      let upper = case successes == trials {
        True -> 1.0
        False -> float.min(1.0, centre +. margin)
      }
      Ok(Interval(lower, upper))
    }
  }
}

/// The 95% interval.
pub fn interval_95(successes: Int, trials: Int) -> Result(Interval, Nil) {
  interval(successes, trials, 0.95)
}

pub fn width(interval: Interval) -> Float {
  interval.upper -. interval.lower
}
