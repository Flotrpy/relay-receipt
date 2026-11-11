//// A small seeded pseudo-random generator (SplitMix64).
////
//// Receipt never uses the runtime's global random source for anything
//// that affects a result. Shuffles, permutation tests and randomised
//// tie-breaks take a `Prng` so that a replayed trace reproduces the same
//// numbers. This generator is for reproducibility, not for secrets.

import gleam/float
import gleam/int
import gleam/list

const mask64 = 0xFFFFFFFFFFFFFFFF

const golden_gamma = 0x9E3779B97F4A7C15

pub opaque type Prng {
  Prng(state: Int)
}

/// A generator seeded with any integer.
pub fn new(seed: Int) -> Prng {
  Prng(int.bitwise_and(seed, mask64))
}

/// The next 64-bit value and the advanced generator.
pub fn next(prng: Prng) -> #(Int, Prng) {
  let state = int.bitwise_and(prng.state + golden_gamma, mask64)
  #(mix(state), Prng(state))
}

fn mix(z: Int) -> Int {
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask64,
    )
  int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
}

/// An independent generator derived from this one and a label. Lets each
/// step, batch or probe have its own stream regardless of the order in
/// which other streams are consumed.
pub fn fork(prng: Prng, label: Int) -> Prng {
  Prng(mix(int.bitwise_and(prng.state + golden_gamma * { label + 1 }, mask64)))
}

/// A float uniform on `[0, 1)`.
pub fn float(prng: Prng) -> #(Float, Prng) {
  let #(bits, prng) = next(prng)
  // Top 53 bits, the precision of a double.
  let top = int.bitwise_shift_right(bits, 11)
  #(int.to_float(top) /. 9_007_199_254_740_992.0, prng)
}

/// An integer uniform on `[0, bound)`. `bound` below 1 gives 0.
pub fn int_below(prng: Prng, bound: Int) -> #(Int, Prng) {
  case bound < 1 {
    True -> #(0, prng)
    False -> {
      // Rejection sampling removes modulo bias.
      let limit = mask64 + 1 - { mask64 + 1 } % bound
      draw_below(prng, bound, limit)
    }
  }
}

fn draw_below(prng: Prng, bound: Int, limit: Int) -> #(Int, Prng) {
  let #(value, prng) = next(prng)
  case value < limit {
    True -> #(value % bound, prng)
    False -> draw_below(prng, bound, limit)
  }
}

/// `count` floats uniform on `[0, 1)`.
pub fn floats(prng: Prng, count: Int) -> #(List(Float), Prng) {
  floats_loop(prng, count, [])
}

fn floats_loop(
  prng: Prng,
  count: Int,
  acc: List(Float),
) -> #(List(Float), Prng) {
  case count <= 0 {
    True -> #(list.reverse(acc), prng)
    False -> {
      let #(value, prng) = float(prng)
      floats_loop(prng, count - 1, [value, ..acc])
    }
  }
}

/// A uniformly random permutation of the list.
pub fn shuffle(items: List(a), prng: Prng) -> #(List(a), Prng) {
  let #(keyed, prng) =
    list.fold(items, #([], prng), fn(acc, item) {
      let #(pairs, prng) = acc
      let #(key, prng) = next(prng)
      #([#(key, item), ..pairs], prng)
    })
  let shuffled =
    keyed
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.1 })
  #(shuffled, prng)
}

/// One element chosen uniformly, or an error for an empty list.
pub fn pick(items: List(a), prng: Prng) -> Result(#(a, Prng), Nil) {
  let #(index, prng) = int_below(prng, list.length(items))
  case list.drop(items, index) {
    [item, ..] -> Ok(#(item, prng))
    [] -> Error(Nil)
  }
}

/// `count` distinct elements chosen uniformly without replacement, in
/// random order. Returns the whole list shuffled if it is shorter.
pub fn sample(items: List(a), count: Int, prng: Prng) -> #(List(a), Prng) {
  let #(shuffled, prng) = shuffle(items, prng)
  #(list.take(shuffled, count), prng)
}

/// The mean of a list of floats, used by tests of this module.
pub fn mean(values: List(Float)) -> Float {
  case values {
    [] -> 0.0
    _ -> float.sum(values) /. int.to_float(list.length(values))
  }
}
