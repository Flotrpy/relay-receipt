import gleam/list
import gleam/string
import receipt/probes/questions
import receipt/thresholds

pub fn pool_is_larger_than_one_audit_needs_test() {
  assert list.length(questions.pool()) >= thresholds.inflation_questions + 10
}

pub fn ids_and_texts_are_unique_test() {
  let pool = questions.pool()
  let ids = list.map(pool, fn(q) { q.id })
  let texts = list.map(pool, fn(q) { q.text })
  assert list.unique(ids) == ids
  assert list.unique(texts) == texts
}

pub fn every_question_has_four_distinct_options_test() {
  list.each(questions.pool(), fn(question) {
    assert list.length(question.options) == 4
    assert list.unique(question.options) == question.options
  })
}

pub fn rendered_question_lists_options_and_asks_for_an_answer_line_test() {
  let assert [first, ..] = questions.pool()
  let text = questions.render(first)
  assert string.contains(
    text,
    "A) Oxygen\nB) Carbon dioxide\nC) Nitrogen\nD) Helium",
  )
  assert string.ends_with(text, questions.answer_line)
}

pub fn probed_question_only_appends_the_probe_test() {
  let assert [first, ..] = questions.pool()
  let plain = questions.render(first)
  let probed = questions.render_probed(first, questions.probe_a)
  assert string.starts_with(probed, plain)
  assert string.ends_with(probed, questions.probe_a)
}

pub fn probes_are_the_two_formulations_of_the_paper_test() {
  assert string.starts_with(
    questions.probe_a,
    "Before the required final-answer line",
  )
  assert string.starts_with(
    questions.probe_b,
    "Lay out the required derivation",
  )
  assert questions.probe_a != questions.probe_b
}
