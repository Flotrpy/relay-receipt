//// The Markdown report. Layout and wording rules are in
//// `docs/REPORT_SCHEMA.md`.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/catalog
import receipt/report/block.{
  type Block, Bullets, Code, Mermaid, Paragraph, Table,
}
import receipt/report/model.{type EndpointInfo, type Report}
import receipt/step.{type StepResult}
import receipt/verdict.{
  type Verdict, Anomaly, Clean, Inconclusive, Informational, Run,
}

pub fn render(report: Report) -> String {
  [
    header(report),
    rating(report),
    summary(report),
    coverage(report),
    ..list.map(report.steps, step_section)
  ]
  |> list.append([limits(report)])
  |> string.join("\n\n")
  |> string.append("\n")
}

fn header(report: Report) -> String {
  let rows = [
    ["Target", code_span(report.target.base_url)],
    ["Model", code_span(report.target.model)],
    [
      "API format",
      option.unwrap(report.target.api_format, "not detected"),
    ],
    [
      "Reference",
      case report.reference {
        Some(reference) -> endpoint_cell(reference)
        None -> "none configured"
      },
    ],
    ["Profile", report.profile],
    ["Generated", report.generated_at],
    ["Tool", "receipt " <> report.tool_version],
    ["Seed", int.to_string(report.seed)],
  ]
  let extra = case report.endpoints {
    [] -> []
    endpoints -> [
      ["Other endpoints", string.join(list.map(endpoints, endpoint_cell), "; ")],
    ]
  }
  "# Receipt audit report\n\n" <> table(["", ""], list.append(rows, extra))
}

fn endpoint_cell(info: EndpointInfo) -> String {
  info.name
  <> ": "
  <> code_span(info.base_url)
  <> " ("
  <> code_span(info.model)
  <> ")"
}

fn rating(report: Report) -> String {
  let risk = verdict.risk_to_string(report.rating.risk)
  let reasons = case report.rating.reasons {
    [] ->
      "No rated step reported an anomaly or an inconclusive result among the steps that ran. This is not a statement that the relay is safe to use."
    reasons -> bullets(reasons)
  }
  "## Rating: "
  <> risk
  <> "\n\nRule "
  <> int.to_string(report.rating.rule)
  <> " of the rating table matched.\n\n"
  <> reasons
}

fn summary(report: Report) -> String {
  let rows =
    list.map(report.steps, fn(result) {
      [
        int.to_string(result.id),
        title(result.id),
        verdict.status_to_string(result.status),
        verdict_cell(result),
        result.summary,
      ]
    })
  "## Summary\n\n" <> table(["#", "Step", "Status", "Verdict", "Summary"], rows)
}

fn verdict_cell(result: StepResult) -> String {
  case result.status {
    Run ->
      case result.verdict, result.severity {
        Anomaly, Some(severity) ->
          "anomaly (" <> verdict.severity_to_string(severity) <> ")"
        other, _ -> verdict.verdict_to_string(other)
      }
    _ -> "-"
  }
}

fn coverage(report: Report) -> String {
  let line = fn(result: StepResult) {
    "Step "
    <> int.to_string(result.id)
    <> " ("
    <> title(result.id)
    <> "): "
    <> option.unwrap(result.reason, "no reason recorded")
  }
  let section = fn(heading: String, results: List(StepResult)) {
    case results {
      [] -> heading <> ": none."
      _ -> heading <> ":\n\n" <> bullets(list.map(results, line))
    }
  }
  "## Coverage\n\nA step listed here is not evidence of clean behaviour.\n\n"
  <> string.join(
    [
      section("Did not run", model.not_run(report)),
      section("Ran but inconclusive", model.inconclusive(report)),
      section("Crashed", model.crashed(report)),
    ],
    "\n\n",
  )
}

