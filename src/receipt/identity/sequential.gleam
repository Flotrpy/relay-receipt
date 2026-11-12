//// The sequential decision of Step 17: batch p-values from the two
//// components are calibrated to e-values, multiplied within a component,
//// averaged across components, and compared with `1 / alpha`.
//// See `docs/steps/17-identity.md`.

import gleam/list
import gleam/option.{type Option, None, Some}
import receipt/prng.{type Prng}
import receipt/stats/cvm
import receipt/stats/evalue
import receipt/stats/mmd.{Template}
import receipt/stats/rut
import receipt/thresholds

/// One template's samples in a batch. `None` is a request that failed.
pub type ToolSamples {
  ToolSamples(
    template: String,
    reference: List(Option(String)),
    target: List(Option(String)),
  )
}

/// One prompt's completions in a batch. `None` is a request that failed.
pub type TextSamples {
  TextSamples(target: Option(String), references: List(Option(String)))
}

pub type BatchResult {
  BatchResult(
    /// Whether the batch passed its validity gate.
    valid: Bool,
    /// The batch p-value; `None` for an invalid batch.
    p_value: Option(Float),
    /// The batch e-value; 1 for an invalid batch.
    e_value: Float,
  )
}

const invalid = BatchResult(False, None, 1.0)

fn present(samples: List(Option(String))) -> List(String) {
  option.values(samples)
}

/// The templates of a batch that have enough valid samples on both sides.
pub fn valid_templates(batch: List(ToolSamples)) -> List(mmd.Template) {
  list.filter_map(batch, fn(samples) {
    let reference = present(samples.reference)
    let target = present(samples.target)
    case
      list.length(reference) >= thresholds.identity_min_valid_samples
      && list.length(target) >= thresholds.identity_min_valid_samples
    {
      True -> Ok(Template(reference, target))
      False -> Error(Nil)
    }
  })
}

/// Component A for one batch: the MMD permutation test over the valid
/// templates, or an invalid result if too few templates are valid.
pub fn evaluate_tools(
  batch: List(ToolSamples),
  permutations: Int,
  prng: Prng,
) -> #(BatchResult, Prng) {
  let templates = valid_templates(batch)
  case list.length(templates) >= thresholds.identity_min_valid_templates {
    False -> #(invalid, prng)
    True -> {
      let #(result, prng) = mmd.permutation_test(templates, permutations, prng)
      #(
        BatchResult(
          True,
          Some(result.p_value),
          evalue.calibrate(result.p_value),
        ),
        prng,
      )
    }
  }
}

/// The randomised ranks of the valid prompts of a batch.
pub fn ranks(batch: List(TextSamples), prng: Prng) -> #(List(Float), Prng) {
  list.fold(batch, #([], prng), fn(acc, samples) {
    let #(found, prng) = acc
    let references = present(samples.references)
    case
      samples.target,
      list.length(references) >= thresholds.identity_min_valid_references
    {
      Some(target), True -> {
        let #(u, prng) = prng.float(prng)
        #([rut.rank(target, references, u), ..found], prng)
      }
      _, _ -> #(found, prng)
    }
  })
  |> fn(pair) { #(list.reverse(pair.0), pair.1) }
}

/// Component B for one batch: the Cramér-von Mises test of the ranks, or
/// an invalid result if too few prompts are valid.
pub fn evaluate_text(
  batch: List(TextSamples),
  simulations: Int,
  prng: Prng,
) -> #(BatchResult, Prng) {
  let #(found, prng) = ranks(batch, prng)
  case list.length(found) >= thresholds.identity_min_valid_prompts {
    False -> #(invalid, prng)
    True -> {
      let #(result, prng) = cvm.uniformity_test(found, simulations, prng)
      #(
        BatchResult(
          True,
          Some(result.p_value),
          evalue.calibrate(result.p_value),
        ),
        prng,
      )
    }
  }
}

pub type Outcome {
  Different
  Same
  InsufficientData
}

/// Evidence accumulated so far.
pub type Progress {
  Progress(tool_batches: List(BatchResult), text_batches: List(BatchResult))
}

pub fn start() -> Progress {
  Progress([], [])
}

pub fn add(
  progress: Progress,
  tools: BatchResult,
  text: BatchResult,
) -> Progress {
  Progress(
    tool_batches: list.append(progress.tool_batches, [tools]),
    text_batches: list.append(progress.text_batches, [text]),
  )
}

fn product(batches: List(BatchResult)) -> Float {
  evalue.product(list.map(batches, fn(batch) { batch.e_value }))
}

pub fn tool_evidence(progress: Progress) -> Float {
  product(progress.tool_batches)
}

pub fn text_evidence(progress: Progress) -> Float {
  product(progress.text_batches)
}

/// The combined e-value: the mean of the two components' products.
pub fn evidence(progress: Progress) -> Float {
  evalue.mean([tool_evidence(progress), text_evidence(progress)])
}

fn valid_count(batches: List(BatchResult)) -> Int {
  list.count(batches, fn(batch) { batch.valid })
}

/// Whether the evidence has reached the rejection threshold.
pub fn rejects(progress: Progress) -> Bool {
  evidence(progress) >=. thresholds.identity_reject_at
}

/// The outcome when no more batches will be run.
pub fn conclude(progress: Progress) -> Outcome {
  case
    rejects(progress),
    valid_count(progress.tool_batches) >= 2
    || valid_count(progress.text_batches) >= 2
  {
    True, _ -> Different
    False, True -> Same
    False, False -> InsufficientData
  }
}

pub fn outcome_to_string(outcome: Outcome) -> String {
  case outcome {
    Different -> "different"
    Same -> "same"
    InsufficientData -> "insufficient_data"
  }
}
