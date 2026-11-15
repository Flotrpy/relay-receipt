import gleam/list
import gleam/string
import receipt/probes/everyday
import receipt/thresholds

pub fn there_are_enough_prompts_for_every_batch_test() {
  assert list.length(everyday.pool())
    >= thresholds.identity_prompts_per_batch * thresholds.identity_batches_full
}

pub fn prompts_are_distinct_and_short_test() {
  let pool = everyday.pool()
  assert list.unique(pool) == pool
  assert list.all(pool, fn(prompt) {
    string.length(prompt) > 10 && string.length(prompt) < 120
  })
}

pub fn prompts_do_not_mention_auditing_test() {
  let text = string.lowercase(string.join(everyday.pool(), " "))
  ["audit", "test", "relay", "model", "token"]
  |> list.each(fn(word) {
    assert !string.contains(text, word)
  })
}
