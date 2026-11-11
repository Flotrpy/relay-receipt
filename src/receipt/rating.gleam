//// The overall rating: the rule table of `docs/THRESHOLDS.md`, first match
//// wins.

import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import receipt/catalog
import receipt/step.{type StepResult}
import receipt/verdict.{
  type Risk, Anomaly, CriticalClass, HighRisk, Inconclusive, Low, MajorClass,
  Medium, MediumRisk, Run,
}

pub type Rating {
  Rating(risk: Risk, rule: Int, reasons: List(String))
}

/// Rate a set of step results.
pub fn rate(results: List(StepResult)) -> Rating {
  let critical = list.filter(results, is_critical_anomaly)
  let major = list.filter(results, is_major_anomaly)
  let medium_leak = list.filter(results, is_medium_leak)
  let undecided = list.filter(results, is_rated_inconclusive)
  let crashed = list.filter(results, fn(r) { r.crashed })

  case critical, major, medium_leak, undecided, crashed {
    [_, ..], _, _, _, _ ->
      Rating(
        HighRisk,
        1,
        list.map(critical, describe("anomaly in a critical step")),
      )
    [], [_, _, ..], _, _, _ ->
      Rating(HighRisk, 2, list.map(major, describe("anomaly")))
    [], [one], _, _, _ -> Rating(MediumRisk, 3, [describe("anomaly")(one)])
    [], [], [_, ..], _, _ ->
      Rating(
        MediumRisk,
        4,
        list.map(medium_leak, describe("anomaly of medium severity")),
      )
    [], [], [], [], [] -> Rating(Low, 6, [])
    [], [], [], _, _ ->
      Rating(
        MediumRisk,
        5,
        list.append(
          list.map(undecided, describe("ran but was inconclusive")),
          list.map(crashed, describe("crashed")),
        )
          |> list.unique,
      )
  }
}

fn describe(what: String) -> fn(StepResult) -> String {
  fn(result: StepResult) {
    let title = case catalog.find(result.id) {
      Ok(info) -> info.title
      Error(Nil) -> "unknown step"
    }
    string.concat(["Step ", int.to_string(result.id), " (", title, "): ", what])
  }
}

fn is_critical_anomaly(result: StepResult) -> Bool {
  result.verdict == Anomaly
  && catalog.class_of(result.id) == CriticalClass
  && result.severity != Some(Medium)
}

fn is_major_anomaly(result: StepResult) -> Bool {
  result.verdict == Anomaly && catalog.class_of(result.id) == MajorClass
}

fn is_medium_leak(result: StepResult) -> Bool {
  result.verdict == Anomaly
  && catalog.class_of(result.id) == CriticalClass
  && result.severity == Some(Medium)
}

fn is_rated_inconclusive(result: StepResult) -> Bool {
  result.status == Run
  && result.verdict == Inconclusive
  && catalog.is_rated(result.id)
}
