import gleam/int
import gleam/list
import gleam/string
import receipt/report/markdown
import receipt/verdict.{Anomaly, Clean, Inconclusive, Informational}
import support/sample

fn rendered() -> String {
  markdown.render(sample.report())
}

fn index_of(text: String, part: String) -> Int {
  case string.split_once(text, part) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}

pub fn sections_appear_in_the_documented_order_test() {
  let text = rendered()
  let positions =
    [
      "# Receipt audit report", "## Rating: MEDIUM", "## Summary", "## Coverage",
      "## 2. Connectivity", "## 3. Token injection", "## 17. Identity test",
      "## What this report does not claim",
    ]
    |> list.map(index_of(text, _))
  assert !list.contains(positions, -1)
  assert positions == list.sort(positions, int.compare)
}

pub fn run_facts_are_in_the_header_test() {
  let text = rendered()
  assert string.contains(text, "| Target | `https://relay.example/v1` |")
  assert string.contains(text, "| Model | `m-1` |")
  assert string.contains(text, "| Reference | none configured |")
  assert string.contains(text, "| Seed | 42 |")
}

pub fn rating_names_the_rule_and_reason_test() {
  let text = rendered()
  assert string.contains(text, "Rule 4 of the rating table matched.")
  assert string.contains(text, "- Step 9 (Error-response leakage)")
}

pub fn summary_has_one_row_per_step_test() {
  let text = rendered()
  assert string.contains(
    text,
    "| 9 | Error-response leakage | run | anomaly (medium) |",
  )
  assert string.contains(text, "| 16 | Upstream map | profile_gated | - |")
}

pub fn coverage_lists_reasons_test() {
  let text = rendered()
  assert string.contains(text, "- Step 17 (Identity test): no_reference")
  assert string.contains(text, "- Step 10 (Stream (SSE) integrity): no_stream")
  assert string.contains(text, "Crashed: none.")
  assert string.contains(text, "not evidence of clean behaviour")
}

pub fn not_run_steps_say_nothing_is_known_test() {
  assert string.contains(
    rendered(),
    "**Status:** not_applicable (no_reference). Not run, so nothing is known from this step.",
  )
}

pub fn table_cells_escape_pipes_test() {
  assert string.contains(rendered(), "| a\\|b | 12 | 12 |")
  assert markdown.cell("x\ny|z") == "x y\\|z"
}

pub fn code_fence_outgrows_backticks_in_content_test() {
  let fenced = markdown.fenced("", "has ``` inside")
  assert string.starts_with(fenced, "````\n")
  assert string.ends_with(fenced, "\n````")
  assert string.contains(rendered(), "````\nTraceback ```")
}

pub fn error_rate_is_stated_for_statistical_steps_test() {
  assert string.contains(
    rendered(),
    "**Error rate:** false_positive at most 0.02% (paper, no system prompt).",
  )
}

pub fn limits_section_is_always_printed_test() {
  let text = rendered()
  assert string.contains(text, "not a safety certificate")
  assert string.contains(
    text,
    "Misreported hidden reasoning tokens cannot be detected black-box",
  )
}

pub fn verdict_meanings_follow_the_wording_rules_test() {
  assert markdown.meaning(Clean) == "no anomaly observed by this step"
  assert string.contains(markdown.meaning(Anomaly), "not proof")
  assert string.contains(markdown.meaning(Inconclusive), "not counted as clean")
  assert markdown.meaning(Informational) == "descriptive only"
}

pub fn report_never_uses_overclaiming_words_test() {
  let text = string.lowercase(rendered())
  ["fraud", "proven", "confirmed", "guarantee", "certified", "is safe"]
  |> list.each(fn(word) {
    assert !string.contains(text, word)
  })
  // "proof" and "safe" may only appear in negated, fixed phrases.
  let without_fixed =
    text
    |> string.replace("not proof", "")
    |> string.replace("not a safety certificate", "")
    |> string.replace("not a statement that the relay is safe to use", "")
  assert !string.contains(without_fixed, "proof")
  assert !string.contains(without_fixed, "safe")
}

pub fn html_from_endpoints_is_neutralised_test() {
  assert !string.contains(rendered(), "<script")
  assert string.contains(rendered(), "&lt;script>alert(1)")
}
