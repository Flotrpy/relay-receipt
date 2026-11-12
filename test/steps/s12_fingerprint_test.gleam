import gleam/option.{None, Some}
import gleam/string
import receipt/http/types as http
import receipt/steps/s12_fingerprint.{Confirmed, Tentative} as s12
import receipt/verdict.{Inconclusive, Informational}
import support/fake
import support/world

fn response(headers: List(#(String, String)), body: String) -> http.Response {
  http.Response(200, headers, <<body:utf8>>, [], http.Timing(None, None, None))
}

pub fn header_prefix_markers_test() {
  assert s12.match_response(response([#("x-litellm-version", "1.2")], ""))
    == ["litellm"]
  assert s12.match_response(response([#("Helicone-Id", "abc")], ""))
    == ["helicone"]
  assert s12.match_response(response([#("cf-aig-cache-status", "MISS")], ""))
    == ["cloudflare-ai-gateway"]
}

pub fn body_markers_are_case_insensitive_test() {
  assert s12.match_response(response([], "<title>New API</title>"))
    == ["new-api"]
  assert s12.match_response(response([], "Powered by One-API")) == ["one-api"]
}

pub fn server_header_markers_test() {
  assert s12.match_response(response([#("server", "nginx/1.25.3")], ""))
    == ["nginx"]
  assert s12.match_response(response(
      [#("Server", "cloudflare"), #("cf-ray", "8a")],
      "",
    ))
    == ["cloudflare"]
}

pub fn several_layers_can_match_at_once_test() {
  assert s12.match_response(response(
      [#("x-litellm-call-id", "1"), #("server", "cloudflare")],
      "",
    ))
    == ["litellm", "cloudflare"]
}

pub fn nothing_known_matches_nothing_test() {
  assert s12.match_response(response([#("server", "gunicorn")], "{}")) == []
}

pub fn two_of_three_is_confirmed_one_is_tentative_test() {
  assert s12.aggregate([["new-api", "nginx"], ["new-api"], ["nginx"]])
    == [#("new-api", Confirmed), #("nginx", Confirmed)]
  assert s12.aggregate([["litellm"], [], []]) == [#("litellm", Tentative)]
  assert s12.aggregate([[], [], []]) == []
}

pub fn recognised_gateway_is_informational_with_a_note_test() {
  let landing = response([#("server", "nginx")], "<title>New API</title>")
  let models =
    response([#("server", "nginx"), #("x-new-api-version", "0.4")], "{}")
  let result =
    s12.build([
      #("landing page", Some(landing)),
      #("model list", Some(models)),
      #("missing path", None),
    ])
  assert result.verdict == Informational
  assert string.contains(result.summary, "new-api (confirmed)")
  assert string.contains(result.summary, "nginx (confirmed)")
  let assert [_] = result.findings
}

pub fn unrecognised_stack_is_informational_test() {
  let result = s12.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Informational
  assert string.contains(result.summary, "No known gateway")
}

pub fn no_responses_is_inconclusive_test() {
  let result = s12.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_responses")
}

pub fn requests_carry_no_credentials_test() {
  let ctx =
    world.ctx(fn(_, request: http.Request) {
      case request.headers {
        [] -> fake.json_reply(200, "{}")
        _ -> panic as "fingerprint probes must be unauthenticated"
      }
    })
  assert s12.run(ctx).verdict == Informational
}
