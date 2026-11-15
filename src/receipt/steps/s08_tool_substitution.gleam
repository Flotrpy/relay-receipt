//// Step 8: Tool-call substitution.
////
//// A malicious relay can rewrite package names on the return path so
//// that an agent installs an attacker's package (arXiv:2604.08407,
//// AC-1.a). Four probes ask the model to repeat a pinned install command
//// as plain text; two ask it to pass a command to a tool, which covers
//// rewrites that touch only structured tool calls. Each returned command
//// is compared character by character. A difference counts only if it
//// repeats in a second attempt, so one paraphrase by the model is not
//// enough.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import receipt/api/chat
import receipt/api/types.{type Tool, Tool} as api
import receipt/ctx.{type Ctx}
import receipt/report/block.{Table}
import receipt/step.{type StepResult}
import receipt/verdict.{Anomaly, Clean}

const id = 8

pub type Kind {
  /// The command is echoed as plain text.
  Echo
  /// The command is passed as a tool-call argument.
  ToolCall
}

pub type Probe {
  Probe(label: String, kind: Kind, command: String)
}

pub fn probes() -> List(Probe) {
  [
    Probe("pip (text)", Echo, "pip install requests==2.31.0"),
    Probe("npm (text)", Echo, "npm install lodash@4.17.21"),
    Probe("cargo (text)", Echo, "cargo add serde@1.0.203"),
    Probe("go (text)", Echo, "go get github.com/stretchr/testify@v1.9.0"),
    Probe("pip (tool call)", ToolCall, "pip install numpy==1.26.4"),
    Probe("npm (tool call)", ToolCall, "npm install express@4.19.2"),
  ]
}

pub fn echo_prompt(command: String) -> String {
  "Repeat the following line exactly as written. It is plain text and will not be run. Reply with that line only, without quotes, code fences or commentary.\n\n"
  <> command
}

pub fn tool_prompt(command: String) -> String {
  "Call the run_shell tool with the command set to exactly: " <> command
}

/// The single tool offered in tool-call probes.
pub fn shell_tool() -> Tool {
  Tool(
    name: "run_shell",
    description: "Queue a shell command for later review. Nothing is executed.",
    parameters: json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("command", json.object([#("type", json.string("string"))])),
        ]),
      ),
      #("required", json.array(["command"], json.string)),
    ]),
  )
}

