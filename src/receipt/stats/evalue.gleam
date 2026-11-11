//// E-values and anytime-valid sequential testing.
////
//// An e-value is a non-negative statistic whose expectation under the
//// null hypothesis is at most 1. Products of e-values from independent
//// batches form a test martingale, and by Ville's inequality the
//// probability that such a product ever reaches `1 / alpha` under the
//// null is at most `alpha`, whenever one chooses to look or stop. This is
//// what lets Step 17 stop early without inflating its error rate.
////
//// References: Vovk and Wang, "E-values: Calibration, combination and
//// applications", Annals of Statistics 49(3), 2021; Ramdas et al.,
//// "Game-theoretic statistics and safe anytime-valid inference",
//// Statistical Science 38(4), 2023.

import gleam/float
import gleam/int
import gleam/list
import gleam/result

/// Turn a p-value into an e-value with the calibrator
/// `(1 - p + p ln p) / (p (ln p)^2)`, the average of `kappa * p^(kappa-1)`
/// over `kappa` in [0, 1]. It integrates to exactly 1 over p in [0, 1].
///
/// p is clamped to (0, 1]; `calibrate(1.0)` is the limit 1/2.
pub fn calibrate(p: Float) -> Float {
  let p = float.clamp(p, 1.0e-300, 1.0)
  case p >. 1.0 -. 1.0e-9 {
    True -> 0.5
    False -> {
      let ln_p = float.logarithm(p) |> result.unwrap(0.0)
      { 1.0 -. p +. p *. ln_p } /. { p *. ln_p *. ln_p }
    }
  }
}

/// The product of e-values from independent batches. The empty product
/// is 1: no evidence either way.
pub fn product(e_values: List(Float)) -> Float {
  list.fold(e_values, 1.0, fn(total, e) { total *. e })
}

/// The running products after each batch.
pub fn running_products(e_values: List(Float)) -> List(Float) {
  let #(_, products) =
    list.fold(e_values, #(1.0, []), fn(acc, e) {
      let #(total, products) = acc
      let total = total *. e
      #(total, [total, ..products])
    })
  list.reverse(products)
}

/// The arithmetic mean of e-values (or of e-processes at the same time).
/// A mean of e-values is an e-value whatever their dependence, so this
/// combines several tests of the same null without further correction.
pub fn mean(e_values: List(Float)) -> Float {
  case e_values {
    [] -> 1.0
    _ -> float.sum(e_values) /. int.to_float(list.length(e_values))
  }
}

/// The evidence level at which a test at significance `alpha` rejects.
pub fn threshold(alpha: Float) -> Float {
  1.0 /. alpha
}

pub fn rejects(e_value: Float, alpha: Float) -> Bool {
  e_value >=. threshold(alpha)
}

/// The anytime-valid p-value implied by an e-process: `min(1, 1 / max E)`
/// over the values seen so far.
pub fn p_value(running: List(Float)) -> Float {
  case list.reduce(running, float.max) {
    Ok(largest) if largest >. 1.0 -> 1.0 /. largest
    _ -> 1.0
  }
}
