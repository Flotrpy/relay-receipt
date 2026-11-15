//// Basic descriptive statistics over lists of floats.
////
//// Functions that are undefined for an empty (or too short) sample return
//// `Error(Nil)` rather than a made-up number.

import gleam/float
import gleam/int
import gleam/list
import gleam/result

pub fn mean(values: List(Float)) -> Result(Float, Nil) {
  case values {
    [] -> Error(Nil)
    _ -> Ok(float.sum(values) /. int.to_float(list.length(values)))
  }
}

/// Unbiased sample variance. Needs at least two values.
pub fn variance(values: List(Float)) -> Result(Float, Nil) {
  case values {
    [] | [_] -> Error(Nil)
    _ -> {
      use centre <- result.try(mean(values))
      let squares =
        list.fold(values, 0.0, fn(total, value) {
          let deviation = value -. centre
          total +. deviation *. deviation
        })
      Ok(squares /. int.to_float(list.length(values) - 1))
    }
  }
}

/// Sample standard deviation. Needs at least two values.
pub fn standard_deviation(values: List(Float)) -> Result(Float, Nil) {
  use spread <- result.try(variance(values))
  float.square_root(spread)
}

/// Standard deviation divided by the mean. Undefined when the mean is not
/// positive.
pub fn coefficient_of_variation(values: List(Float)) -> Result(Float, Nil) {
  use centre <- result.try(mean(values))
  use spread <- result.try(standard_deviation(values))
  case centre >. 0.0 {
    True -> Ok(spread /. centre)
    False -> Error(Nil)
  }
}

pub fn minimum(values: List(Float)) -> Result(Float, Nil) {
  list.reduce(values, float.min)
}

pub fn maximum(values: List(Float)) -> Result(Float, Nil) {
  list.reduce(values, float.max)
}

pub fn sorted(values: List(Float)) -> List(Float) {
  list.sort(values, float.compare)
}

/// The quantile at probability `p` in `[0, 1]`, by linear interpolation
/// between order statistics (the common "type 7" definition).
pub fn quantile(values: List(Float), p: Float) -> Result(Float, Nil) {
  case values, p >=. 0.0 && p <=. 1.0 {
    [], _ | _, False -> Error(Nil)
    _, True -> {
      let ordered = sorted(values)
      let position = p *. int.to_float(list.length(ordered) - 1)
      let lower = float.truncate(float.floor(position))
      let fraction = position -. int.to_float(lower)
      case list.drop(ordered, lower) {
        [low, high, ..] -> Ok(low +. fraction *. { high -. low })
        [low] -> Ok(low)
        [] -> Error(Nil)
      }
    }
  }
}

pub fn median(values: List(Float)) -> Result(Float, Nil) {
  quantile(values, 0.5)
}
