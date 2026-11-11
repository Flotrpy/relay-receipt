//// The registry of implemented steps.

import gleam/option.{type Option, None}
import receipt/runner.{type ConnectFn, type StepFn}

/// Step 2, which also detects the API format.
pub fn connect() -> Option(ConnectFn) {
  None
}

/// Every other implemented step, by number.
pub fn all() -> List(#(Int, StepFn)) {
  []
}
