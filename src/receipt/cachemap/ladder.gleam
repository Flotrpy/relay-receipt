//// Fresh prompts and their prefix ladder.
////
//// A prompt is a fixed instruction, a nonce never used before, and
//// padding words drawn from a stream seeded by the nonce. Cutting the
//// padding earlier gives a true string prefix, so the ladder
//// `P[1] ⊂ P[2] ⊂ ... ⊂ P[L]` needs no extra requests to plant.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import receipt/prng.{type Prng}
import receipt/seq

const instruction =
  "Reply with exactly OK and nothing else. The lines below are padding and carry no request."

const vocabulary = [
  "amber", "basin", "cedar", "delta", "ember", "fable", "grove", "harbor",
  "inlet", "jetty", "kernel", "ledger", "meadow", "nectar", "orbit", "pebble",
  "quarry", "ripple", "saddle", "timber", "upland", "valley", "willow", "yonder",
  "zenith", "anchor", "beacon", "candle", "dapple", "eddy", "fennel", "garnet",
]

/// A nonce: 24 hexadecimal characters from the generator.
pub fn nonce(prng: Prng) -> #(String, Prng) {
  let #(high, prng) = prng.int_below(prng, 0xFFFFFFFFFFFF)
  let #(low, prng) = prng.int_below(prng, 0xFFFFFFFFFFFF)
  let hex = fn(value: Int) {
    string.pad_start(string.lowercase(int.to_base16(value)), 12, "0")
  }
  #(hex(high) <> hex(low), prng)
}

fn seed_of(nonce: String) -> Int {
  string.to_utf_codepoints(nonce)
  |> list.fold(0, fn(hash, codepoint) {
    { hash * 131 + string.utf_codepoint_to_int(codepoint) } % 0xFFFFFFFFFFFF
  })
}

/// The first `count` padding words for a nonce. A longer request returns
/// the same words followed by more.
pub fn padding(nonce: String, count: Int) -> List(String) {
  let size = list.length(vocabulary)
  seq.range(1, count)
  |> list.fold(#([], prng.new(seed_of(nonce))), fn(acc, _) {
    let #(words, generator) = acc
    let #(index, generator) = prng.int_below(generator, size)
    let word = seq.at(vocabulary, index)
    #(
      [
        case word {
          Ok(word) -> word
          Error(Nil) -> "amber"
        },
        ..words
      ],
      generator,
    )
  })
  |> fn(pair) { list.reverse(pair.0) }
}

/// The prompt with `count` padding words.
pub fn prompt(nonce: String, count: Int) -> String {
  instruction
  <> "\nreference "
  <> nonce
  <> "\n"
  <> string.join(padding(nonce, count), " ")
}

/// Padding word counts for a ladder whose steps are `base_tokens`,
/// `base_tokens + stride_tokens`, ... given how many tokens one padding
/// word costs on the endpoint that will be probed.
pub fn word_counts(
  base_tokens: Int,
  stride_tokens: Int,
  steps: Int,
  tokens_per_word: Float,
) -> List(Int) {
  let per_word = float.max(tokens_per_word, 0.1)
  seq.range(0, steps - 1)
  |> list.map(fn(step) {
    float.truncate(float.ceiling(
      int.to_float(base_tokens + step * stride_tokens) /. per_word,
    ))
  })
}

/// The ladder for a nonce: one prompt per word count, shortest first.
pub fn build(nonce: String, counts: List(Int)) -> List(String) {
  list.map(counts, prompt(nonce, _))
}

/// The hit test of the paper: the reported cached prefix reaches to
/// within one cache chunk of the prompt's length.
pub fn is_hit(prompt_tokens: Int, cached_tokens: Int, chunk: Int) -> Bool {
  cached_tokens > 0 && cached_tokens >= prompt_tokens - chunk
}
