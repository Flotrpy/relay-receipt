import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/http/types as http
import receipt/net
import receipt/report/block
import receipt/step
import receipt/steps/s01_recon
import receipt/trace/replayer
import receipt/verdict.{Inconclusive, Informational}
import support/script
import support/world

fn landing(status: Int) {
  script.reply(
    status,
    [
      #("server", "nginx"),
      #("set-cookie", "secret=1"),
      #("x-powered-by", "new-api"),
    ],
    "<html><title>Relay</title></html>",
  )
}

pub fn resolving_host_is_informational_test() {
  let result =
    s01_recon.build("relay.example", "A 203.0.113.7", None, Error(http.Timeout))
  assert result.verdict == Informational
  assert result.id == 1
}

pub fn answering_host_is_informational_even_without_dns_test() {
  let result =
    s01_recon.build("relay.example", net.no_records, None, landing(200))
  assert result.verdict == Informational
}

pub fn silent_unresolved_host_is_inconclusive_test() {
  let result =
    s01_recon.build("relay.example", net.no_records, None, Error(http.Timeout))
  assert result.verdict == Inconclusive
  assert result.reason == Some("host_unresolved")
}

pub fn unrecorded_dns_does_not_count_as_resolved_test() {
  assert !s01_recon.resolved(replayer.not_recorded)
  assert !s01_recon.resolved(net.no_records)
  assert s01_recon.resolved("A 192.0.2.1")
}

pub fn only_informative_headers_are_shown_test() {
  let result = s01_recon.build("h", "A 192.0.2.1", None, landing(200))
  let assert Ok(block.Table(_, rows)) =
    list.find(result.details, fn(b) {
      case b {
        block.Table(..) -> True
        _ -> False
      }
    })
  assert rows == [["server", "nginx"], ["x-powered-by", "new-api"]]
}

pub fn tls_failure_is_noted_not_judged_test() {
  let result =
    s01_recon.build(
      "h",
      "A 192.0.2.1",
      Some("error: {tls_alert,{unknown_ca,[]}}"),
      landing(200),
    )
  assert result.verdict == Informational
  let assert [step.Finding(step.Note, text)] = result.findings
  assert string.contains(text, "unknown_ca")
}

pub fn readable_certificate_adds_no_finding_test() {
  let result =
    s01_recon.build(
      "h",
      "A 192.0.2.1",
      Some("subject CN=h\nissuer CN=ca"),
      landing(200),
    )
  assert result.findings == []
}

pub fn run_requests_the_origin_not_the_api_path_test() {
  let scripted = script.start([landing(200)])
  let base = world.ctx(script.handler(scripted))
  let ctx = world.with_target_url(base, "http://localhost:18999/v1")
  let result = s01_recon.run(ctx)
  assert result.verdict == Informational
  let assert [request] = script.seen(scripted)
  assert request.url == "http://localhost:18999"
  assert request.method == http.Get
}

pub fn url_without_host_is_inconclusive_test() {
  let ctx =
    world.with_target_url(
      world.ctx(fn(_, _) { Error(http.Timeout) }),
      "not a url",
    )
  let result = s01_recon.run(ctx)
  assert result.reason == Some("bad_url")
}

pub fn dns_lookup_of_localhost_finds_an_address_test() {
  assert string.contains(net.dns_text("localhost"), "127.0.0.1")
}

pub fn tls_lookup_failure_is_reported_as_text_test() {
  assert string.starts_with(net.tls_text("127.0.0.1", 9), "error: ")
}
