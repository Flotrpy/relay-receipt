import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import receipt/report/json as report_json
import support/sample

fn rendered() -> String {
  report_json.render(sample.report())
}

fn at(path: List(String), decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = json.parse(rendered(), decode.at(path, decoder))
  value
}

pub fn output_is_one_valid_json_document_test() {
  let assert Ok(_) = json.parse(rendered(), decode.dynamic)
  assert !string.contains(rendered(), "\n")
}

pub fn top_level_fields_match_the_schema_test() {
  assert at(["schema_version"], decode.int) == 1
  assert at(["report_type"], decode.string) == "audit"
  assert at(["tool", "name"], decode.string) == "receipt"
  assert at(["profile"], decode.string) == "general"
  assert at(["seed"], decode.int) == 42
  assert at(["target", "base_url"], decode.string) == "https://relay.example/v1"
  assert at(["target", "api_format"], decode.string) == "openai"
}

pub fn rating_carries_rule_and_reasons_test() {
  assert at(["risk_level"], decode.string) == "MEDIUM"
  assert at(["rating", "rule"], decode.int) == 4
  assert at(["rating", "reasons"], decode.list(decode.string)) != []
}

pub fn every_step_is_listed_with_status_and_verdict_test() {
  let steps =
    at(
      ["steps"],
      decode.list({
        use id <- decode.field("id", decode.int)
        use status <- decode.field("status", decode.string)
        use verdict <- decode.field("verdict", decode.string)
        decode.success(#(id, status, verdict))
      }),
    )
  assert list.contains(steps, #(3, "run", "clean"))
  assert list.contains(steps, #(9, "run", "anomaly"))
  assert list.contains(steps, #(16, "profile_gated", "inconclusive"))
  assert list.contains(steps, #(17, "not_applicable", "inconclusive"))
}

pub fn step_objects_have_class_key_and_references_test() {
  assert string.contains(
    rendered(),
    "\"id\":15,\"key\":\"inflation\",\"title\":\"Inflation probe\",\"class\":\"major\"",
  )
  assert string.contains(rendered(), "\"arXiv:2609.20370\"")
  assert string.contains(rendered(), "\"severity\":\"medium\"")
  assert string.contains(
    rendered(),
    "\"error_rate\":{\"kind\":\"false_positive\",\"bound\":0.0002,",
  )
  assert string.contains(rendered(), "\"data\":{\"modal_offset\":0}")
}

pub fn coverage_lists_not_run_inconclusive_and_crashed_test() {
  assert at(["coverage", "inconclusive"], decode.list(decode.int)) == [10]
  assert at(["coverage", "crashed"], decode.list(decode.int)) == []
  assert at(["coverage", "not_run"], decode.list(decode.at(["id"], decode.int)))
    == [16, 17]
  assert string.contains(
    rendered(),
    "{\"id\":17,\"status\":\"not_applicable\",\"reason\":\"no_reference\"}",
  )
}

pub fn limits_are_always_present_test() {
  let limits = at(["limits"], decode.list(decode.string))
  assert list.any(limits, string.contains(_, "not a safety certificate"))
  assert list.any(limits, string.contains(_, "hidden reasoning tokens"))
}
