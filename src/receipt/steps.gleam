//// The registry of implemented steps.

import gleam/option.{type Option, Some}
import receipt/runner.{type ConnectFn, type StepFn}
import receipt/steps/s01_recon
import receipt/steps/s02_connectivity
import receipt/steps/s03_token_injection
import receipt/steps/s04_prompt_extraction
import receipt/steps/s05_override
import receipt/steps/s06_jailbreak
import receipt/steps/s07_context
import receipt/steps/s08_tool_substitution
import receipt/steps/s09_error_leakage
import receipt/steps/s10_stream
import receipt/steps/s12_fingerprint
import receipt/steps/s13_latency

/// Step 2, which also detects the API format.
pub fn connect() -> Option(ConnectFn) {
  Some(s02_connectivity.run)
}

/// Every other implemented step, by number.
pub fn all() -> List(#(Int, StepFn)) {
  [
    #(1, s01_recon.run),
    #(3, s03_token_injection.run),
    #(4, s04_prompt_extraction.run),
    #(5, s05_override.run),
    #(6, s06_jailbreak.run),
    #(7, s07_context.run),
    #(8, s08_tool_substitution.run),
    #(9, s09_error_leakage.run),
    #(10, s10_stream.run),
    #(12, s12_fingerprint.run),
    #(13, s13_latency.run),
  ]
}
