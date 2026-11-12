//// The registry of implemented steps.

import gleam/option.{type Option, Some}
import receipt/runner.{type ConnectFn, type StepFn}
import receipt/steps/s01_recon
import receipt/steps/s02_connectivity
import receipt/steps/s03_token_injection

/// Step 2, which also detects the API format.
pub fn connect() -> Option(ConnectFn) {
  Some(s02_connectivity.run)
}

/// Every other implemented step, by number.
pub fn all() -> List(#(Int, StepFn)) {
  [#(1, s01_recon.run), #(3, s03_token_injection.run)]
}
