//// The JSON report, schema version 1. See `docs/REPORT_SCHEMA.md`.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import receipt/catalog
import receipt/report/model.{type EndpointInfo, type Report}
import receipt/step.{type StepResult}
import receipt/verdict

pub const schema_version = 1

pub fn render(report: Report) -> String {
  to_json(report) |> json.to_string
}

pub fn to_json(report: Report) -> Json {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("report_type", json.string("audit")),
    #("generated_at", json.string(report.generated_at)),
    #(
      "tool",
      json.object([
        #("name", json.string("receipt")),
        #("version", json.string(report.tool_version)),
      ]),
    ),
    #("profile", json.string(report.profile)),
    #("seed", json.int(report.seed)),
    #("target", endpoint(report.target)),
    #("reference", json.nullable(report.reference, endpoint)),
    #("endpoints", json.array(report.endpoints, endpoint)),
    #("risk_level", json.string(verdict.risk_to_string(report.rating.risk))),
    #(
      "rating",
      json.object([
        #("rule", json.int(report.rating.rule)),
        #("reasons", json.array(report.rating.reasons, json.string)),
      ]),
    ),
    #("steps", json.array(report.steps, step)),
    #(
      "coverage",
      json.object([
        #(
          "not_run",
          json.array(model.not_run(report), fn(result) {
            json.object([
              #("id", json.int(result.id)),
              #("status", json.string(verdict.status_to_string(result.status))),
              #("reason", json.nullable(result.reason, json.string)),
            ])
          }),
        ),
        #("inconclusive", ids(model.inconclusive(report))),
        #("crashed", ids(model.crashed(report))),
      ]),
    ),
    #("limits", json.array(report.limits, json.string)),
  ])
}

fn ids(results: List(StepResult)) -> Json {
  json.array(results, fn(result) { json.int(result.id) })
}

fn endpoint(info: EndpointInfo) -> Json {
  json.object([
    #("name", json.string(info.name)),
    #("base_url", json.string(info.base_url)),
    #("model", json.string(info.model)),
    #("api_format", json.nullable(info.api_format, json.string)),
  ])
}

fn step(result: StepResult) -> Json {
  let info = catalog.find(result.id)
  let field = fn(pick: fn(catalog.StepInfo) -> String) -> Option(String) {
    case info {
      Ok(info) -> Some(pick(info))
      Error(Nil) -> None
    }
  }
  json.object([
    #("id", json.int(result.id)),
    #("key", json.nullable(field(fn(i) { i.key }), json.string)),
    #("title", json.nullable(field(fn(i) { i.title }), json.string)),
    #(
      "class",
      json.string(verdict.class_to_string(catalog.class_of(result.id))),
    ),
    #("status", json.string(verdict.status_to_string(result.status))),
    #("verdict", json.string(verdict.verdict_to_string(result.verdict))),
    #(
      "severity",
      json.nullable(result.severity, fn(severity) {
        json.string(verdict.severity_to_string(severity))
      }),
    ),
    #("summary", json.string(result.summary)),
    #("reason", json.nullable(result.reason, json.string)),
    #(
      "findings",
      json.array(result.findings, fn(finding) {
        json.object([
          #("level", json.string(step.finding_level_to_string(finding.level))),
          #("text", json.string(finding.text)),
        ])
      }),
    ),
    #("data", json.object(result.data)),
    #(
      "error_rate",
      json.nullable(result.error_rate, fn(rate) {
        json.object([
          #("kind", json.string(rate.kind)),
          #("bound", json.float(rate.bound)),
          #("basis", json.string(rate.basis)),
        ])
      }),
    ),
    #(
      "requests",
      json.object([
        #("sent", json.int(result.requests_sent)),
        #("failed", json.int(result.requests_failed)),
      ]),
    ),
    #("duration_ms", json.int(result.duration_ms)),
    #("crashed", json.bool(result.crashed)),
    #(
      "references",
      json.array(
        case info {
          Ok(info) -> info.references
          Error(Nil) -> []
        },
        json.string,
      ),
    ),
  ])
}
