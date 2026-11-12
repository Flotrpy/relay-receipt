//// Model families, as named in model identifiers and in a model's own
//// description of itself.
////
//// A model's self-description is a consistency signal only. Models
//// misreport their identity, and a relay can make a model say anything.
//// Receipt therefore never treats a mismatch here as an anomaly on its
//// own; see Step 5 in `docs/THRESHOLDS.md`.

import gleam/list
import gleam/regexp
import gleam/string

/// `#(family, words found in self-descriptions, fragments of model ids)`.
const families = [
  #("openai", ["openai", "chatgpt", "gpt"], [
    "gpt",
    "openai",
    "o1-",
    "o3-",
    "o4-",
  ]),
  #("anthropic", ["anthropic", "claude"], ["claude", "anthropic"]),
  #("google", ["google", "gemini", "gemma", "bard"], ["gemini", "gemma"]),
  #("meta", ["meta", "llama"], ["llama"]),
  #("alibaba", ["alibaba", "qwen", "tongyi", "通义", "千问"], ["qwen"]),
  #("deepseek", ["deepseek"], ["deepseek"]),
  #("mistral", ["mistral", "mixtral", "codestral"], [
    "mistral",
    "mixtral",
    "codestral",
    "ministral",
  ]),
  #("moonshot", ["moonshot", "kimi"], ["moonshot", "kimi"]),
  #("zhipu", ["zhipu", "glm", "chatglm", "智谱"], ["glm"]),
  #("xai", ["xai", "grok"], ["grok"]),
  #("minimax", ["minimax"], ["minimax", "abab"]),
  #("baidu", ["baidu", "ernie", "文心"], ["ernie"]),
  #("bytedance", ["bytedance", "doubao", "豆包"], ["doubao"]),
  #("cohere", ["cohere"], ["command-r", "cohere"]),
  #("microsoft", ["microsoft", "phi"], ["phi-"]),
  #("amazon", ["amazon", "aws", "titan", "nova"], ["titan", "nova-"]),
  #("sdaia", ["sdaia", "allam"], ["allam"]),
]

fn is_ascii_word(word: String) -> Bool {
  let assert Ok(pattern) = regexp.from_string("^[a-z0-9]+$")
  regexp.check(pattern, word)
}

/// Whether a word occurs in a text as a whole word (for ASCII words) or as
/// a substring (for other scripts).
fn mentions(lower_text: String, word: String) -> Bool {
  case is_ascii_word(word) {
    False -> string.contains(lower_text, word)
    True -> {
      let assert Ok(pattern) =
        regexp.from_string("(^|[^a-z0-9])" <> word <> "($|[^a-z])")
      regexp.check(pattern, lower_text)
    }
  }
}

/// The families a self-description names, in catalogue order.
pub fn in_text(text: String) -> List(String) {
  let lower = string.lowercase(text)
  list.filter_map(families, fn(family) {
    case list.any(family.1, mentions(lower, _)) {
      True -> Ok(family.0)
      False -> Error(Nil)
    }
  })
}

/// The family a model identifier belongs to, if recognised. The first
/// matching family wins.
pub fn of_model(model: String) -> Result(String, Nil) {
  let lower = string.lowercase(model)
  list.find_map(families, fn(family) {
    case list.any(family.2, string.contains(lower, _)) {
      True -> Ok(family.0)
      False -> Error(Nil)
    }
  })
}

pub type Consistency {
  /// The self-description names the claimed model's family.
  Consistent(family: String)
  /// It names other families and not the claimed one.
  Conflict(claimed: String, reported: List(String))
  /// The model id is not recognised, or the reply names no family.
  Unknown
}

/// Compare a claimed model id with a self-description.
pub fn compare(model: String, self_description: String) -> Consistency {
  case of_model(model), in_text(self_description) {
    Error(Nil), _ | _, [] -> Unknown
    Ok(claimed), reported ->
      case list.contains(reported, claimed) {
        True -> Consistent(claimed)
        False -> Conflict(claimed, reported)
      }
  }
}
