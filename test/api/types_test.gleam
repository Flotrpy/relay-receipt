import gleam/option.{None, Some}
import receipt/api/types.{Anthropic, OpenAi, Usage}

pub fn simple_params_have_one_user_message_test() {
  let params = types.simple("m", "hi", 16)
  assert params.messages == [types.Message("user", "hi")]
  assert params.system == None
  assert params.temperature == None
  assert params.tools == []
  assert !params.stream
}

pub fn builders_set_their_field_test() {
  let params =
    types.simple("m", "hi", 16)
    |> types.with_system("be brief")
    |> types.with_temperature(0.0)
    |> types.streaming
  assert params.system == Some("be brief")
  assert params.temperature == Some(0.0)
  assert params.stream
}

pub fn format_strings_round_trip_test() {
  assert types.format_from_string(types.format_to_string(OpenAi)) == Ok(OpenAi)
  assert types.format_from_string(types.format_to_string(Anthropic))
    == Ok(Anthropic)
  assert types.format_from_string("gemini") == Error(Nil)
}

pub fn visible_tokens_subtract_reported_reasoning_test() {
  assert types.visible_output_tokens(Usage(None, Some(100), None, Some(30)))
    == Some(70)
  assert types.visible_output_tokens(Usage(None, Some(100), None, None))
    == Some(100)
  assert types.visible_output_tokens(Usage(None, None, None, Some(30))) == None
}

pub fn reasoning_larger_than_total_is_not_subtracted_test() {
  assert types.visible_output_tokens(Usage(None, Some(10), None, Some(30)))
    == Some(10)
}
