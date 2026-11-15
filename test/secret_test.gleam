import envoy
import gleam/string
import qcheck
import receipt/secret

const key = "sk-live-abcdefghijklmnopqrstuvwxyz012345"

pub fn missing_variable_is_an_error_test() {
  envoy.unset("RECEIPT_TEST_MISSING_KEY")
  assert secret.from_env("RECEIPT_TEST_MISSING_KEY")
    == Error(secret.Missing("RECEIPT_TEST_MISSING_KEY"))
}

pub fn empty_variable_is_an_error_test() {
  envoy.set("RECEIPT_TEST_EMPTY_KEY", "   ")
  assert secret.from_env("RECEIPT_TEST_EMPTY_KEY")
    == Error(secret.Empty("RECEIPT_TEST_EMPTY_KEY"))
  envoy.unset("RECEIPT_TEST_EMPTY_KEY")
}

pub fn key_is_read_and_trimmed_test() {
  envoy.set("RECEIPT_TEST_KEY", "  " <> key <> "\n")
  let assert Ok(loaded) = secret.from_env("RECEIPT_TEST_KEY")
  assert secret.expose(loaded) == key
  assert secret.length(loaded) == string.length(key)
  envoy.unset("RECEIPT_TEST_KEY")
}

pub fn inspecting_a_secret_does_not_show_the_key_test() {
  let shown = string.inspect(secret.from_string(key))
  assert !string.contains(shown, "abcdefgh")
  assert !string.contains(shown, key)
}

pub fn stand_in_has_requested_length_and_prefix_test() {
  assert secret.stand_in(40) |> string.length == 40
  assert secret.stand_in(40)
    |> string.starts_with("sk-receipt-0123456789abcdef")
  assert secret.stand_in(5) == "sk-re"
  assert secret.stand_in(0) == ""
}

pub fn full_key_is_replaced_by_stand_in_test() {
  let secret_key = secret.from_string(key)
  let redacted = secret.redact("Bearer " <> key <> " rejected", secret_key)
  assert redacted
    == "Bearer " <> secret.stand_in(string.length(key)) <> " rejected"
}

pub fn fragment_is_replaced_by_same_positions_test() {
  let secret_key = secret.from_string(key)
  let fragment = string.slice(key, 10, 12)
  let redacted = secret.redact("tail=" <> fragment, secret_key)
  assert redacted
    == "tail=" <> string.slice(secret.stand_in(string.length(key)), 10, 12)
}

pub fn short_fragments_are_left_alone_test() {
  let secret_key = secret.from_string(key)
  let text = "prefix " <> string.slice(key, 0, 7)
  assert secret.redact(text, secret_key) == text
}

pub fn text_without_the_key_is_unchanged_test() {
  let secret_key = secret.from_string(key)
  assert secret.redact("{\"error\":\"bad model\"}", secret_key)
    == "{\"error\":\"bad model\"}"
}

pub fn every_occurrence_is_redacted_test() {
  let secret_key = secret.from_string(key)
  let redacted = secret.redact(key <> " and " <> key, secret_key)
  assert !string.contains(redacted, "abcdefgh")
}

pub fn redaction_leaves_no_sensitive_fragment_test() {
  use #(before, after, start, size) <- qcheck.given(qcheck.tuple4(
    qcheck.string_from(qcheck.alphabetic_ascii_codepoint()),
    qcheck.string_from(qcheck.alphabetic_ascii_codepoint()),
    qcheck.bounded_int(0, 20),
    qcheck.bounded_int(8, 20),
  ))
  let secret_key = secret.from_string(key)
  let fragment = string.slice(key, start, size)
  let redacted =
    secret.redact(before <> " " <> fragment <> " " <> after, secret_key)
  assert !string.contains(redacted, fragment)
}

pub fn redaction_is_idempotent_test() {
  let secret_key = secret.from_string(key)
  let once = secret.redact("x " <> key <> " y", secret_key)
  assert secret.redact(once, secret_key) == once
}

pub fn longest_fragment_measures_the_leak_test() {
  let secret_key = secret.from_string(key)
  assert secret.longest_fragment("nothing here", secret_key) == 0
  assert secret.longest_fragment(key, secret_key) == string.length(key)
  assert secret.longest_fragment("..." <> string.slice(key, 5, 14), secret_key)
    == 14
  assert secret.longest_fragment(string.slice(key, 0, 7), secret_key) == 0
}

pub fn errors_name_the_variable_not_a_value_test() {
  assert secret.describe_error(secret.Missing("RECEIPT_API_KEY"))
    == "environment variable RECEIPT_API_KEY is not set"
}
