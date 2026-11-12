import evilrelay/matrix.{Cells}
import gleam/string

fn report(name: String, verdicts: String) {
  let assert Ok(found) = matrix.parse(name, "{\"steps\":[" <> verdicts <> "]}")
  found
}

const clean8 = "{\"id\":8,\"status\":\"run\",\"verdict\":\"clean\"}"

const anomaly8 = "{\"id\":8,\"status\":\"run\",\"verdict\":\"anomaly\"}"

const unsure8 = "{\"id\":8,\"status\":\"run\",\"verdict\":\"inconclusive\"}"

pub fn condition_comes_from_the_file_name_test() {
  assert report("a-rewrite", clean8).condition == "rewrite"
  assert matrix.is_honest("a-none")
  assert matrix.is_honest("c-groq-direct")
  assert !matrix.is_honest("a-inject")
}

pub fn detection_under_the_aimed_fault_is_a_true_positive_test() {
  assert matrix.cells([report("a-rewrite", anomaly8)], 8)
    == Cells(1, 0, 0, 0, 0, 0)
  assert matrix.cells([report("a-rewrite", clean8)], 8)
    == Cells(0, 1, 0, 0, 0, 0)
  assert matrix.cells([report("a-rewrite", unsure8)], 8)
    == Cells(0, 0, 1, 0, 0, 0)
}

pub fn honest_conditions_give_false_positives_and_true_negatives_test() {
  assert matrix.cells([report("a-none", anomaly8)], 8)
    == Cells(0, 0, 0, 1, 0, 0)
  assert matrix.cells([report("c-x", clean8)], 8) == Cells(0, 0, 0, 0, 1, 0)
  assert matrix.cells([report("a-none", unsure8)], 8) == Cells(0, 0, 0, 0, 0, 1)
}

pub fn off_target_faults_are_not_counted_test() {
  assert matrix.cells([report("a-inject", anomaly8)], 8)
    == Cells(0, 0, 0, 0, 0, 0)
}

pub fn render_shows_grid_and_confusion_test() {
  let text =
    matrix.render([report("a-none", clean8), report("a-rewrite", anomaly8)])
  assert string.contains(text, "| a-rewrite | **anomaly** |")
  assert string.contains(text, "| 8 | 1 | 0 | 0 | 0 | 1 | 0 |")
}
