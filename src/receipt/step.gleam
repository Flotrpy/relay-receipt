//// The result every step returns, and the only ways to build one.
////
//// Results are built through `ran` and `not_run` so the invariant from
//// `docs/THRESHOLDS.md` holds by construction: a step whose status is not
//// `run` always carries the verdict `inconclusive`.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import receipt/report/block.{type Block}
import receipt/verdict.{
  type Severity, type Status, type Verdict, Anomaly, Inconclusive, Run,
}

/// How a finding should be read.
pub type FindingLevel {
  /// An observation that points toward an anomaly.
  Signal
  /// A neutral observation.
  Note
  /// Something this step could not see or decide.
  Limit
}

pub type Finding {
  Finding(level: FindingLevel, text: String)
}

/// The error rate a statistical step states for its decision.
pub type ErrorRate {
  ErrorRate(kind: String, bound: Float, basis: String)
}

pub type StepResult {
  StepResult(
    id: Int,
    status: Status,
    verdict: Verdict,
    severity: Option(Severity),
    summary: String,
    reason: Option(String),
    findings: List(Finding),
    data: List(#(String, Json)),
    details: List(Block),
    error_rate: Option(ErrorRate),
    requests_sent: Int,
    requests_failed: Int,
    duration_ms: Int,
    crashed: Bool,
  )
}

/// A result for a step that executed.
pub fn ran(id: Int, verdict: Verdict, summary: String) -> StepResult {
  StepResult(
    id: id,
    status: Run,
    verdict: verdict,
    severity: case verdict {
      Anomaly -> Some(verdict.High)
      _ -> None
    },
    summary: summary,
    reason: None,
    findings: [],
    data: [],
    details: [],
    error_rate: None,
    requests_sent: 0,
    requests_failed: 0,
    duration_ms: 0,
    crashed: False,
  )
}

/// A result for a step that executed but could not decide.
pub fn inconclusive(id: Int, reason: String, summary: String) -> StepResult {
  StepResult(..ran(id, Inconclusive, summary), reason: Some(reason))
}

/// A result for a step that did not execute. `status` must not be `Run`;
/// if it is, the result is still inconclusive.
pub fn not_run(id: Int, status: Status, reason: String) -> StepResult {
  StepResult(
    ..ran(id, Inconclusive, "Not run: " <> reason),
    status: status,
    reason: Some(reason),
  )
}

/// A result for a step that raised an error while running.
pub fn crashed(id: Int, detail: String) -> StepResult {
  StepResult(
    ..ran(id, Inconclusive, "The step crashed: " <> detail),
    reason: Some("crashed"),
    crashed: True,
  )
}

/// Grade an anomaly. Has no effect on other verdicts.
pub fn with_severity(result: StepResult, severity: Severity) -> StepResult {
  case result.verdict {
    Anomaly -> StepResult(..result, severity: Some(severity))
    _ -> result
  }
}

pub fn with_finding(
  result: StepResult,
  level: FindingLevel,
  text: String,
) -> StepResult {
  StepResult(
    ..result,
    findings: list.append(result.findings, [Finding(level, text)]),
  )
}

pub fn with_data(result: StepResult, key: String, value: Json) -> StepResult {
  StepResult(..result, data: list.append(result.data, [#(key, value)]))
}

pub fn with_details(result: StepResult, blocks: List(Block)) -> StepResult {
  StepResult(..result, details: list.append(result.details, blocks))
}

pub fn with_error_rate(result: StepResult, rate: ErrorRate) -> StepResult {
  StepResult(..result, error_rate: Some(rate))
}

pub fn with_requests(
  result: StepResult,
  sent sent: Int,
  failed failed: Int,
) -> StepResult {
  StepResult(..result, requests_sent: sent, requests_failed: failed)
}

pub fn with_duration(result: StepResult, duration_ms: Int) -> StepResult {
  StepResult(..result, duration_ms: duration_ms)
}

pub fn finding_level_to_string(level: FindingLevel) -> String {
  case level {
    Signal -> "signal"
    Note -> "note"
    Limit -> "limit"
  }
}
