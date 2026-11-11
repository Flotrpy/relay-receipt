//// Holm's step-down correction for multiple comparisons.
////
//// Controls the family-wise error rate with no assumption about how the
//// tests depend on each other. Receipt uses it for diagnostic tables that
//// show many p-values at once (for example one per tool-choice template in
//// Step 17), never for a step's verdict.

import gleam/float
import gleam/int
import gleam/list

/// Adjusted p-values, in the order the raw p-values were given.
///
/// With m tests and raw p-values sorted ascending as p(1)..p(m), the
/// adjusted value of p(i) is the running maximum of
/// `min(1, (m - i + 1) * p(i))`.
pub fn adjust(p_values: List(Float)) -> List(Float) {
  let count = list.length(p_values)
  let ascending =
    p_values
    |> list.index_map(fn(p, index) { #(index, p) })
    |> list.sort(fn(a, b) { float.compare(a.1, b.1) })
  let #(adjusted, _) =
    list.index_fold(ascending, #([], 0.0), fn(acc, pair, rank) {
      let #(done, running) = acc
      let scaled = float.min(1.0, int.to_float(count - rank) *. pair.1)
      let value = float.max(running, scaled)
      #([#(pair.0, value), ..done], value)
    })
  adjusted
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(pair) { pair.1 })
}

/// For each hypothesis, whether it is rejected at family-wise level alpha.
pub fn reject(p_values: List(Float), alpha: Float) -> List(Bool) {
  adjust(p_values) |> list.map(fn(p) { p <=. alpha })
}
