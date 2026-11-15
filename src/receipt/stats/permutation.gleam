//// Monte Carlo p-values.

import gleam/int
import gleam/list

/// Slack for comparing floating-point statistics that should be equal.
const tolerance = 1.0e-12

/// The p-value of an observed statistic against statistics simulated
/// under the null hypothesis, where large values are extreme:
/// `(1 + #{simulated >= observed}) / (B + 1)`.
///
/// Counting the observed value itself keeps the p-value valid (never too
/// small) for any number of simulations, and means it is never zero.
pub fn p_value(observed: Float, simulated: List(Float)) -> Float {
  let as_extreme =
    list.count(simulated, fn(value) { value >=. observed -. tolerance })
  int.to_float(1 + as_extreme) /. int.to_float(1 + list.length(simulated))
}

/// The smallest p-value `p_value` can return with this many simulations.
pub fn smallest_p(simulations: Int) -> Float {
  1.0 /. int.to_float(1 + simulations)
}
