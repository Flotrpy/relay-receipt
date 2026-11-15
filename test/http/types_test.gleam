import gleam/list
import gleam/option.{None}
import receipt/http/types.{
  Closed, Connect, Get, Head, Other, Post, Response, Timeout, Timing, Tls,
  TraceMiss,
}

fn response(status: Int, body: BitArray) {
  Response(
    status: status,
    headers: [#("content-type", "application/json"), #("x-request-id", "r1")],
    body: body,
    chunks: [],
    timing: Timing(None, None, None),
  )
}

pub fn method_strings_round_trip_test() {
  [Get, Post, Head]
  |> list.each(fn(method) {
    assert types.method_from_string(types.method_to_string(method))
      == Ok(method)
  })
  assert types.method_from_string("DELETE") == Error(Nil)
}

pub fn header_lookup_ignores_case_test() {
  let headers = response(200, <<>>).headers
  assert types.header(headers, "Content-Type") == Ok("application/json")
  assert types.header(headers, "X-REQUEST-ID") == Ok("r1")
  assert types.header(headers, "missing") == Error(Nil)
}

pub fn header_lookup_returns_first_of_repeated_test() {
  assert types.header(
      [#("set-cookie", "a"), #("set-cookie", "b")],
      "set-cookie",
    )
    == Ok("a")
}

pub fn body_text_decodes_utf8_test() {
  assert types.body_text(response(200, <<"héllo":utf8>>)) == "héllo"
}

pub fn body_text_of_invalid_utf8_is_empty_test() {
  assert types.body_text(response(200, <<0xFF, 0xFE>>)) == ""
}

pub fn success_is_the_2xx_range_test() {
  assert types.is_success(response(200, <<>>))
  assert types.is_success(response(204, <<>>))
  assert !types.is_success(response(199, <<>>))
  assert !types.is_success(response(301, <<>>))
  assert !types.is_success(response(429, <<>>))
}

pub fn error_kinds_match_the_trace_format_test() {
  assert types.error_kind(Timeout) == "timeout"
  assert types.error_kind(Connect("x")) == "connect"
  assert types.error_kind(Tls("x")) == "tls"
  assert types.error_kind(Closed("x")) == "closed"
  assert types.error_kind(Other("x")) == "other"
  assert types.error_kind(TraceMiss("x")) == "trace_miss"
}

pub fn describe_error_includes_detail_when_present_test() {
  assert types.describe_error(Timeout) == "timeout"
  assert types.describe_error(Connect("refused")) == "connect: refused"
}
