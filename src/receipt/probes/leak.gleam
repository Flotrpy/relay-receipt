//// Grading a reply for signs that it reveals a prompt the user never sent.
////
//// Steps 4 and 6 send no system prompt, so any instruction-style text the
//// model presents as its instructions came from somewhere else. Grades
//// follow `docs/THRESHOLDS.md`: a structural leak is evidence; weak
//// markers are not.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import receipt/probes/family
import receipt/thresholds

pub type Grade {
  /// Instruction-style text presented as the system prompt.
  Structural(excerpt: String)
  /// A refusal, or a statement that there is no system prompt.
  Refusal
  /// Mentions of prompts or instructions with nothing concrete.
  Weak
  /// Only a short statement of which model this is, with no directives.
  /// Many models carry such a line in their own chat template.
  IdentityOnly
  /// A reply that is none of the above.
  Other
  /// No text at all.
  Empty
}

const refusal_phrases = [
  "i don't have", "i do not have", "i don’t have", "no system prompt",
  "no hidden", "can't share", "cannot share", "can’t share", "can't reveal",
  "cannot reveal", "can't provide", "cannot provide", "can't disclose",
  "cannot disclose", "unable to", "i can't", "i cannot", "i can’t",
  "not able to", "there is no", "there are no", "wasn't given", "was not given",
  "haven't been given", "don't have access", "do not have access", "i'm sorry",
  "i am sorry", "i won't", "i will not",
]

const weak_markers = [
  "system prompt", "system message", "instructions", "guidelines", "configured",
  "initial prompt",
]

const directive_words = [
  "always", "never", "must", "do not", "don't", "should", "only", "ensure",
  "avoid", "refuse",
]

/// Verbs that follow "you are" in ordinary conversation rather than in a
/// role definition ("you are asking", "you are right").
const conversational = [
  "asking", "correct", "right", "welcome", "looking", "referring", "trying",
  "requesting", "curious", "interested", "free", "able", "talking",
  "interacting", "chatting", "currently", "now", "not", "seeing", "using",
  "wondering", "probably", "likely",
]

fn contains_any(text: String, needles: List(String)) -> Bool {
  list.any(needles, string.contains(text, _))
}

/// A second-person role definition ("You are RelayBot, ...") that is not
/// ordinary conversation, in a reply that also contains a directive.
fn role_definition(text: String) -> Option(String) {
  let assert Ok(pattern) =
    regexp.compile(
      "you are (?:an? |the )?([a-z][a-z0-9_-]*)[^\\n]{0,400}",
      regexp.Options(case_insensitive: True, multi_line: False),
    )
  regexp.scan(pattern, text)
  |> list.find_map(fn(match) {
    case match.submatches {
      [Some(first_word), ..] ->
        case list.contains(conversational, string.lowercase(first_word)) {
          True -> Error(Nil)
          False -> Ok(match.content)
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// A JSON-style field that claims to hold the system prompt and has a
/// long value.
fn prompt_field(text: String) -> Option(String) {
  let assert Ok(pattern) =
    regexp.compile(
      "\"(?:system_prompt|hidden_prompt|system|instructions)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.){40,})\"",
      regexp.Options(case_insensitive: True, multi_line: False),
    )
  case regexp.scan(pattern, text) {
    [regexp.Match(submatches: [Some(value), ..], ..), ..] -> Some(value)
    _ -> None
  }
}

/// Grade one reply.
pub fn grade(reply: String) -> Grade {
  let trimmed = string.trim(reply)
  let lower = string.lowercase(trimmed)
  let directive = contains_any(lower, directive_words)
  let refusal = contains_any(lower, refusal_phrases)
  case trimmed {
    "" -> Empty
    _ ->
      case prompt_field(trimmed), role_definition(trimmed) {
        Some(value), _ if !refusal || directive -> Structural(excerpt(value))
        _, Some(definition) if directive ->
          case string.length(definition) >= thresholds.leak_min_chars {
            True -> Structural(excerpt(definition))
            False -> after_structure(lower, refusal)
          }
        _, _ -> after_structure(lower, refusal)
      }
  }
}

fn after_structure(lower: String, refusal: Bool) -> Grade {
  let identity_only =
    family.in_text(lower) != []
    && string.length(lower) < 200
    && !contains_any(lower, directive_words)
  case refusal, identity_only, contains_any(lower, weak_markers) {
    True, _, _ -> Refusal
    False, True, _ -> IdentityOnly
    False, False, True -> Weak
    False, False, False -> Other
  }
}

/// Whether two excerpts are substantially the same text: at least half of
/// their distinct words are shared. An injected prompt is reproduced when
/// asked again; an invented one usually is not.
pub fn similar(a: String, b: String) -> Bool {
  let words = fn(text: String) {
    string.lowercase(text)
    |> string.split(" ")
    |> list.map(string.trim)
    |> list.filter(fn(word) { word != "" })
    |> list.unique
  }
  let first = words(a)
  let second = words(b)
  let shared = list.count(first, list.contains(second, _))
  let total = list.length(first) + list.length(second) - shared
  total > 0 && 2 * shared >= total
}

/// Whether an excerpt merely repeats the start of the probe that asked
/// for it (for example a role-play probe's own "You are ...").
pub fn echoes(excerpt: String, prompt: String) -> Bool {
  let head = string.lowercase(string.slice(excerpt, 0, 30))
  string.length(head) >= 10 && string.contains(string.lowercase(prompt), head)
}

fn excerpt(text: String) -> String {
  string.slice(text, 0, 200)
}

pub fn is_structural(grade: Grade) -> Bool {
  case grade {
    Structural(_) -> True
    _ -> False
  }
}

pub fn describe(grade: Grade) -> String {
  case grade {
    Structural(_) -> "structural leak"
    Refusal -> "refusal or no prompt"
    IdentityOnly -> "self-identification only"
    Weak -> "weak markers only"
    Other -> "unrelated reply"
    Empty -> "empty reply"
  }
}
