//// Robust statistics for timing data.
////
//// Latencies have heavy right tails: one slow request can dominate a mean
//// or a standard deviation. These summaries are insensitive to a few
//// outliers, and the gap rule separates "two clusters" from "one cluster
//// and an outlier".

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import receipt/stats/descriptive

/// Scale factor that makes the MAD estimate the standard deviation of a
/// normal distribution.
pub const mad_to_sigma = 1.4826

/// Median absolute deviation from the median (unscaled).
pub fn mad(values: List(Float)) -> Result(Float, Nil) {
  use centre <- result.try(descriptive.median(values))
  descriptive.median(
    list.map(values, fn(value) { float.absolute_value(value -. centre) }),
  )
}

/// Interquartile range.
pub fn iqr(values: List(Float)) -> Result(Float, Nil) {
  use low <- result.try(descriptive.quantile(values, 0.25))
  use high <- result.try(descriptive.quantile(values, 0.75))
  Ok(high -. low)
}

/// A robust analogue of the coefficient of variation: scaled MAD over the
/// median. Undefined when the median is not positive.
pub fn robust_cv(values: List(Float)) -> Result(Float, Nil) {
  use centre <- result.try(descriptive.median(values))
  use spread <- result.try(mad(values))
  case centre >. 0.0 {
    True -> Ok(mad_to_sigma *. spread /. centre)
    False -> Error(Nil)
  }
}

/// The mean after dropping the lowest and highest `fraction` of values
/// (each side). `fraction` must be in `[0, 0.5)`.
pub fn trimmed_mean(
  values: List(Float),
  fraction: Float,
) -> Result(Float, Nil) {
  case fraction >=. 0.0 && fraction <. 0.5 {
    False -> Error(Nil)
    True -> {
      let ordered = descriptive.sorted(values)
      let count = list.length(ordered)
      let drop = float.truncate(fraction *. int.to_float(count))
      ordered
      |> list.drop(drop)
      |> list.take(count - 2 * drop)
      |> descriptive.mean
    }
  }
}

/// The widest gap between consecutive sorted values that leaves at least
/// `min_cluster` values on each side.
pub type Gap {
  Gap(
    /// Width of the gap.
    width: Float,
    /// Number of values below the gap.
    below: Int,
    /// Number of values above the gap.
    above: Int,
  )
}

pub fn widest_gap(values: List(Float), min_cluster: Int) -> Result(Gap, Nil) {
  let ordered = descriptive.sorted(values)
  let count = list.length(ordered)
  list.window_by_2(ordered)
  |> list.index_map(fn(pair, index) {
    Gap(width: pair.1 -. pair.0, below: index + 1, above: count - index - 1)
  })
  |> list.filter(fn(gap) {
    gap.below >= min_cluster && gap.above >= min_cluster
  })
  |> list.reduce(fn(best, gap) {
    case gap.width >. best.width {
      True -> gap
      False -> best
    }
  })
}

/// Whether the sample splits into two clusters: the widest gap that leaves
/// at least two values on each side exceeds `ratio` times the median.
/// Needs at least four values; fewer are never bimodal.
pub fn is_bimodal(values: List(Float), ratio: Float) -> Bool {
  case widest_gap(values, 2), descriptive.median(values) {
    Ok(gap), Ok(centre) if centre >. 0.0 -> gap.width /. centre >. ratio
    _, _ -> False
  }
}
