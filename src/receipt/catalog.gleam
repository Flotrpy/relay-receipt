//// The fixed list of steps: number, machine key, title, class and sources.
////
//// The classes here are the "Step classes" table of `docs/THRESHOLDS.md`.

import gleam/list
import receipt/verdict.{
  type Class, AdvisoryClass, CriticalClass, InformationalClass, MajorClass,
}

pub type StepInfo {
  StepInfo(
    id: Int,
    key: String,
    title: String,
    class: Class,
    /// Runs only in the `full` profile.
    full_only: Bool,
    references: List(String),
  )
}

const relay_paper = "arXiv:2604.08407"

const shadow_paper = "arXiv:2603.01919"

/// Every step, in numeric order.
pub fn all() -> List(StepInfo) {
  [
    StepInfo(
      1,
      "infra_recon",
      "Infrastructure recon",
      InformationalClass,
      False,
      [],
    ),
    StepInfo(2, "connectivity", "Connectivity", InformationalClass, False, []),
    StepInfo(3, "token_injection", "Token injection", MajorClass, False, [
      "arXiv:2608.29930",
    ]),
    StepInfo(4, "prompt_extraction", "Prompt extraction", MajorClass, False, [
      relay_paper,
    ]),
    StepInfo(
      5,
      "instruction_override",
      "Instruction override / identity self-report",
      MajorClass,
      False,
      [shadow_paper],
    ),
    StepInfo(6, "jailbreak", "Jailbreak resistance", AdvisoryClass, False, []),
    StepInfo(
      7,
      "context_truncation",
      "Context truncation scan",
      MajorClass,
      False,
      [],
    ),
    StepInfo(
      8,
      "tool_substitution",
      "Tool-call substitution",
      CriticalClass,
      False,
      [
        relay_paper,
      ],
    ),
    StepInfo(
      9,
      "error_leakage",
      "Error-response leakage",
      CriticalClass,
      False,
      [
        relay_paper,
      ],
    ),
    StepInfo(
      10,
      "stream_integrity",
      "Stream (SSE) integrity",
      CriticalClass,
      False,
      [],
    ),
    StepInfo(11, "web3", "Web3 prompt injection", InformationalClass, False, []),
    StepInfo(
      12,
      "infra_fingerprint",
      "Infrastructure fingerprint",
      InformationalClass,
      False,
      [shadow_paper],
    ),
    StepInfo(
      13,
      "latency_variance",
      "Latency variance",
      InformationalClass,
      False,
      [],
    ),
    StepInfo(
      14,
      "channel_classifier",
      "Upstream channel classifier",
      InformationalClass,
      False,
      [],
    ),
    StepInfo(15, "inflation", "Inflation probe", MajorClass, False, [
      "arXiv:2609.20370", "arXiv:2605.30040", "arXiv:2510.05181",
    ]),
    StepInfo(16, "upstream_map", "Upstream map", InformationalClass, True, [
      "arXiv:2608.20732",
    ]),
    StepInfo(17, "identity", "Identity test", MajorClass, False, [
      "arXiv:2609.00052", "arXiv:2506.06975",
    ]),
  ]
}

pub fn find(id: Int) -> Result(StepInfo, Nil) {
  list.find(all(), fn(info) { info.id == id })
}

/// The class of a step. Unknown ids are informational so they can never
/// move a rating.
pub fn class_of(id: Int) -> Class {
  case find(id) {
    Ok(info) -> info.class
    Error(Nil) -> InformationalClass
  }
}

/// Whether an anomaly or an inconclusive result in this step can move the
/// overall rating.
pub fn is_rated(id: Int) -> Bool {
  case class_of(id) {
    CriticalClass | MajorClass -> True
    AdvisoryClass | InformationalClass -> False
  }
}