fn step_section(result: StepResult) -> String {
  let heading = "## " <> int.to_string(result.id) <> ". " <> title(result.id)
  let facts = case result.status {
    Run ->
      "**Verdict:** "
      <> verdict_cell(result)
      <> " - "
      <> meaning(result.verdict)
      <> "\n\n"
      <> escape_inline(result.summary)
    status ->
      "**Status:** "
      <> verdict.status_to_string(status)
      <> " ("
      <> option.unwrap(result.reason, "no reason recorded")
      <> "). Not run, so nothing is known from this step."
  }
  let findings = case result.findings {
    [] -> []
    findings -> [
      bullets(
        list.map(findings, fn(finding) {
          "**"
          <> step.finding_level_to_string(finding.level)
          <> ":** "
          <> escape_inline(finding.text)
        }),
      ),
    ]
  }
  let error_rate = case result.error_rate {
    Some(rate) -> [
      "**Error rate:** "
      <> rate.kind
      <> " "
      <> percent(rate.bound)
      <> " ("
      <> rate.basis
      <> ").",
    ]
    None -> []
  }
  let details = list.map(result.details, block)
  let footer = case result.status {
    Run -> [
      "_Requests: "
      <> int.to_string(result.requests_sent)
      <> " sent, "
      <> int.to_string(result.requests_failed)
      <> " failed. Duration: "
      <> int.to_string(result.duration_ms)
      <> " ms."
      <> references(result.id)
      <> "_",
    ]
    _ -> []
  }
  list.flatten([[heading, facts], findings, error_rate, details, footer])
  |> string.join("\n\n")
}

fn references(id: Int) -> String {
  case catalog.find(id) {
    Ok(catalog.StepInfo(references: [_, ..] as references, ..)) ->
      " Based on " <> string.join(references, ", ") <> "."
    _ -> ""
  }
}

/// What a verdict means, in the fixed wording of the threat model.
pub fn meaning(verdict: Verdict) -> String {
  case verdict {
    Clean -> "no anomaly observed by this step"
    Anomaly -> "the step's rule fired; a reason to investigate, not proof"
    Inconclusive -> "the step could not decide; not counted as clean"
    Informational -> "descriptive only"
  }
}

fn limits(report: Report) -> String {
  "## What this report does not claim\n\n" <> bullets(report.limits)
}

fn title(id: Int) -> String {
  case catalog.find(id) {
    Ok(info) -> info.title
    Error(Nil) -> "Unknown step"
  }
}

fn block(block: Block) -> String {
  case block {
    Paragraph(text) -> escape_inline(text)
    Table(headers, rows) -> table(headers, rows)
    Code(text) -> fenced("", text)
    Bullets(items) -> bullets(list.map(items, escape_inline))
    Mermaid(source) -> fenced("mermaid", source)
  }
}

fn bullets(items: List(String)) -> String {
  list.map(items, fn(item) { "- " <> one_line(item) }) |> string.join("\n")
}

/// A fenced block whose fence is longer than any backtick run inside it.
pub fn fenced(language: String, text: String) -> String {
  let fence = string.repeat("`", int.max(3, longest_backtick_run(text) + 1))
  fence <> language <> "\n" <> text <> "\n" <> fence
}

fn longest_backtick_run(text: String) -> Int {
  string.to_graphemes(text)
  |> list.fold(#(0, 0), fn(acc, grapheme) {
    let #(longest, current) = acc
    case grapheme {
      "`" -> #(int.max(longest, current + 1), current + 1)
      _ -> #(longest, 0)
    }
  })
  |> fn(pair) { pair.0 }
}

pub fn table(headers: List(String), rows: List(List(String))) -> String {
  let row = fn(cells: List(String)) {
    "| " <> string.join(list.map(cells, cell), " | ") <> " |"
  }
  let rule = "|" <> string.repeat(" --- |", list.length(headers))
  [row(headers), rule, ..list.map(rows, row)] |> string.join("\n")
}

/// Make text safe inside a table cell.
pub fn cell(text: String) -> String {
  one_line(text) |> string.replace("|", "\\|")
}

fn one_line(text: String) -> String {
  text
  |> string.replace("\r\n", " ")
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
}

/// Keep endpoint-supplied text from being read as Markdown structure.
fn escape_inline(text: String) -> String {
  text |> string.replace("<", "&lt;")
}

fn code_span(text: String) -> String {
  "`" <> string.replace(text, "`", "'") <> "`"
}

fn percent(fraction: Float) -> String {
  let scaled = float.to_precision(fraction *. 100.0, 2)
  "at most " <> float.to_string(scaled) <> "%"
}
