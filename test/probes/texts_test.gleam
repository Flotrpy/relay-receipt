import gleam/list
import gleam/string
import receipt/probes/texts
import receipt/thresholds

pub fn there_are_exactly_thirty_texts_test() {
  assert list.length(texts.all()) == thresholds.injection_texts
}

pub fn texts_are_distinct_and_non_empty_test() {
  let all = texts.all()
  assert list.unique(all) == all
  assert list.all(all, fn(text) { string.length(text) > 0 })
}

pub fn the_set_covers_the_categories_of_the_paper_test() {
  let all = string.join(texts.all(), "\n")
  // Non-Latin scripts, code, emoji, structured data, URLs.
  ["天气", "Привет", "مرحبا", "def add", "SELECT", "🚀", "{\"name\"", "https://"]
  |> list.each(fn(marker) {
    assert string.contains(all, marker)
  })
}

pub fn two_texts_are_long_repeats_test() {
  assert list.count(texts.all(), fn(text) { string.length(text) >= 300 }) == 2
}

pub fn no_text_is_so_long_it_strains_a_free_tier_test() {
  assert list.all(texts.all(), fn(text) { string.length(text) <= 1000 })
}

pub fn three_minimal_messages_for_the_estimate_method_test() {
  assert list.length(texts.minimal()) == 3
}
