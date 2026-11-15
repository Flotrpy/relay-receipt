//// The standard normal distribution: CDF and quantile function.

import gleam/float
import gleam/result

@external(erlang, "math", "erfc")
fn erfc(x: Float) -> Float

const sqrt_two = 1.4142135623730951

const sqrt_two_pi = 2.5066282746310002

/// P(Z <= x) for a standard normal Z.
pub fn cdf(x: Float) -> Float {
  0.5 *. erfc(0.0 -. x /. sqrt_two)
}

fn density(x: Float) -> Float {
  float.exponential(-0.5 *. x *. x) /. sqrt_two_pi
}

fn ln(x: Float) -> Float {
  float.logarithm(x) |> result.unwrap(0.0)
}

fn sqrt(x: Float) -> Float {
  float.square_root(x) |> result.unwrap(0.0)
}

/// The value x with P(Z <= x) = p, for p strictly between 0 and 1.
///
/// Acklam's rational approximation followed by one Halley step, which
/// brings the error near machine precision.
pub fn quantile(p: Float) -> Result(Float, Nil) {
  case p >. 0.0 && p <. 1.0 {
    False -> Error(Nil)
    True -> {
      let x = acklam(p)
      let error = cdf(x) -. p
      let u = error /. density(x)
      Ok(x -. u /. { 1.0 +. x *. u /. 2.0 })
    }
  }
}

fn acklam(p: Float) -> Float {
  let low = 0.02425
  case p <. low, p >. 1.0 -. low {
    True, _ -> {
      let q = sqrt(-2.0 *. ln(p))
      tail(q)
    }
    _, True -> {
      let q = sqrt(-2.0 *. ln(1.0 -. p))
      0.0 -. tail(q)
    }
    False, False -> {
      let q = p -. 0.5
      let r = q *. q
      let numerator =
        {
          {
            {
              {
                { -39.69683028665376 *. r +. 220.9460984245205 }
                *. r
                -. 275.9285104469687
              }
              *. r
              +. 138.357751867269
            }
            *. r
            -. 30.66479806614716
          }
          *. r
          +. 2.506628277459239
        }
        *. q
      let denominator =
        {
          {
            {
              { -54.47609879822406 *. r +. 161.5858368580409 }
              *. r
              -. 155.6989798598866
            }
            *. r
            +. 66.80131188771972
          }
          *. r
          -. 13.28068155288572
        }
        *. r
        +. 1.0
      numerator /. denominator
    }
  }
}

fn tail(q: Float) -> Float {
  let numerator =
    {
      {
        {
          { -0.007784894002430293 *. q -. 0.3223964580411365 }
          *. q
          -. 2.400758277161838
        }
        *. q
        -. 2.549732539343734
      }
      *. q
      +. 4.374664141464968
    }
    *. q
    +. 2.938163982698783
  let denominator =
    {
      {
        { 0.007784695709041462 *. q +. 0.3224671290700398 }
        *. q
        +. 2.445134137142996
      }
      *. q
      +. 3.754408661907416
    }
    *. q
    +. 1.0
  numerator /. denominator
}
