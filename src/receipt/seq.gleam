//// Small list helpers that the standard library does not provide.

import gleam/list

/// The integers from `from` to `to`, both inclusive, ascending. Empty when
/// `from` is greater than `to`.
pub fn range(from from: Int, to to: Int) -> List(Int) {
  range_loop(from, to, [])
}

fn range_loop(from: Int, current: Int, acc: List(Int)) -> List(Int) {
  case current < from {
    True -> acc
    False -> range_loop(from, current - 1, [current, ..acc])
  }
}

/// Pair each element with its zero-based position.
pub fn indexed(items: List(a)) -> List(#(Int, a)) {
  list.index_map(items, fn(item, index) { #(index, item) })
}

/// The element at a zero-based position.
pub fn at(items: List(a), index: Int) -> Result(a, Nil) {
  case index < 0 {
    True -> Error(Nil)
    False -> list.first(list.drop(items, index))
  }
}
