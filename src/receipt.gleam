//// Receipt: a local security auditor for AI API relays.
////
//// This module is the command-line entry point. All behaviour lives in the
//// `receipt/*` modules so that it can be tested without a process boundary.

import gleam/io
import receipt/version

pub fn main() -> Nil {
  io.println("receipt " <> version.version)
}
