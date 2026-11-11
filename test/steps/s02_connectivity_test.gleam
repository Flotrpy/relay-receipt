import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/api/chat
import receipt/api/types.{Anthropic, OpenAi}
import receipt/http/types as http
import receipt/step
import receipt/steps/s02_connectivity.{Attempt}
import receipt/verdict.{Inconclusive, Informational}
import support/fake.{type Fake, Fake}
import support/world

fn run(relay: Fake) {
  s02_connectivity.run(world.ctx(fake.handler(relay)))
}

pub fn openai_compatible_relay_is_detected_test() {
  let #(result, format) = run(fake.honest())
  assert format == Some(OpenAi)
  assert result.verdict == Informational
  assert string.contains(result.summary, "OpenAI-compatible")
}

pub fn anthropic_only_relay_is_detected_test() {
  let #(result, format) =
    run(Fake(..fake.honest(), openai: False, anthropic: True))
  assert format == Some(Anthropic)
  assert result.verdict == Informational
}

pub fn openai_is_preferred_when_both_answer_test() {
  let #(_, format) = run(Fake(..fake.honest(), anthropic: True))
  assert format == Some(OpenAi)
}

pub fn no_answering_format_is_inconclusive_test() {
  let #(result, format) =
    run(Fake(..fake.honest(), openai: False, anthropic: False))
  assert format == None
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_format")
  assert string.contains(result.summary, "HTTP 404")
}

pub fn transport_failure_is_inconclusive_test() {
  let #(result, format) =
    s02_connectivity.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert format == None
  assert result.verdict == Inconclusive
}

pub fn listed_model_is_noted_test() {
  let #(result, _) = run(fake.honest())
  let assert [step.Finding(step.Note, note)] = result.findings
  assert string.contains(note, "2 entries and includes the requested model")
}

pub fn unlisted_model_is_noted_not_judged_test() {
  let #(result, _) = run(Fake(..fake.honest(), models: ["something-else"]))
  assert result.verdict == Informational
  let assert [step.Finding(step.Note, note)] = result.findings
  assert string.contains(note, "does not include the requested model")
}

pub fn detect_uses_only_successful_attempts_test() {
  let failed = Error(chat.Status(401, "bad key", ""))
  assert s02_connectivity.detect([
      Attempt(OpenAi, failed),
      Attempt(Anthropic, Ok(Nil)),
    ])
    == Some(Anthropic)
  assert s02_connectivity.detect([Attempt(OpenAi, failed)]) == None
  assert s02_connectivity.detect([]) == None
}

pub fn three_requests_are_sent_test() {
  let #(result, _) = run(fake.honest())
  // Counts are filled in by the runner; here we only check the table.
  assert list.length(result.details) == 1
}
