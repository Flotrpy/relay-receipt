//// The categorical two-sample test of AgentProv (arXiv:2609.00052).
////
//// Each template yields categorical outcomes (which tool was called) from
//// a reference and from a target. Under the delta kernel the squared MMD
//// between the two samples is the squared Euclidean distance between
//// their per-template outcome frequencies, summed over templates. The
//// null distribution comes from shuffling endpoint labels within each
//// template.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import receipt/prng.{type Prng}
import receipt/stats/permutation

/// The outcomes observed for one template.
pub type Template {
  Template(reference: List(String), target: List(String))
}

pub type TestResult {
  TestResult(
    /// The observed statistic T.
    statistic: Float,
    p_value: Float,
    /// Each template's contribution to T, in input order.
    per_template: List(Float),
  )
}

fn counts(outcomes: List(String)) -> Dict(String, Int) {
  list.fold(outcomes, dict.new(), fn(tally, outcome) {
    dict.upsert(tally, outcome, fn(existing) {
      case existing {
        Some(count) -> count + 1
        None -> 1
      }
    })
  })
}

fn option_count(found: Result(Int, Nil)) -> Int {
  result.unwrap(found, 0)
}

/// `||phi_ref - phi_tgt||^2` for one template. A template with no samples
/// on either side contributes nothing.
pub fn template_distance(template: Template) -> Float {
  let reference_size = list.length(template.reference)
  let target_size = list.length(template.target)
  case reference_size == 0 || target_size == 0 {
    True -> 0.0
    False -> {
      let reference = counts(template.reference)
      let target = counts(template.target)
      list.append(dict.keys(reference), dict.keys(target))
      |> list.unique
      |> list.fold(0.0, fn(total, outcome) {
        let difference =
          int.to_float(option_count(dict.get(reference, outcome)))
          /. int.to_float(reference_size)
          -. int.to_float(option_count(dict.get(target, outcome)))
          /. int.to_float(target_size)
        total +. difference *. difference
      })
    }
  }
}

/// The statistic T: the sum of template distances.
pub fn statistic(templates: List(Template)) -> Float {
  list.fold(templates, 0.0, fn(total, template) {
    total +. template_distance(template)
  })
}

/// Shuffle endpoint labels within one template, keeping group sizes.
fn permute(template: Template, prng: Prng) -> #(Template, Prng) {
  let pooled = list.append(template.reference, template.target)
  let #(shuffled, prng) = prng.shuffle(pooled, prng)
  let #(reference, target) =
    list.split(shuffled, list.length(template.reference))
  #(Template(reference, target), prng)
}

fn permuted_statistic(templates: List(Template), prng: Prng) -> #(Float, Prng) {
  list.fold(templates, #(0.0, prng), fn(acc, template) {
    let #(total, prng) = acc
    let #(shuffled, prng) = permute(template, prng)
    #(total +. template_distance(shuffled), prng)
  })
}

/// The permutation test of AgentProv's Algorithm 1.
pub fn permutation_test(
  templates: List(Template),
  permutations: Int,
  prng: Prng,
) -> #(TestResult, Prng) {
  let observed = statistic(templates)
  let #(simulated, prng) = simulate(templates, permutations, prng, [])
  #(
    TestResult(
      statistic: observed,
      p_value: permutation.p_value(observed, simulated),
      per_template: list.map(templates, template_distance),
    ),
    prng,
  )
}

fn simulate(
  templates: List(Template),
  remaining: Int,
  prng: Prng,
  acc: List(Float),
) -> #(List(Float), Prng) {
  case remaining <= 0 {
    True -> #(acc, prng)
    False -> {
      let #(value, prng) = permuted_statistic(templates, prng)
      simulate(templates, remaining - 1, prng, [value, ..acc])
    }
  }
}

/// A permutation p-value for one template alone, for the diagnostic table.
pub fn template_p_value(
  template: Template,
  permutations: Int,
  prng: Prng,
) -> #(Float, Prng) {
  let #(result, prng) = permutation_test([template], permutations, prng)
  #(result.p_value, prng)
}
