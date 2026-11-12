import gleam/option.{None, Some}
import gleam/string
import receipt/http/types as http
import receipt/steps/s14_channel.{Classification, Evidence} as s14
import receipt/verdict.{Inconclusive, Informational}
import support/fake
import support/script
import support/world

fn evidence(
  headers: List(#(String, String)),
  message_id: String,
  body: String,
) {
  Evidence(headers, message_id, body)
}

pub fn tier_one_markers_decide_alone_test() {
  assert s14.classify(evidence([], "gen-1762900000-abc", ""))
    == Classification(Some("openrouter"), 1.0, 1)
  assert s14.classify(evidence([#("cf-aig-cache-status", "miss")], "x", ""))
    == Classification(Some("cloudflare-ai-gateway"), 1.0, 1)
  assert s14.classify(evidence(
      [#("x-groq-region", "us-east")],
      "chatcmpl-1",
      "",
    ))
    == Classification(Some("groq"), 1.0, 1)
  assert s14.classify(evidence([], "msg_bdrk_01abc", ""))
    == Classification(Some("aws-bedrock"), 1.0, 1)
  assert s14.classify(evidence([], "msg_vrtx_01abc", ""))
    == Classification(Some("google-vertex"), 1.0, 1)
}

pub fn tier_two_weights_accumulate_and_cap_at_one_test() {
  let anthropic =
    s14.classify(evidence(
      [#("anthropic-ratelimit-requests-limit", "50"), #("request-id", "req_01")],
      "",
      "",
    ))
  assert anthropic == Classification(Some("anthropic"), 1.0, 2)
  let openai =
    s14.classify(evidence([#("openai-processing-ms", "120")], "chatcmpl-9", ""))
  assert openai == Classification(Some("openai"), 1.0, 2)
}

pub fn weak_tier_two_evidence_names_no_channel_test() {
  // A chatcmpl- id alone scores 0.2: many gateways mint such ids.
  let weak = s14.classify(evidence([], "chatcmpl-abc", ""))
  assert weak.channel == None
  assert weak.confidence == 0.2
}

pub fn body_markers_count_in_tier_two_test() {
  assert s14.classify(evidence(
      [],
      "",
      "{\"anthropic_version\":\"bedrock-2023-05-31\"}",
    ))
    == Classification(Some("aws-bedrock"), 0.9, 2)
}

pub fn native_anthropic_id_alone_is_a_tier_three_inference_test() {
  assert s14.classify(evidence([], "msg_01XFDUDYJgAACzvnptvVoYEL", ""))
    == Classification(Some("anthropic-passthrough"), 0.5, 3)
}

pub fn nothing_recognised_test() {
  assert s14.classify(evidence([#("server", "nginx")], "abc", "{}"))
    == Classification(None, 0.0, 0)
}

pub fn evidence_is_lower_cased_and_reads_the_id_test() {
  let assert Ok(response) =
    script.reply(
      200,
      [#("X-Groq-Region", "US-East")],
      "{\"id\":\"chatcmpl-7\"}",
    )
  let found = s14.evidence_from(response)
  assert found.headers == [#("x-groq-region", "us-east")]
  assert found.message_id == "chatcmpl-7"
}

pub fn recognised_channel_is_informational_test() {
  let result = s14.build(evidence([#("x-groq-region", "us")], "chatcmpl-1", ""))
  assert result.verdict == Informational
  assert string.contains(result.summary, "groq")
}

pub fn unrecognised_channel_is_informational_too_test() {
  let result = s14.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Informational
  assert string.contains(result.summary, "No serving-channel markers")
}

pub fn failed_request_is_inconclusive_test() {
  let result = s14.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_authenticated_response")
  let refused = s14.run(world.ctx(fn(_, _) { script.reply(401, [], "{}") }))
  assert refused.verdict == Inconclusive
}

pub fn the_report_shows_only_the_start_of_the_id_test() {
  let result = s14.build(evidence([], "chatcmpl-0123456789abcdefghij", ""))
  assert !string.contains(
    string.inspect(result.details),
    "0123456789abcdefghij",
  )
}
