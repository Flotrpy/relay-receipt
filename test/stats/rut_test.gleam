import gleam/int
import gleam/list
import gleam/string
import receipt/prng.{type Prng}
import receipt/seq
import receipt/stats/cvm
import receipt/stats/rut
import support/close

pub fn cvm_statistic_of_perfectly_spaced_values_is_minimal_test() {
  // Values at (2i-1)/(2n) give exactly 1/(12n).
  assert close.to(
    cvm.statistic([0.125, 0.375, 0.625, 0.875]),
    1.0 /. 48.0,
    1.0e-12,
  )
  assert cvm.statistic([]) == 0.0
}

pub fn cvm_statistic_known_value_test() {
  // n = 2, values 0.1 and 0.2: 1/24 + (0.25-0.1)^2 + (0.75-0.2)^2.
  assert close.to(
    cvm.statistic([0.2, 0.1]),
    1.0 /. 24.0 +. 0.0225 +. 0.3025,
    1.0e-12,
  )
}

pub fn cvm_rejects_values_piled_at_one_end_test() {
  let piled = list.repeat(0.02, 10)
  let #(result, _) = cvm.uniformity_test(piled, 999, prng.new(1))
  assert result.p_value <. 0.01
}

pub fn cvm_accepts_evenly_spread_values_test() {
  let spread = [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]
  let #(result, _) = cvm.uniformity_test(spread, 999, prng.new(1))
  assert result.p_value >. 0.9
}

pub fn cvm_p_values_are_valid_for_uniform_data_test() {
  let #(p_values, _) =
    seq.range(1, 500)
    |> list.fold(#([], prng.new(2026)), fn(acc, _) {
      let #(p_values, generator) = acc
      let #(values, generator) = prng.floats(generator, 10)
      let #(result, generator) = cvm.uniformity_test(values, 199, generator)
      #([result.p_value, ..p_values], generator)
    })
  let share = fn(level: Float) {
    int.to_float(list.count(p_values, fn(p) { p <=. level })) /. 500.0
  }
  assert share(0.05) <. 0.085
  assert share(0.05) >. 0.02
  assert close.to(share(0.5), 0.5, 0.08)
}

pub fn words_are_lower_cased_and_split_on_punctuation_test() {
  assert rut.words("Hello, World! It's 42.")
    == ["hello", "world", "it", "s", "42"]
  assert rut.words("  ") == []
  assert rut.words("Zürich-Ost") == ["zürich", "ost"]
}

pub fn leave_one_out_scores_have_one_entry_per_response_test() {
  let scores = rut.leave_one_out_scores(["the cat", "the dog", "a fish"])
  assert list.length(scores) == 3
}

pub fn a_response_sharing_words_with_the_others_scores_higher_test() {
  let assert [typical, odd, ..] =
    rut.leave_one_out_scores([
      "the cat sat", "zebra quantum flux", "the cat sat down", "the cat sat",
      "a cat sat",
    ])
  assert typical >. odd
}

pub fn identical_responses_get_identical_scores_test() {
  let assert [a, b, c] =
    rut.leave_one_out_scores(["same text", "same text", "same text"])
  assert a == b && b == c
}

pub fn empty_responses_get_the_floor_score_test() {
  assert rut.leave_one_out_scores(["", "words here", "..."])
    |> list.filter(fn(score) { score == rut.empty_score })
    |> list.length
    == 2
}

pub fn scores_do_not_depend_on_response_order_test() {
  let responses = ["alpha beta", "beta gamma", "gamma delta", "alpha alpha"]
  let forward = rut.leave_one_out_scores(responses)
  let backward = rut.leave_one_out_scores(list.reverse(responses))
  assert list.zip(forward, list.reverse(backward))
    |> list.all(fn(pair) { close.to(pair.0, pair.1, 1.0e-12) })
}

pub fn randomised_rank_known_values_test() {
  // Two of four references below, none equal: (2 + u) / 5.
  assert close.to(
    rut.randomised_rank(0.5, [0.1, 0.2, 0.8, 0.9], 0.0),
    0.4,
    1.0e-12,
  )
  assert close.to(
    rut.randomised_rank(0.5, [0.1, 0.2, 0.8, 0.9], 1.0),
    0.6,
    1.0e-12,
  )
  // All four tie with the target: u spreads over the whole interval.
  assert close.to(
    rut.randomised_rank(1.0, [1.0, 1.0, 1.0, 1.0], 0.3),
    0.3,
    1.0e-12,
  )
  // No references: the rank is u.
  assert rut.randomised_rank(1.0, [], 0.7) == 0.7
}

pub fn rank_is_always_in_the_unit_interval_test() {
  seq.range(0, 10)
  |> list.each(fn(step) {
    let u = int.to_float(step) /. 10.0
    let rank = rut.rank("a b c", ["a b", "c d", "x y z"], u)
    assert rank >=. 0.0 && rank <=. 1.0
  })
}

const common_words = [
  "the",
  "a",
  "of",
  "to",
  "and",
  "is",
  "in",
  "it",
  "you",
  "that",
]

const rare_words = [
  "zinc",
  "quark",
  "fjord",
  "onyx",
  "lynx",
  "waltz",
  "vex",
  "jib",
  "gnu",
  "ohm",
]

fn sentence(pool: List(String), generator: Prng) -> #(String, Prng) {
  let #(words, generator) =
    seq.range(1, 6)
    |> list.fold(#([], generator), fn(acc, _) {
      let #(words, generator) = acc
      let assert Ok(#(word, generator)) = prng.pick(pool, generator)
      #([word, ..words], generator)
    })
  #(string.join(words, " "), generator)
}

fn simulated_ranks(
  count: Int,
  target_pool: List(String),
  seed: Int,
) -> List(Float) {
  let #(ranks, _) =
    seq.range(1, count)
    |> list.fold(#([], prng.new(seed)), fn(acc, _) {
      let #(ranks, generator) = acc
      let #(target, generator) = sentence(target_pool, generator)
      let #(references, generator) =
        seq.range(1, 10)
        |> list.fold(#([], generator), fn(inner, _) {
          let #(references, generator) = inner
          let #(reference, generator) = sentence(common_words, generator)
          #([reference, ..references], generator)
        })
      let #(u, generator) = prng.float(generator)
      #([rut.rank(target, references, u), ..ranks], generator)
    })
  ranks
}

pub fn ranks_are_uniform_when_target_and_reference_share_a_distribution_test() {
  let ranks = simulated_ranks(3000, common_words, 11)
  seq.range(0, 9)
  |> list.each(fn(decile) {
    let low = int.to_float(decile) /. 10.0
    let count = list.count(ranks, fn(r) { r >=. low && r <. low +. 0.1 })
    // Expected 300 per decile; five standard errors is about 82.
    assert count > 218 && count < 382
  })
  let #(result, _) = cvm.uniformity_test(ranks, 199, prng.new(5))
  assert result.p_value >. 0.01
}

pub fn ranks_pile_up_low_when_the_target_uses_different_words_test() {
  let ranks = simulated_ranks(40, rare_words, 13)
  let #(result, _) = cvm.uniformity_test(ranks, 999, prng.new(5))
  assert result.p_value <. 0.01
  let low = list.count(ranks, fn(r) { r <. 0.2 })
  assert low > 30
}
