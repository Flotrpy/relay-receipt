//// A small synthetic report used by reporter tests.

import gleam/json
import gleam/option.{None, Some}
import receipt/rating
import receipt/report/block
import receipt/report/model.{EndpointInfo, Report}
import receipt/step
import receipt/verdict.{
  Anomaly, Clean, Informational, Medium, NotApplicable, ProfileGated,
}

pub fn steps() -> List(step.StepResult) {
  [
    step.ran(2, Informational, "OpenAI-compatible chat answers.")
      |> step.with_requests(sent: 2, failed: 0),
    step.ran(3, Clean, "Billed prompt tokens match the reference.")
      |> step.with_data("modal_offset", json.int(0))
      |> step.with_details([
        block.Table(["Text", "Endpoint", "Reference"], [["a|b", "12", "12"]]),
      ]),
    step.ran(9, Anomaly, "A filesystem path appears in an error body.")
      |> step.with_severity(Medium)
      |> step.with_finding(step.Signal, "path /app/server.py in body")
      |> step.with_details([
        block.Code("Traceback ```\nFile \"/app/server.py\""),
      ]),
    step.inconclusive(10, "no_stream", "The endpoint did not stream."),
    step.ran(15, Clean, "No PTIA-consistent signal.")
      |> step.with_error_rate(step.ErrorRate(
        "false_positive",
        0.0002,
        "paper, no system prompt",
      )),
    step.not_run(16, ProfileGated, "full_profile_only"),
    step.not_run(17, NotApplicable, "no_reference"),
  ]
}

pub fn report() -> model.Report {
  let steps = steps()
  Report(
    generated_at: "2026-11-10T04:00:00Z",
    tool_version: "0.1.0",
    profile: "general",
    seed: 42,
    target: EndpointInfo(
      "target",
      "https://relay.example/v1",
      "m-1",
      Some("openai"),
    ),
    reference: None,
    endpoints: [],
    rating: rating.rate(steps),
    steps: steps,
    limits: model.limits_for(steps),
  )
}
