import receipt/seq

pub fn range_is_inclusive_test() {
  assert seq.range(1, 4) == [1, 2, 3, 4]
  assert seq.range(0, 0) == [0]
  assert seq.range(-1, 1) == [-1, 0, 1]
}

pub fn range_is_empty_when_reversed_test() {
  assert seq.range(3, 2) == []
}

pub fn indexed_starts_at_zero_test() {
  assert seq.indexed(["a", "b"]) == [#(0, "a"), #(1, "b")]
  assert seq.indexed([]) == []
}

pub fn at_returns_the_element_or_an_error_test() {
  assert seq.at([10, 20, 30], 1) == Ok(20)
  assert seq.at([10, 20, 30], 3) == Error(Nil)
  assert seq.at([10], -1) == Error(Nil)
}
