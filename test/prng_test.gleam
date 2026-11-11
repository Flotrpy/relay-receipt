import gleam/float
import gleam/int
import gleam/list
import qcheck
import receipt/prng
import receipt/seq

pub fn same_seed_gives_same_sequence_test() {
  let #(a, _) = prng.floats(prng.new(42), 50)
  let #(b, _) = prng.floats(prng.new(42), 50)
  assert a == b
}

pub fn different_seeds_give_different_sequences_test() {
  let #(a, _) = prng.floats(prng.new(1), 10)
  let #(b, _) = prng.floats(prng.new(2), 10)
  assert a != b
}

pub fn known_splitmix64_values_test() {
  // Reference outputs of SplitMix64 for seed 0.
  let #(first, generator) = prng.next(prng.new(0))
  let #(second, generator) = prng.next(generator)
  let #(third, _) = prng.next(generator)
  assert first == 0xE220A8397B1DCDAF
  assert second == 0x6E789E6AA1B965F4
  assert third == 0x06C45D188009454F
}

pub fn floats_are_in_unit_interval_test() {
  use seed <- qcheck.given(qcheck.uniform_int())
  let #(values, _) = prng.floats(prng.new(seed), 20)
  list.each(values, fn(value) {
    assert value >=. 0.0 && value <. 1.0
  })
}

pub fn int_below_is_in_range_test() {
  use #(seed, bound) <- qcheck.given(qcheck.tuple2(
    qcheck.uniform_int(),
    qcheck.bounded_int(1, 1000),
  ))
  let #(value, _) = prng.int_below(prng.new(seed), bound)
  assert value >= 0 && value < bound
}

pub fn int_below_non_positive_bound_is_zero_test() {
  assert prng.int_below(prng.new(7), 0).0 == 0
  assert prng.int_below(prng.new(7), -5).0 == 0
}

pub fn shuffle_is_a_permutation_test() {
  use #(seed, items) <- qcheck.given(qcheck.tuple2(
    qcheck.uniform_int(),
    qcheck.generic_list(
      qcheck.small_non_negative_int(),
      qcheck.bounded_int(0, 30),
    ),
  ))
  let #(shuffled, _) = prng.shuffle(items, prng.new(seed))
  assert list.sort(shuffled, int.compare) == list.sort(items, int.compare)
}

pub fn shuffle_actually_reorders_test() {
  let items = seq.range(1, 50)
  let #(shuffled, _) = prng.shuffle(items, prng.new(3))
  assert shuffled != items
}

pub fn sample_returns_distinct_elements_test() {
  let #(chosen, _) = prng.sample(seq.range(1, 100), 20, prng.new(9))
  assert list.length(chosen) == 20
  assert list.unique(chosen) == chosen
}

pub fn sample_larger_than_list_returns_everything_test() {
  let #(chosen, _) = prng.sample([1, 2, 3], 10, prng.new(9))
  assert list.sort(chosen, int.compare) == [1, 2, 3]
}

pub fn pick_from_empty_list_is_an_error_test() {
  assert prng.pick([], prng.new(1)) == Error(Nil)
}

pub fn forks_with_different_labels_differ_test() {
  let base = prng.new(11)
  let #(a, _) = prng.floats(prng.fork(base, 1), 5)
  let #(b, _) = prng.floats(prng.fork(base, 2), 5)
  assert a != b
}

pub fn fork_does_not_depend_on_other_forks_test() {
  let base = prng.new(11)
  let _ = prng.floats(prng.fork(base, 1), 100)
  let #(a, _) = prng.floats(prng.fork(base, 2), 5)
  let #(b, _) = prng.floats(prng.fork(base, 2), 5)
  assert a == b
}

pub fn uniform_floats_have_mean_near_one_half_test() {
  let #(values, _) = prng.floats(prng.new(2026), 20_000)
  assert float.absolute_value(prng.mean(values) -. 0.5) <. 0.01
}

pub fn each_decile_gets_about_a_tenth_test() {
  let #(values, _) = prng.floats(prng.new(5), 20_000)
  seq.range(0, 9)
  |> list.each(fn(decile) {
    let low = int.to_float(decile) /. 10.0
    let count = list.count(values, fn(v) { v >=. low && v <. low +. 0.1 })
    assert count > 1800 && count < 2200
  })
}
