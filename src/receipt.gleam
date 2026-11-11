//// Receipt: a local security auditor for AI API relays.
////
//// This module is the command-line entry point. It parses arguments,
//// runs the audit and sets the exit code; all behaviour lives in the
//// `receipt/*` modules so that it can be tested without a process
//// boundary.

import argv
import gleam/io
import gleam/option.{None, Some}
import receipt/app
import receipt/cli.{Audit, Help, Version}
import receipt/config.{type Config}
import receipt/steps
import receipt/verdict
import receipt/version
import simplifile

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

pub fn main() -> Nil {
  case cli.parse(argv.load().arguments) {
    Ok(Help) -> io.print(cli.usage)
    Ok(Version) -> io.println("receipt " <> version.version)
    Ok(Audit(config)) -> audit(config)
    Error(message) -> {
      io.println_error("receipt: " <> message)
      io.println_error("Run 'receipt help' for usage.")
      halt(1)
    }
  }
}

fn audit(config: Config) -> Nil {
  case app.open(config, io.println_error) {
    Error(failure) -> {
      io.println_error("receipt: " <> app.failure_message(failure))
      halt(app.failure_exit_code(failure))
    }
    Ok(session) -> {
      let report = app.run(session, config, steps.connect(), steps.all())
      let text = app.render(report, config.format)
      io.println_error("Rating: " <> verdict.risk_to_string(report.rating.risk))
      case config.output {
        None -> io.print(text)
        Some(path) ->
          case simplifile.write(path, text) {
            Ok(Nil) -> io.println_error("Report written to " <> path)
            Error(error) -> {
              io.println_error(
                "receipt: cannot write "
                <> path
                <> ": "
                <> simplifile.describe_error(error),
              )
              halt(1)
            }
          }
      }
      halt(app.exit_code(report, config.fail_on))
    }
  }
}
