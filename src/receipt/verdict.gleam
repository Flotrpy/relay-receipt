//// The closed vocabulary every step result is expressed in.
////
//// Meanings are fixed in `docs/THRESHOLDS.md`. Keeping them as closed
//// types means no step can report a value outside that vocabulary.

/// What a step concluded.
pub type Verdict {
  /// The step ran with enough valid observations and its rule did not fire.
  Clean
  /// The step's pre-registered rule fired. A reason to investigate, not proof.
  Anomaly
  /// The step could not decide. Never counted as clean.
  Inconclusive
  /// The step only describes the endpoint and makes no claim either way.
  Informational
}

/// Whether, and why, a step executed.
pub type Status {
  /// The step executed.
  Run
  /// Turned off by the user, or made pointless by an earlier failure.
  Skipped
  /// The selected profile does not include the step.
  ProfileGated
  /// The step cannot apply to this run.
  NotApplicable
}

/// How serious an anomaly is. Steps that do not grade severity use `High`.
pub type Severity {
  Medium
  High
  Critical
}

/// How a step's anomaly affects the overall rating.
pub type Class {
  /// An anomaly is `HIGH` on its own.
  CriticalClass
  /// An anomaly is `MEDIUM` on its own, `HIGH` with a second one.
  MajorClass
  /// Shown, never moves the rating.
  AdvisoryClass
  /// Descriptive only, never moves the rating.
  InformationalClass
}

/// The overall rating of a report.
pub type Risk {
  Low
  MediumRisk
  HighRisk
}

pub fn verdict_to_string(verdict: Verdict) -> String {
  case verdict {
    Clean -> "clean"
    Anomaly -> "anomaly"
    Inconclusive -> "inconclusive"
    Informational -> "informational"
  }
}

pub fn verdict_from_string(text: String) -> Result(Verdict, Nil) {
  case text {
    "clean" -> Ok(Clean)
    "anomaly" -> Ok(Anomaly)
    "inconclusive" -> Ok(Inconclusive)
    "informational" -> Ok(Informational)
    _ -> Error(Nil)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Run -> "run"
    Skipped -> "skipped"
    ProfileGated -> "profile_gated"
    NotApplicable -> "not_applicable"
  }
}

pub fn status_from_string(text: String) -> Result(Status, Nil) {
  case text {
    "run" -> Ok(Run)
    "skipped" -> Ok(Skipped)
    "profile_gated" -> Ok(ProfileGated)
    "not_applicable" -> Ok(NotApplicable)
    _ -> Error(Nil)
  }
}

pub fn severity_to_string(severity: Severity) -> String {
  case severity {
    Medium -> "medium"
    High -> "high"
    Critical -> "critical"
  }
}

pub fn class_to_string(class: Class) -> String {
  case class {
    CriticalClass -> "critical"
    MajorClass -> "major"
    AdvisoryClass -> "advisory"
    InformationalClass -> "informational"
  }
}

pub fn risk_to_string(risk: Risk) -> String {
  case risk {
    Low -> "LOW"
    MediumRisk -> "MEDIUM"
    HighRisk -> "HIGH"
  }
}

/// Order severities so the worst of several findings can be chosen.
pub fn severity_rank(severity: Severity) -> Int {
  case severity {
    Medium -> 1
    High -> 2
    Critical -> 3
  }
}

/// The more serious of two severities.
pub fn worst_severity(a: Severity, b: Severity) -> Severity {
  case severity_rank(a) >= severity_rank(b) {
    True -> a
    False -> b
  }
}
