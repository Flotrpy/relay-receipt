//// Float comparison for tests.

import gleam/float

/// Whether two floats agree to within an absolute tolerance.
pub fn to(actual: Float, expected: Float, tolerance: Float) -> Bool {
  float.absolute_value(actual -. expected) <=. tolerance
}

/// As `to`, for a result that must be `Ok`.
pub fn ok_to(
  actual: Result(Float, Nil),
  expected: Float,
  tolerance: Float,
) -> Bool {
  case actual {
    Ok(value) -> to(value, expected, tolerance)
    Error(Nil) -> False
  }
}
