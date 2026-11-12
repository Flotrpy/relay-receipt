import gleam/int
import gleam/list
import gleam/string
import qcheck
import receipt/cachemap/ladder
import receipt/prng

pub fn nonces_are_24_hex_characters_and_differ_test() {
  let #(first, generator) = ladder.nonce(prng.new(1))
  let #(second, _) = ladder.nonce(generator)
  assert string.length(first) == 24
  assert first != second
  assert string.lowercase(first) == first
}

pub fn padding_is_deterministic_per_nonce_test() {
  assert ladder.padding("abc", 20) == ladder.padding("abc", 20)
  assert ladder.padding("abc", 20) != ladder.padding("abd", 20)
  assert list.length(ladder.padding("abc", 20)) == 20
}

pub fn shorter_prompts_are_true_prefixes_of_longer_ones_test() {
  use #(short, extra) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(1, 300),
    qcheck.bounded_int(1, 300),
  ))
  let long = ladder.prompt("0123456789abcdef01234567", short + extra)
  let prefix = ladder.prompt("0123456789abcdef01234567", short)
  assert string.starts_with(long, prefix)
}

pub fn prompts_with_different_nonces_diverge_early_test() {
  let a = ladder.prompt("aaaaaaaaaaaaaaaaaaaaaaaa", 200)
  let b = ladder.prompt("bbbbbbbbbbbbbbbbbbbbbbbb", 200)
  // They share only the fixed instruction.
  assert string.slice(a, 0, 80) == string.slice(b, 0, 80)
  assert string.slice(a, 0, 140) != string.slice(b, 0, 140)
}

pub fn word_counts_follow_base_and_stride_test() {
  assert ladder.word_counts(1280, 256, 4, 1.0) == [1280, 1536, 1792, 2048]
  assert ladder.word_counts(1280, 256, 2, 2.0) == [640, 768]
  assert ladder.word_counts(100, 10, 3, 1.5) == [67, 74, 80]
  assert ladder.word_counts(100, 10, 0, 1.0) == []
}

pub fn ladder_is_built_shortest_first_test() {
  let prompts = ladder.build("0123456789abcdef01234567", [10, 20, 30])
  let lengths = list.map(prompts, string.length)
  assert lengths == list.sort(lengths, int.compare)
  assert list.length(prompts) == 3
}

pub fn hit_test_allows_one_chunk_of_slack_test() {
  assert ladder.is_hit(2000, 1920, 128)
  assert ladder.is_hit(2000, 1872, 128)
  assert !ladder.is_hit(2000, 1871, 128)
  assert !ladder.is_hit(2000, 0, 128)
  assert !ladder.is_hit(100, 0, 128)
}

pub fn state_from_a_miss_cannot_satisfy_the_next_step_test() {
  // A miss at step l caches at most tokens(l). With a stride of two
  // chunks, step l + 1 needs more than that.
  let chunk = 128
  let stride = 2 * chunk
  let step = 1280
  assert !ladder.is_hit(step + stride, step, chunk)
}
