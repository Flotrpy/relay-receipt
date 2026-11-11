import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import receipt/jsonx

fn parse(text: String, decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = json.parse(text, decoder)
  value
}

pub fn present_value_is_some_test() {
  assert parse("{\"a\":{\"b\":7}}", jsonx.optional_int(["a", "b"])) == Some(7)
  assert parse("{\"s\":\"x\"}", jsonx.optional_string(["s"])) == Some("x")
}

pub fn missing_key_is_none_test() {
  assert parse("{}", jsonx.optional_int(["a", "b"])) == None
  assert parse("{\"a\":{}}", jsonx.optional_int(["a", "b"])) == None
}

pub fn null_is_none_test() {
  assert parse("{\"a\":null}", jsonx.optional_int(["a"])) == None
  assert parse("{\"a\":null}", jsonx.optional_int(["a", "b"])) == None
}

pub fn wrong_type_is_none_test() {
  assert parse("{\"a\":\"seven\"}", jsonx.optional_int(["a"])) == None
  assert parse("{\"a\":7}", jsonx.optional_int(["a", "b"])) == None
  assert parse("[1,2]", jsonx.optional_int(["a"])) == None
}

pub fn string_or_falls_back_test() {
  assert parse("{}", jsonx.string_or(["id"], "none")) == "none"
  assert parse("{\"id\":\"x1\"}", jsonx.string_or(["id"], "none")) == "x1"
}

pub fn list_or_empty_test() {
  assert parse("{\"xs\":[1,2]}", jsonx.list_or_empty(["xs"], decode.int))
    == [1, 2]
  assert parse("{}", jsonx.list_or_empty(["xs"], decode.int)) == []
  assert parse("{\"xs\":null}", jsonx.list_or_empty(["xs"], decode.int)) == []
  assert parse("{\"xs\":[1,\"a\"]}", jsonx.list_or_empty(["xs"], decode.int))
    == []
}

pub fn any_round_trips_nested_values_test() {
  let text = "{\"a\":[1,2.5,\"x\",true,null],\"b\":{\"c\":\"d\"}}"
  assert json.to_string(parse(text, jsonx.any())) == text
}

pub fn any_sorts_object_keys_test() {
  assert json.to_string(parse("{\"b\":1,\"a\":2}", jsonx.any()))
    == "{\"a\":2,\"b\":1}"
}

pub fn raw_at_serialises_a_fragment_test() {
  assert parse("{\"input\":{\"cmd\":\"ls\"}}", jsonx.raw_at(["input"]))
    == Some("{\"cmd\":\"ls\"}")
  assert parse("{}", jsonx.raw_at(["input"])) == None
}
