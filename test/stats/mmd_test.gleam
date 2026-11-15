import gleam/int
import gleam/list
import receipt/prng.{type Prng}
import receipt/seq
import receipt/stats/mmd.{Template}
import receipt/stats/permutation
import support/close

pub fn p_value_counts_the_observed_statistic_test() {
  assert permutation.p_value(5.0, [1.0, 2.0, 3.0]) == 0.25
  assert permutation.p_value(2.0, [1.0, 2.0, 3.0]) == 0.75
  assert permutation.p_value(0.0, [1.0, 2.0, 3.0]) == 1.0
  assert permutation.p_value(1.0, []) == 1.0
  assert permutation.smallest_p(4999) == 0.0002
}

pub fn identical_samples_have_zero_distance_test() {
  let template = Template(["a", "a", "b"], ["b", "a", "a"])
  assert mmd.template_distance(template) == 0.0
}

pub fn disjoint_samples_have_distance_two_test() {
  // Frequencies (1, 0) against (0, 1): 1 + 1.
  assert mmd.template_distance(Template(["a", "a"], ["b", "b"])) == 2.0
}

pub fn distance_matches_the_papers_worked_example_test() {
  // Figure 2 of arXiv:2609.00052: phi = (.17,.33,.00,.00 | .33,.17,.00,.00)
  // is one endpoint's fingerprint. Against a reference that always picks
  // gmail and gcal the distance for template k1 is
  // (1-1/3)^2 + (2/3)^2 = 8/9.
  let k1 =
    Template(["gmail", "gmail", "gmail"], ["gmail", "outlook", "outlook"])
  assert close.to(mmd.template_distance(k1), 8.0 /. 9.0, 1.0e-12)
}

pub fn unequal_group_sizes_use_frequencies_test() {
  let template = Template(["a", "a", "a", "a"], ["a", "b"])
  // (1 - 0.5)^2 + (0 - 0.5)^2
  assert close.to(mmd.template_distance(template), 0.5, 1.0e-12)
}

pub fn empty_side_contributes_nothing_test() {
  assert mmd.template_distance(Template([], ["a"])) == 0.0
  assert mmd.template_distance(Template(["a"], [])) == 0.0
}

pub fn statistic_is_the_sum_over_templates_test() {
  let templates = [
    Template(["a", "a"], ["b", "b"]),
    Template(["x"], ["x"]),
    Template(["a", "a", "a", "a"], ["a", "b"]),
  ]
  assert close.to(mmd.statistic(templates), 2.5, 1.0e-12)
  let #(result, _) = mmd.permutation_test(templates, 50, prng.new(1))
  assert close.to(result.statistic, 2.5, 1.0e-12)
  assert list.length(result.per_template) == 3
}

pub fn statistic_is_symmetric_in_the_two_sides_test() {
  let template = Template(["a", "b", "b", "c"], ["a", "a", "c", "c"])
  assert mmd.template_distance(template)
    == mmd.template_distance(Template(template.target, template.reference))
}

pub fn the_test_is_deterministic_for_a_seed_test() {
  let templates = [
    Template(["a", "b", "a", "b", "a"], ["b", "b", "a", "b", "b"]),
  ]
  let #(first, _) = mmd.permutation_test(templates, 200, prng.new(7))
  let #(second, _) = mmd.permutation_test(templates, 200, prng.new(7))
  assert first == second
}

pub fn clearly_different_policies_get_the_smallest_p_value_test() {
  let templates =
    seq.range(1, 10)
    |> list.map(fn(_) {
      Template(list.repeat("alpha", 5), list.repeat("beta", 5))
    })
  let #(result, _) = mmd.permutation_test(templates, 999, prng.new(3))
  assert result.p_value == permutation.smallest_p(999)
}

/// Draw `count` outcomes from a three-way categorical distribution.
fn draw(
  count: Int,
  weights: #(Float, Float),
  generator: Prng,
) -> #(List(String), Prng) {
  seq.range(1, count)
  |> list.fold(#([], generator), fn(acc, _) {
    let #(outcomes, generator) = acc
    let #(unit, generator) = prng.float(generator)
    let outcome = case unit <. weights.0, unit <. weights.0 +. weights.1 {
      True, _ -> "tool_a"
      _, True -> "tool_b"
      _, _ -> "_no_call"
    }
    #([outcome, ..outcomes], generator)
  })
}

fn simulated_p_values(
  datasets: Int,
  reference_weights: #(Float, Float),
  target_weights: #(Float, Float),
  seed: Int,
) -> List(Float) {
  let #(p_values, _) =
    seq.range(1, datasets)
    |> list.fold(#([], prng.new(seed)), fn(acc, _) {
      let #(p_values, generator) = acc
      let #(templates, generator) =
        seq.range(1, 4)
        |> list.fold(#([], generator), fn(inner, _) {
          let #(templates, generator) = inner
          let #(reference, generator) = draw(6, reference_weights, generator)
          let #(target, generator) = draw(6, target_weights, generator)
          #([Template(reference, target), ..templates], generator)
        })
      let #(result, generator) = mmd.permutation_test(templates, 99, generator)
      #([result.p_value, ..p_values], generator)
    })
  p_values
}

fn share_at_most(p_values: List(Float), level: Float) -> Float {
  let hits = list.count(p_values, fn(p) { p <=. level })
  int.to_float(hits) /. int.to_float(list.length(p_values))
}

pub fn p_values_are_valid_under_the_null_test() {
  // Same policy on both sides: P(p <= level) must not exceed the level
  // (permutation p-values are exact or conservative).
  let p_values = simulated_p_values(600, #(0.5, 0.3), #(0.5, 0.3), 20_261_111)
  assert share_at_most(p_values, 0.05) <. 0.05 +. 0.03
  assert share_at_most(p_values, 0.2) <. 0.2 +. 0.05
  assert share_at_most(p_values, 0.5) <. 0.5 +. 0.06
  // And they are not degenerate: about half fall below one half.
  assert share_at_most(p_values, 0.5) >. 0.35
}

pub fn the_test_has_power_against_a_different_policy_test() {
  let p_values = simulated_p_values(200, #(0.8, 0.1), #(0.1, 0.8), 99)
  assert share_at_most(p_values, 0.05) >. 0.9
}
