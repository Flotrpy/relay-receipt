//// The in-memory report both reporters render from.

import gleam/list
import gleam/option.{type Option}
import receipt/rating.{type Rating}
import receipt/step.{type StepResult}
import receipt/verdict.{Inconclusive, Run}

pub type EndpointInfo {
  EndpointInfo(
    name: String,
    base_url: String,
    model: String,
    api_format: Option(String),
  )
}

pub type Report {
  Report(
    generated_at: String,
    tool_version: String,
    profile: String,
    seed: Int,
    target: EndpointInfo,
    reference: Option(EndpointInfo),
    endpoints: List(EndpointInfo),
    rating: Rating,
    steps: List(StepResult),
    limits: List(String),
  )
}

/// Statements printed in every report, whatever the outcome.
pub const standing_limits = [
  "This report is not a safety certificate. It records what these probes observed on these requests at this time.",
  "An anomaly is a reason to investigate, not proof of intent or of a specific mechanism.",
  "Inconclusive steps and steps that did not run are not evidence of clean behaviour.",
  "A relay can behave differently on traffic it recognises as an audit, or on a small share of requests.",
  "Token counts, model names, ids and headers are whatever the endpoint reported.",
]

/// Statements added when Step 15 ran. See `docs/steps/15-inflation.md`.
pub const inflation_limits = [
  "Step 15 looks for output that is already lengthened. It cannot detect token counts that are misreported without the visible text changing.",
  "Misreported hidden reasoning tokens cannot be detected black-box: auditing reported token counts needs access to the model (arXiv:2510.05181), and audits that rely on evidence supplied by the provider can be evaded (arXiv:2605.30040).",
]

/// The limits that apply to a set of step results.
pub fn limits_for(steps: List(StepResult)) -> List(String) {
  let inflation_ran =
    list.any(steps, fn(result) { result.id == 15 && result.status == Run })
  case inflation_ran {
    True -> list.append(standing_limits, inflation_limits)
    False -> standing_limits
  }
}

/// Steps whose status is not `run`.
pub fn not_run(report: Report) -> List(StepResult) {
  list.filter(report.steps, fn(result) { result.status != Run })
}

/// Steps that ran and were inconclusive.
pub fn inconclusive(report: Report) -> List(StepResult) {
  list.filter(report.steps, fn(result) {
    result.status == Run && result.verdict == Inconclusive
  })
}

/// Steps that crashed.
pub fn crashed(report: Report) -> List(StepResult) {
  list.filter(report.steps, fn(result) { result.crashed })
}
