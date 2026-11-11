//// The rank construction of the rank-based uniformity test
//// (arXiv:2506.06975), with a score that needs no model access.
////
//// The paper scores a response by its log-rank under a locally run
//// reference model. Receipt has only a reference API, so it scores each
//// of the `m + 1` responses to a prompt (one from the target, `m` from
//// the reference) against the other `m`. Because every response is
//// treated alike, the scores are exchangeable when target and reference
//// share a distribution, and the randomised rank is then exactly uniform.
//// See `docs/steps/17-identity.md`.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp
import gleam/result
import gleam/string

/// Score given to a response with no words. All empty responses tie.
pub const empty_score = -1.0e9

/// Lower-cased words of a text. Letters and digits form words; everything
/// else separates them.
pub fn words(text: String) -> List(String) {
  let assert Ok(separator) = regexp.from_string("[^\\p{L}\\p{N}]+")
  regexp.split(separator, string.lowercase(text))
  |> list.filter(fn(word) { word != "" })
}

fn tally(words: List(String)) -> Dict(String, Int) {
  list.fold(words, dict.new(), fn(counts, word) {
    dict.upsert(counts, word, fn(existing) {
      case existing {
        Some(count) -> count + 1
        None -> 1
      }
    })
  })
}

/// Leave-one-out scores: for each response, the mean log-probability of
/// its words under an add-one-smoothed unigram model built from all the
/// *other* responses. The vocabulary is that of all responses together.
pub fn leave_one_out_scores(responses: List(String)) -> List(Float) {
  let tokenised = list.map(responses, words)
  let tallies = list.map(tokenised, tally)
  let total_counts =
    list.fold(tallies, dict.new(), fn(total, counts) {
      dict.combine(total, counts, fn(a, b) { a + b })
    })
  let vocabulary = dict.size(total_counts)
  let total_words = list.fold(tokenised, 0, fn(sum, w) { sum + list.length(w) })
  list.zip(tokenised, tallies)
  |> list.map(fn(pair) {
    let #(own_words, own_counts) = pair
    case own_words {
      [] -> empty_score
      _ -> {
        let others_total = total_words - list.length(own_words)
        let denominator = int.to_float(others_total + vocabulary)
        let sum =
          list.fold(own_words, 0.0, fn(sum, word) {
            let everywhere = dict.get(total_counts, word) |> result.unwrap(0)
            let own = dict.get(own_counts, word) |> result.unwrap(0)
            let others = everywhere - own
            sum
            +. {
              float.logarithm(int.to_float(others + 1) /. denominator)
              |> result.unwrap(0.0)
            }
          })
        sum /. int.to_float(list.length(own_words))
      }
    }
  })
}

/// The randomised rank of a target score among `m` reference scores:
/// `(g + u * (t + 1)) / (m + 1)`, where `g` reference scores are below the
/// target's, `t` are equal to it, and `u` is uniform on [0, 1].
pub fn randomised_rank(
  target: Float,
  references: List(Float),
  u: Float,
) -> Float {
  let below = list.count(references, fn(score) { score <. target })
  let equal = list.count(references, fn(score) { score == target })
  { int.to_float(below) +. u *. int.to_float(equal + 1) }
  /. int.to_float(list.length(references) + 1)
}

/// The rank statistic for one prompt.
pub fn rank(target: String, references: List(String), u: Float) -> Float {
  case leave_one_out_scores([target, ..references]) {
    [target_score, ..reference_scores] ->
      randomised_rank(target_score, reference_scores, u)
    [] -> u
  }
}
