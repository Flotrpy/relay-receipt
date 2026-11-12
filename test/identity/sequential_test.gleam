import gleam/int
import gleam/list
import gleam/option.{None, Some}
import receipt/identity/sequential.{
  BatchResult, Different, InsufficientData, Same, TextSamples, ToolSamples,
} as seqtest
import receipt/prng
import receipt/seq

fn tools(reference: String, target: String, valid: Int) {
  seq.range(1, 20)
  |> list.map(fn(index) {
    let samples = fn(name: String) {
      list.append(list.repeat(Some(name), valid), list.repeat(None, 5 - valid))
    }
    ToolSamples(
      "t" <> int.to_string(index),
      samples(reference),
      samples(target),
    )
  })
}

fn decisive() {
  BatchResult(True, Some(0.0002), 68.0)
}

fn neutral() {
  BatchResult(True, Some(0.6), 0.9)
}

fn invalid() {
  BatchResult(False, None, 1.0)
}

pub fn identical_tool_choices_give_no_evidence_test() {
  let #(result, _) =
    seqtest.evaluate_tools(tools("a", "a", 5), 199, prng.new(1))
  assert result.valid
  assert result.p_value == Some(1.0)
  assert result.e_value == 0.5
}

pub fn opposite_tool_choices_give_the_smallest_p_value_test() {
  let #(result, _) =
    seqtest.evaluate_tools(tools("a", "b", 5), 199, prng.new(1))
  assert result.p_value == Some(0.005)
  assert result.e_value >. 5.0
}

pub fn four_of_five_valid_samples_keeps_a_template_test() {
  assert list.length(seqtest.valid_templates(tools("a", "b", 4))) == 20
  assert seqtest.valid_templates(tools("a", "b", 3)) == []
}

pub fn fewer_than_sixteen_valid_templates_invalidate_the_batch_test() {
  let batch =
    list.append(
      list.take(tools("a", "b", 5), 15),
      list.take(tools("a", "b", 2), 5),
    )
  let #(result, _) = seqtest.evaluate_tools(batch, 99, prng.new(1))
  assert result == BatchResult(False, None, 1.0)
  let enough =
    list.append(
      list.take(tools("a", "b", 5), 16),
      list.take(tools("a", "b", 2), 4),
    )
  let #(valid, _) = seqtest.evaluate_tools(enough, 99, prng.new(1))
  assert valid.valid
}

pub fn failed_requests_are_not_samples_but_no_call_is_test() {
  // "_no_call" is data; None is a missing value.
  let batch = tools("_no_call", "_no_call", 5)
  let #(result, _) = seqtest.evaluate_tools(batch, 99, prng.new(1))
  assert result.valid
}

fn text_batch(target: fn(Int) -> option.Option(String), references: Int) {
  seq.range(1, 10)
  |> list.map(fn(index) {
    TextSamples(
      target(index),
      list.append(
        seq.range(1, references)
          |> list.map(fn(r) {
            Some("the answer number " <> int.to_string(r % 3))
          }),
        list.repeat(None, 10 - references),
      ),
    )
  })
}

pub fn ranks_are_computed_only_for_valid_prompts_test() {
  let #(all, _) =
    seqtest.ranks(
      text_batch(fn(_) { Some("the answer number 1") }, 10),
      prng.new(1),
    )
  assert list.length(all) == 10
  let #(some, _) =
    seqtest.ranks(
      text_batch(
        fn(index) {
          case index <= 7 {
            True -> Some("x")
            False -> None
          }
        },
        10,
      ),
      prng.new(1),
    )
  assert list.length(some) == 7
  let #(few_references, _) =
    seqtest.ranks(text_batch(fn(_) { Some("x") }, 7), prng.new(1))
  assert few_references == []
}

pub fn text_batch_needs_eight_valid_prompts_test() {
  let #(result, _) =
    seqtest.evaluate_text(
      text_batch(
        fn(index) {
          case index <= 7 {
            True -> Some("x")
            False -> None
          }
        },
        10,
      ),
      99,
      prng.new(1),
    )
  assert result == BatchResult(False, None, 1.0)
}

pub fn atypical_target_text_gives_a_small_p_value_test() {
  let #(result, _) =
    seqtest.evaluate_text(
      text_batch(fn(_) { Some("zebra quantum flux capacitor") }, 10),
      999,
      prng.new(1),
    )
  assert result.valid
  let assert Some(p) = result.p_value
  assert p <. 0.01
}

pub fn evidence_is_the_mean_of_component_products_test() {
  let progress =
    seqtest.start()
    |> seqtest.add(
      BatchResult(True, Some(0.1), 4.0),
      BatchResult(True, Some(0.5), 0.5),
    )
    |> seqtest.add(BatchResult(True, Some(0.1), 5.0), invalid())
  assert seqtest.tool_evidence(progress) == 20.0
  assert seqtest.text_evidence(progress) == 0.5
  assert seqtest.evidence(progress) == 10.25
  assert !seqtest.rejects(progress)
}

pub fn no_batches_is_no_evidence_test() {
  assert seqtest.evidence(seqtest.start()) == 1.0
  assert seqtest.conclude(seqtest.start()) == InsufficientData
}

pub fn one_decisive_component_is_enough_to_reject_test() {
  let progress = seqtest.start() |> seqtest.add(decisive(), invalid())
  assert seqtest.rejects(progress)
  assert seqtest.conclude(progress) == Different
}

pub fn same_needs_two_valid_batches_in_one_component_test() {
  let one = seqtest.start() |> seqtest.add(neutral(), neutral())
  assert seqtest.conclude(one) == InsufficientData
  let two = one |> seqtest.add(neutral(), invalid())
  assert seqtest.conclude(two) == Same
  let text_only =
    seqtest.start()
    |> seqtest.add(invalid(), neutral())
    |> seqtest.add(invalid(), neutral())
  assert seqtest.conclude(text_only) == Same
}

pub fn invalid_batches_never_count_toward_same_test() {
  let progress =
    seqtest.start()
    |> seqtest.add(invalid(), invalid())
    |> seqtest.add(invalid(), invalid())
    |> seqtest.add(neutral(), invalid())
  assert seqtest.conclude(progress) == InsufficientData
}

pub fn outcome_names_test() {
  assert seqtest.outcome_to_string(Different) == "different"
  assert seqtest.outcome_to_string(Same) == "same"
  assert seqtest.outcome_to_string(InsufficientData) == "insufficient_data"
}