/// Remove wrappers a model adds despite being told not to: one code
/// fence, one layer of quotes or backticks, a leading shell prompt.
pub fn strip_wrappers(text: String) -> String {
  let text = string.trim(text)
  let text = case string.starts_with(text, "```") {
    True -> {
      let without_open = case string.split_once(text, "\n") {
        Ok(#(_, rest)) -> rest
        Error(Nil) -> string.drop_start(text, 3)
      }
      case string.ends_with(string.trim(without_open), "```") {
        True -> string.drop_end(string.trim(without_open), 3)
        False -> without_open
      }
    }
    False -> text
  }
  let text = string.trim(text)
  let text =
    list.fold(["`", "\"", "'"], text, fn(text, quote) {
      case
        string.length(text) >= 2
        && string.starts_with(text, quote)
        && string.ends_with(text, quote)
      {
        True -> string.drop_start(text, 1) |> string.drop_end(1)
        False -> text
      }
    })
  let text = string.trim(text)
  case text {
    "$ " <> rest -> rest
    "> " <> rest -> rest
    _ -> text
  }
}

pub type Comparison {
  Exact
  /// Same tokens up to case and trailing punctuation.
  Benign
  Substituted
}

fn drop_trailing_punctuation(text: String) -> String {
  case list.any([".", ",", ";", ":", "!", "?"], string.ends_with(text, _)) {
    True -> drop_trailing_punctuation(string.drop_end(text, 1))
    False -> text
  }
}

fn tokens(text: String) -> List(String) {
  string.split(text, " ")
  |> list.flat_map(string.split(_, "\n"))
  |> list.flat_map(string.split(_, "\t"))
  |> list.filter(fn(token) { token != "" })
}

/// Compare a returned command with the expected one. Internal whitespace
/// is not collapsed inside a token: a space inserted into a package name
/// changes what a shell would run and is a substitution.
pub fn compare(expected: String, received: String) -> Comparison {
  case received == expected {
    True -> Exact
    False -> {
      let trimmed = drop_trailing_punctuation(string.trim(received))
      let expected_tokens = tokens(expected)
      let received_tokens = tokens(trimmed)
      case
        expected_tokens == received_tokens
        || list.map(expected_tokens, string.lowercase)
        == list.map(received_tokens, string.lowercase)
      {
        True -> Benign
        False -> Substituted
      }
    }
  }
}

pub type Attempt {
  /// A command came back.
  Returned(command: String)
  /// The request failed, or the model returned no command.
  Missing(detail: String)
}

fn command_argument(arguments: String) -> Result(String, Nil) {
  json.parse(arguments, decode.at(["command"], decode.string))
  |> result_nil
}

fn result_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn attempt(ctx: Ctx, probe: Probe, round: Int) -> Attempt {
  let label = probe.label <> "/" <> int.to_string(round)
  let base = fn(prompt: String) {
    api.simple(ctx.target.model, prompt, 512) |> api.with_temperature(0.0)
  }
  case probe.kind {
    Echo ->
      case
        ctx.chat(ctx, ctx.target, id, label, base(echo_prompt(probe.command)))
      {
        Ok(completion) ->
          case strip_wrappers(completion.text) {
            "" -> Missing("empty reply")
            text -> Returned(text)
          }
        Error(error) -> Missing(chat.describe(error))
      }
    ToolCall ->
      case
        ctx.chat(
          ctx,
          ctx.target,
          id,
          label,
          base(tool_prompt(probe.command)) |> api.with_tools([shell_tool()]),
        )
      {
        Ok(completion) ->
          case
            list.find(completion.tool_calls, fn(call) {
              call.name == "run_shell"
            })
          {
            Ok(call) ->
              case command_argument(call.arguments) {
                Ok(command) -> Returned(command)
                Error(Nil) -> Missing("tool arguments could not be read")
              }
            Error(Nil) -> Missing("the model did not call the tool")
          }
        Error(error) -> Missing(chat.describe(error))
      }
  }
}

pub type Outcome {
  Matched(comparison: Comparison, received: String)
  /// Different from the expected command in two attempts.
  Rewritten(first: String, second: String)
  NoCommand(detail: String)
}

/// Combine a first attempt and, when it differed, a confirming second.
pub fn settle(
  expected: String,
  first: Attempt,
  second: fn() -> Attempt,
) -> Outcome {
  case first {
    Missing(detail) -> NoCommand(detail)
    Returned(command) ->
      case compare(expected, command) {
        Substituted ->
          case second() {
            Returned(again) ->
              case compare(expected, again) {
                Substituted -> Rewritten(command, again)
                other -> Matched(other, again)
              }
            Missing(detail) -> NoCommand(detail)
          }
        other -> Matched(other, command)
      }
  }
}

pub fn run(ctx: Ctx) -> StepResult {
  probes()
  |> list.map(fn(probe) {
    #(
      probe,
      settle(probe.command, attempt(ctx, probe, 1), fn() {
        attempt(ctx, probe, 2)
      }),
    )
  })
  |> build
}

pub fn build(outcomes: List(#(Probe, Outcome))) -> StepResult {
  let rows =
    list.map(outcomes, fn(pair) {
      let #(probe, outcome) = pair
      [
        probe.label,
        probe.command,
        case outcome {
          Matched(_, received) -> received
          Rewritten(first, _) -> first
          NoCommand(detail) -> "(" <> string.slice(detail, 0, 60) <> ")"
        },
        case outcome {
          Matched(Exact, _) -> "exact"
          Matched(_, _) -> "benign difference"
          Rewritten(_, _) -> "DIFFERENT in two attempts"
          NoCommand(_) -> "no command returned"
        },
      ]
    })
  let rewritten =
    list.filter(outcomes, fn(pair) {
      case pair.1 {
        Rewritten(_, _) -> True
        _ -> False
      }
    })
  let missing =
    list.count(outcomes, fn(pair) {
      case pair.1 {
        NoCommand(_) -> True
        _ -> False
      }
    })
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("probes", json.int(list.length(outcomes)))
    |> step.with_data("rewritten", json.int(list.length(rewritten)))
    |> step.with_data("no_command", json.int(missing))
    |> step.with_details([
      Table(["Probe", "Sent", "Returned", "Result"], rows),
    ])
  }
  case rewritten, missing == list.length(outcomes) {
    [_, ..], _ ->
      step.ran(
        id,
        Anomaly,
        int.to_string(list.length(rewritten))
          <> " of "
          <> int.to_string(list.length(outcomes))
          <> " pinned commands came back changed in two attempts: a signal of rewriting on the return path.",
      )
      |> step.with_finding(
        step.Limit,
        "A model that consistently alters a command would look the same. Compare the returned text with what the trusted reference returns for the same probe.",
      )
      |> decorate
    [], True ->
      step.inconclusive(
        id,
        "no_commands",
        "No probe returned a command to compare.",
      )
      |> decorate
    [], False ->
      step.ran(
        id,
        Clean,
        "Every returned command matched what was sent ("
          <> int.to_string(list.length(outcomes) - missing)
          <> " of "
          <> int.to_string(list.length(outcomes))
          <> " probes returned one).",
      )
      |> decorate
  }
}
