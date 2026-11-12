import gleam/list
import gleam/option.{Some}
import gleam/string
import receipt/api/types.{Anthropic, OpenAi}
import receipt/http/types as http
import receipt/sse
import receipt/step
import receipt/steps/s10_stream as s10
import receipt/verdict.{Anomaly, Clean, Inconclusive}
import support/fake.{Fake}
import support/script
import support/world

fn run(fault: String) {
  s10.run(world.ctx(fake.handler(Fake(..fake.honest(), stream_fault: fault))))
}

const good_anthropic =
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-x\",\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"1 2 3\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

fn anthropic(text: String) {
  s10.analyse_anthropic(sse.parse_text(text))
}

pub fn honest_openai_stream_is_clean_test() {
  let result = run("")
  assert result.verdict == Clean
  assert result.findings == []
}

pub fn each_openai_fault_breaks_its_rule_test() {
  [
    #("bad_json", "Rule 1"),
    #("no_done", "Rule 2"),
    #("after_done", "Rule 2"),
    #("two_ids", "Rule 3"),
    #("model_switch", "Rule 4"),
    #("double_finish", "Rule 5"),
  ]
  |> list.each(fn(pair) {
    let result = run(pair.0)
    assert result.verdict == Anomaly
    assert string.contains(result.summary, pair.1)
  })
}

pub fn decreasing_usage_breaks_rule_six_test() {
  let text =
    "data: {\"id\":\"a\",\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":9}}\n\ndata: {\"id\":\"a\",\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}\n\ndata: [DONE]\n\n"
  let analysis = s10.analyse_openai(sse.parse_text(text))
  let assert [violation] = analysis.violations
  assert string.starts_with(violation, "Rule 6")
}

pub fn a_final_usage_chunk_without_choices_is_fine_test() {
  let text =
    "data: {\"id\":\"a\",\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"a\",\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"id\":\"a\",\"model\":\"m\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
  assert s10.analyse_openai(sse.parse_text(text)).violations == []
}

pub fn comment_lines_are_allowed_anywhere_test() {
  let text =
    ": keep-alive\n\ndata: {\"id\":\"a\",\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}]}\n\n: processing\n\ndata: [DONE]\n\n: bye\n\n"
  assert s10.analyse_openai(sse.parse_text(text)).violations == []
}

pub fn honest_anthropic_stream_has_no_violations_test() {
  let analysis = anthropic(good_anthropic)
  assert analysis.violations == []
  assert analysis.model == Some("claude-x")
  assert analysis.events == 7
}

pub fn anthropic_unknown_event_breaks_rule_one_test() {
  let analysis =
    anthropic(string.replace(
      good_anthropic,
      "event: ping\ndata: {\"type\":\"ping\"}",
      "event: injected\ndata: {\"type\":\"injected\"}",
    ))
  let assert [violation] = analysis.violations
  assert string.contains(violation, "injected")
}

pub fn anthropic_changed_input_tokens_breaks_rule_two_test() {
  let analysis =
    anthropic(string.replace(
      good_anthropic,
      "\"usage\":{\"output_tokens\":9}",
      "\"usage\":{\"input_tokens\":900,\"output_tokens\":9}",
    ))
  let assert [violation] = analysis.violations
  assert string.starts_with(violation, "Rule 2")
}

pub fn anthropic_decreasing_output_tokens_breaks_rule_three_test() {
  let analysis =
    anthropic(string.replace(
      good_anthropic,
      "\"output_tokens\":9",
      "\"output_tokens\":0",
    ))
  let assert [violation] = analysis.violations
  assert string.starts_with(violation, "Rule 3")
}

pub fn anthropic_missing_or_trailing_stop_breaks_rule_four_test() {
  let missing =
    anthropic(string.replace(
      good_anthropic,
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
      "",
    ))
  assert list.any(missing.violations, string.contains(_, "no message_stop"))
  let trailing =
    anthropic(
      good_anthropic
      <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\"}\n\n",
    )
  assert list.any(trailing.violations, string.contains(_, "follow message_stop"))
  let ping_after =
    anthropic(good_anthropic <> "event: ping\ndata: {\"type\":\"ping\"}\n\n")
  assert ping_after.violations == []
}

pub fn anthropic_empty_signature_breaks_rule_five_test() {
  let analysis =
    anthropic(string.replace(
      good_anthropic,
      "{\"type\":\"text_delta\",\"text\":\"1 2 3\"}",
      "{\"type\":\"signature_delta\",\"signature\":\"\"}",
    ))
  let assert [violation] = analysis.violations
  assert string.starts_with(violation, "Rule 5")
}

pub fn transport_failure_is_inconclusive_test() {
  let result = s10.build(OpenAi, "m", Error(http.Timeout))
  assert result.verdict == Inconclusive
  assert result.reason == Some("stream_failed")
}

pub fn refused_stream_is_inconclusive_test() {
  let result =
    s10.build(
      OpenAi,
      "m",
      script.reply(400, [], "{\"error\":\"no streaming\"}"),
    )
  assert result.reason == Some("stream_refused")
}

pub fn non_stream_body_is_inconclusive_test() {
  let result = s10.build(OpenAi, "m", script.ok("{\"choices\":[]}"))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_events")
}

pub fn truncated_stream_is_an_anomaly_test() {
  let result =
    s10.build(
      OpenAi,
      "m",
      script.reply(
        200,
        [#("content-type", "text/event-stream")],
        "data: {\"id\":\"a\",\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\ndata: {\"id\":\"a\"",
      ),
    )
  assert result.verdict == Anomaly
}

pub fn a_different_model_name_is_noted_not_judged_test() {
  let result =
    s10.build(
      OpenAi,
      "short-name",
      script.reply(
        200,
        [#("content-type", "text/event-stream")],
        "data: {\"id\":\"a\",\"model\":\"vendor/short-name-001\",\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
      ),
    )
  assert result.verdict == Clean
  let assert [step.Finding(step.Note, note)] = result.findings
  assert string.contains(note, "recorded, not judged")
}

pub fn anthropic_format_uses_the_anthropic_rules_test() {
  let result =
    s10.build(
      Anthropic,
      "claude-x",
      script.reply(
        200,
        [#("content-type", "text/event-stream")],
        good_anthropic,
      ),
    )
  assert result.verdict == Clean
}
