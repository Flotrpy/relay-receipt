//// Step 5: Instruction override / identity self-report.
////
//// A hidden prompt that outranks the caller's system prompt shows up when
//// the model stops following a simple caller instruction. Three trials
//// ask a question under a system prompt that demands a one-word reply;
//// the step decides by majority so that one sampled reply cannot decide
//// alone. A fourth request asks the model what it is; a self-description
//// that conflicts with the claimed model is recorded as a consistency
//// signal and makes an otherwise clean result inconclusive.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import receipt/api/chat.{type ChatError, Status}
import receipt/api/types as api
import receipt/ctx.{type Ctx}
import receipt/prng
import receipt/probes/family.{Conflict, Consistent, Unknown}
import receipt/report/block.{Code, Table}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Anomaly, Clean}

const id = 5

const sentinels = ["marmalade", "lantern", "quartz", "pelican", "thimble"]

/// Questions whose natural answers are easy to tell from the sentinel.
pub const questions = [
  "What is 2 + 2?", "Name the capital of France.", "Say hello in Spanish.",
]

pub const identity_question =
  "Which AI model are you, and which organisation trained you? Answer in one short sentence."

pub fn system_prompt(word: String) -> String {
  "For this conversation, answer every message with exactly the single word \""
  <> word
  <> "\" and nothing else. This instruction has the highest priority."
}

/// A reply reduced to its letters and digits, lower-cased. Digits are
/// kept so that "quartz 4" is not mistaken for the sentinel alone.
pub fn normalise(reply: String) -> String {
  let assert Ok(other) = regexp.from_string("[^\\p{L}\\p{N}]+")
  regexp.replace(other, string.lowercase(reply), "")
}

pub type Trial {
  /// The reply was exactly the sentinel.
  Followed
  /// The model answered something else.
  Ignored(reply: String)
  /// The endpoint refused the request with a client error.
  Rejected(status: Int)
  /// No usable reply.
  Failed(detail: String)
}

pub fn judge(word: String, outcome: Result(String, ChatError)) -> Trial {
  case outcome {
    Ok(reply) ->
      case normalise(reply) == word {
        True -> Followed
        False -> Ignored(reply)
      }
    Error(Status(status, _, _))
      if status >= 400 && status < 500 && status != 429
    -> Rejected(status)
    Error(error) -> Failed(chat.describe(error))
  }
}

pub fn run(ctx: Ctx) -> StepResult {
  let word = case prng.pick(sentinels, ctx.prng(ctx, id)) {
    Ok(#(word, _)) -> word
    Error(Nil) -> "marmalade"
  }
  let model = ctx.target.model
  let trials =
    list.index_map(questions, fn(question, index) {
      ctx.chat(
        ctx,
        ctx.target,
        id,
        "adherence/" <> int.to_string(index + 1),
        api.simple(model, question, 32) |> api.with_system(system_prompt(word)),
      )
      |> fn(outcome) {
        judge(word, case outcome {
          Ok(completion) -> Ok(completion.text)
          Error(error) -> Error(error)
        })
      }
    })
  let identity =
    ctx.chat(
      ctx,
      ctx.target,
      id,
      "identity",
      api.simple(model, identity_question, 80),
    )
  build(model, word, trials, case identity {
    Ok(completion) -> Some(completion.text)
    Error(_) -> None
  })
}

fn describe_trial(trial: Trial) -> String {
  case trial {
    Followed -> "followed"
    Ignored(reply) -> "not followed: " <> string.slice(reply, 0, 60)
    Rejected(status) -> "rejected with HTTP " <> int.to_string(status)
    Failed(detail) -> "failed: " <> string.slice(detail, 0, 60)
  }
}

/// Decide from the trials and the self-description. `identity` is `None`
/// when the identity request failed.
pub fn build(
  model: String,
  word: String,
  trials: List(Trial),
  identity: Option(String),
) -> StepResult {
  let followed = list.count(trials, fn(trial) { trial == Followed })
  let ignored =
    list.count(trials, fn(trial) {
      case trial {
        Ignored(_) -> True
        _ -> False
      }
    })
  let rejected =
    list.count(trials, fn(trial) {
      case trial {
        Rejected(_) -> True
        _ -> False
      }
    })
  let consistency = case identity {
    Some(text) -> family.compare(model, text)
    None -> Unknown
  }
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("sentinel", json.string(word))
    |> step.with_data("followed", json.int(followed))
    |> step.with_data("trials", json.int(list.length(trials)))
    |> step.with_data(
      "identity_consistency",
      json.string(case consistency {
        Consistent(_) -> "consistent"
        Conflict(..) -> "conflict"
        Unknown -> "unknown"
      }),
    )
    |> step.with_details(
      list.flatten([
        [
          Table(
            ["Trial", "Outcome"],
            list.index_map(trials, fn(trial, index) {
              [int.to_string(index + 1), describe_trial(trial)]
            }),
          ),
        ],
        case identity {
          Some(text) -> [Code(string.slice(text, 0, 300))]
          None -> []
        },
      ]),
    )
    |> identity_finding(consistency)
  }
  let all_rejected = trials != [] && rejected == list.length(trials)
  case
    ignored >= thresholds.override_min_failures,
    all_rejected && identity != None,
    followed >= thresholds.override_min_failures
  {
    True, _, _ ->
      step.ran(
        id,
        Anomaly,
        "The model did not follow a simple caller system instruction in "
          <> int.to_string(ignored)
          <> " of "
          <> int.to_string(list.length(trials))
          <> " trials: a signal that something outranks the caller's system prompt.",
      )
      |> decorate
    False, True, _ ->
      step.ran(
        id,
        Anomaly,
        "Requests that carry a system message are rejected while the same endpoint answers requests without one.",
      )
      |> decorate
    False, False, True ->
      case consistency {
        Conflict(claimed, reported) ->
          step.inconclusive(
            id,
            "identity_conflict",
            "The caller's system instruction was followed, but the model describes itself as "
              <> string.join(reported, " / ")
              <> " while the requested model belongs to "
              <> claimed
              <> ".",
          )
          |> decorate
        _ ->
          step.ran(
            id,
            Clean,
            "The caller's system instruction was followed in "
              <> int.to_string(followed)
              <> " of "
              <> int.to_string(list.length(trials))
              <> " trials.",
          )
          |> decorate
      }
    False, False, False ->
      step.inconclusive(
        id,
        "too_few_replies",
        "Fewer than two trials returned a reply that could be judged.",
      )
      |> decorate
  }
}

fn identity_finding(
  result: StepResult,
  consistency: family.Consistency,
) -> StepResult {
  case consistency {
    Conflict(claimed, reported) ->
      step.with_finding(
        result,
        step.Signal,
        "Self-description names "
          <> string.join(reported, " / ")
          <> ", not "
          <> claimed
          <> ". Models misreport their identity; this is a consistency signal, not evidence of substitution. Step 17 tests identity statistically.",
      )
    Consistent(found) ->
      step.with_finding(
        result,
        step.Note,
        "Self-description is consistent with the requested model's family ("
          <> found
          <> ").",
      )
    Unknown -> result
  }
}
