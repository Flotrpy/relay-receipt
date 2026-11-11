import gleam/float
import gleam/int
import gleam/list
import qcheck
import receipt/prng
import receipt/seq
import receipt/stats/holm
import support/close

fn all_close(actual: List(Float), expected: List(Float)) -> Bool {
  list.length(actual) == list.length(expected)
  && list.all(list.zip(actual, expected), fn(pair) {
    close.to(pair.0, pair.1, 1.0e-12)
  })
}

pub fn textbook_example_test() {
  // Sorted: 0.01*4, 0.02*3, 0.03*2, 0.04*1 -> 0.04, 0.06, 0.06, 0.06.
  assert all_close(holm.adjust([0.01, 0.04, 0.03, 0.02]), [
    0.04, 0.06, 0.06, 0.06,
  ])
}

pub fn order_of_inputs_is_preserved_test() {
  assert all_close(holm.adjust([0.5, 0.001, 0.2]), [0.5, 0.003, 0.4])
}

pub fn adjusted_values_are_capped_at_one_test() {
  assert holm.adjust([0.6, 0.7, 0.9]) == [1.0, 1.0, 1.0]
}

pub fn single_and_empty_inputs_test() {
  assert holm.adjust([0.03]) == [0.03]
  assert holm.adjust([]) == []
}

pub fn reject_applies_the_family_wise_level_test() {
  assert holm.reject([0.01, 0.04, 0.03, 0.02], 0.05)
    == [True, False, False, False]
  assert holm.reject([0.001, 0.002, 0.9], 0.05) == [True, True, False]
}

fn p_values() {
  qcheck.generic_list(qcheck.bounded_float(0.0, 1.0), qcheck.bounded_int(1, 25))
}

pub fn adjusted_is_never_below_raw_and_never_above_one_test() {
  use raw <- qcheck.given(p_values())
  list.zip(raw, holm.adjust(raw))
  |> list.each(fn(pair) {
    assert pair.1 >=. pair.0 -. 1.0e-12
    assert pair.1 <=. 1.0
  })
}

pub fn adjustment_preserves_the_ranking_test() {
  use raw <- qcheck.given(p_values())
  let adjusted = holm.adjust(raw)
  list.zip(raw, adjusted)
  |> list.each(fn(a) {
    list.zip(raw, adjusted)
    |> list.each(fn(b) {
      case a.0 <. b.0 {
        True -> {
          assert a.1 <=. b.1 +. 1.0e-12
        }
        False -> Nil
      }
    })
  })
}

pub fn holm_is_never_more_conservative_than_bonferroni_test() {
  use raw <- qcheck.given(p_values())
  let count = list.length(raw)
  list.zip(raw, holm.adjust(raw))
  |> list.each(fn(pair) {
    let bonferroni = float.min(1.0, pair.0 *. int.to_float(count))
    assert pair.1 <=. bonferroni +. 1.0e-12
  })
}

pub fn family_wise_error_is_controlled_under_the_global_null_test() {
  // 2000 families of 10 independent uniform p-values. The share of
  // families with any rejection at 0.05 must be about 0.05 or less.
  let families = 2000
  let #(false_alarms, _) =
    seq.range(1, families)
    |> list.fold(#(0, prng.new(20_261_110)), fn(acc, _) {
      let #(alarms, generator) = acc
      let #(raw, generator) = prng.floats(generator, 10)
      case list.any(holm.reject(raw, 0.05), fn(rejected) { rejected }) {
        True -> #(alarms + 1, generator)
        False -> #(alarms, generator)
      }
    })
  // Expected 100; three standard errors above is about 130.
  assert false_alarms < 130
  assert false_alarms > 60
}
