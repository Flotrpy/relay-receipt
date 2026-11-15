//// Step 1: Infrastructure recon.
////
//// Describes the host behind the base URL: DNS records, the TLS
//// certificate it presents, the response headers of its landing page and
//// the first characters of that page. Purely descriptive; the verdict is
//// `informational` unless nothing at all could be learned.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import receipt/api/url
import receipt/client
import receipt/ctx.{type Ctx}
import receipt/http/types as http
import receipt/net
import receipt/report/block.{Code, Paragraph, Table}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/trace/replayer
import receipt/verdict.{Informational}

const id = 1

/// Response headers worth showing: they describe the serving stack.
pub const informative_headers = [
  "server", "via", "x-powered-by", "cf-ray", "x-served-by", "x-cache", "alt-svc",
  "content-type", "strict-transport-security", "x-request-id",
]

const preview_chars = 500

pub fn run(ctx: Ctx) -> StepResult {
  let base = ctx.target.base_url
  case url.host(base) {
    "" -> step.inconclusive(id, "bad_url", "The base URL has no host name.")
    host -> {
      let dns =
        client.observe(ctx.net, id, "dns:" <> host, fn() { net.dns_text(host) })
      let tls = case is_https(base) {
        True -> {
          let port = port_of(base)
          Some(
            client.observe(
              ctx.net,
              id,
              "tls:" <> host <> ":" <> int.to_string(port),
              fn() { net.tls_text(host, port) },
            ),
          )
        }
        False -> None
      }
      let landing =
        ctx.send(
          ctx,
          ctx.target,
          id,
          "landing",
          http.Request(
            http.Get,
            url.origin(base),
            [],
            "",
            thresholds.request_timeout_ms,
          ),
        )
      build(host, dns, tls, landing)
    }
  }
}

fn is_https(base_url: String) -> Bool {
  string.starts_with(string.lowercase(base_url), "https://")
}

fn port_of(base_url: String) -> Int {
  case uri.parse(base_url) {
    Ok(uri.Uri(port: Some(port), ..)) -> port
    _ -> 443
  }
}

/// Whether a DNS observation holds at least one record.
pub fn resolved(dns: String) -> Bool {
  dns != net.no_records && dns != replayer.not_recorded && dns != ""
}

/// Assemble the result from what was observed. Separate from `run` so it
/// can be tested without lookups.
pub fn build(
  host: String,
  dns: String,
  tls: option.Option(String),
  landing: Result(http.Response, http.TransportError),
) -> StepResult {
  let answered = case landing {
    Ok(_) -> True
    Error(_) -> False
  }
  let dns_block = [Paragraph("DNS records for " <> host <> ":"), Code(dns)]
  let tls_block = case tls {
    Some(text) -> [Paragraph("TLS certificate presented:"), Code(text)]
    None -> [
      Paragraph("The base URL is not HTTPS, so no certificate was read."),
    ]
  }
  let http_block = case landing {
    Ok(response) -> [
      Paragraph(
        "Landing page answered HTTP " <> int.to_string(response.status) <> ".",
      ),
      Table(
        ["Header", "Value"],
        response.headers
          |> list.filter(fn(pair) { list.contains(informative_headers, pair.0) })
          |> list.map(fn(pair) { [pair.0, string.slice(pair.1, 0, 120)] }),
      ),
      Code(string.slice(http.body_text(response), 0, preview_chars)),
    ]
    Error(error) -> [
      Paragraph(
        "The landing page did not answer: " <> http.describe_error(error) <> ".",
      ),
    ]
  }
  let details = list.flatten([dns_block, tls_block, http_block])
  let data = fn(result: StepResult) {
    result
    |> step.with_data("host", json.string(host))
    |> step.with_data("dns", json.string(dns))
    |> step.with_data("tls", json.nullable(tls, json.string))
    |> step.with_data(
      "landing_status",
      json.nullable(
        case landing {
          Ok(response) -> Some(response.status)
          Error(_) -> None
        },
        json.int,
      ),
    )
    |> step.with_details(details)
  }
  case resolved(dns) || answered {
    True ->
      step.ran(id, Informational, "Described the host " <> host <> ".")
      |> data
      |> tls_finding(tls)
    False ->
      step.inconclusive(
        id,
        "host_unresolved",
        "The host " <> host <> " did not resolve and did not answer.",
      )
      |> data
  }
}

fn tls_finding(result: StepResult, tls: option.Option(String)) -> StepResult {
  case tls {
    Some("error: " <> detail) ->
      step.with_finding(
        result,
        step.Note,
        "The TLS certificate could not be read directly ("
          <> string.slice(detail, 0, 120)
          <> "). Behind an HTTPS proxy this is expected.",
      )
    _ -> result
  }
}
