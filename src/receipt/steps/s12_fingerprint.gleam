//// Step 12: Infrastructure fingerprint.
////
//// Three unauthenticated GET requests (landing page, model list, a path
//// that should not exist) are matched against markers of known gateway
//// software. Knowing the software tells the user what they are dealing
//// with; arXiv:2603.01919 found most shadow APIs built on two open-source
//// gateways. Descriptive only: the verdict is `informational`.

import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/url
import receipt/client
import receipt/ctx.{type Ctx}
import receipt/http/types as http
import receipt/report/block.{Table}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Informational}

const id = 12

pub type Marker {
  /// Any response header whose name starts with this.
  HeaderPrefix(prefix: String)
  /// A response header with this name whose value contains this text.
  HeaderContains(name: String, text: String)
  /// The response body contains this text.
  BodyContains(text: String)
}

/// Known gateway software and proxies, most specific first.
pub fn signatures() -> List(#(String, List(Marker))) {
  [
    #("litellm", [HeaderPrefix("x-litellm-"), BodyContains("litellm")]),
    #("helicone", [HeaderPrefix("helicone-")]),
    #("portkey", [HeaderPrefix("x-portkey-")]),
    #("kong", [HeaderPrefix("x-kong-"), HeaderContains("server", "kong")]),
    #("new-api", [
      BodyContains("new-api"),
      BodyContains("new api"),
      HeaderPrefix("x-new-api-"),
      HeaderContains("x-powered-by", "new-api"),
    ]),
    #("one-api", [
      BodyContains("one-api"),
      BodyContains("one api"),
      HeaderPrefix("x-oneapi-"),
    ]),
    #("openrouter", [HeaderPrefix("x-openrouter-"), BodyContains("openrouter")]),
    #("cloudflare-ai-gateway", [HeaderPrefix("cf-aig-")]),
    #("azure-api-management", [HeaderPrefix("apim-")]),
    #("cloudflare", [
      HeaderPrefix("cf-ray"),
      HeaderContains("server", "cloudflare"),
    ]),
    #("nginx", [HeaderContains("server", "nginx")]),
    #("caddy", [HeaderContains("server", "caddy")]),
    #("envoy", [HeaderContains("server", "envoy"), HeaderPrefix("x-envoy-")]),
  ]
}

const body_scan_chars = 8192

fn fires(marker: Marker, response: http.Response, lower_body: String) -> Bool {
  case marker {
    HeaderPrefix(prefix) ->
      list.any(response.headers, fn(pair) {
        string.starts_with(string.lowercase(pair.0), prefix)
      })
    HeaderContains(name, text) ->
      list.any(response.headers, fn(pair) {
        string.lowercase(pair.0) == name
        && string.contains(string.lowercase(pair.1), text)
      })
    BodyContains(text) -> string.contains(lower_body, text)
  }
}

/// Every framework whose markers appear in one response.
pub fn match_response(response: http.Response) -> List(String) {
  let lower_body =
    string.lowercase(string.slice(http.body_text(response), 0, body_scan_chars))
  list.filter_map(signatures(), fn(signature) {
    case list.any(signature.1, fires(_, response, lower_body)) {
      True -> Ok(signature.0)
      False -> Error(Nil)
    }
  })
}

pub type Confidence {
  Confirmed
  Tentative
}

/// Frameworks seen in at least two responses are confirmed; in one,
/// tentative. Ordered as in the signature list.
pub fn aggregate(per_probe: List(List(String))) -> List(#(String, Confidence)) {
  let counts =
    list.flatten(per_probe)
    |> list.fold(dict.new(), fn(tally, name) {
      dict.upsert(tally, name, fn(existing) { option.unwrap(existing, 0) + 1 })
    })
  list.filter_map(signatures(), fn(signature) {
    case dict.get(counts, signature.0) {
      Ok(count) if count >= 2 -> Ok(#(signature.0, Confirmed))
      Ok(_) -> Ok(#(signature.0, Tentative))
      Error(Nil) -> Error(Nil)
    }
  })
}

pub fn run(ctx: Ctx) -> StepResult {
  let base = ctx.target.base_url
  let get = fn(label: String, target_url: String) {
    #(
      label,
      // Unauthenticated on purpose, and a single attempt each.
      client.attempt(
        ctx.net,
        ctx.target.name,
        id,
        label,
        http.Request(
          http.Get,
          target_url,
          [],
          "",
          thresholds.request_timeout_ms,
        ),
      )
        |> option.from_result,
    )
  }
  build([
    get("landing page", url.origin(base)),
    get("model list", url.models(base)),
    get("missing path", url.under_root(base, "receipt-fingerprint-404")),
  ])
}

pub fn build(probes: List(#(String, Option(http.Response)))) -> StepResult {
  let matches =
    list.map(probes, fn(probe) {
      case probe.1 {
        Some(response) -> match_response(response)
        None -> []
      }
    })
  let found = aggregate(matches)
  let rows =
    list.zip(probes, matches)
    |> list.map(fn(pair) {
      let #(#(label, response), names) = pair
      [
        label,
        case response {
          Some(response) -> "HTTP " <> int.to_string(response.status)
          None -> "no response"
        },
        case names {
          [] -> "-"
          names -> string.join(names, ", ")
        },
      ]
    })
  let describe = fn(pair: #(String, Confidence)) {
    pair.0
    <> case pair.1 {
      Confirmed -> " (confirmed)"
      Tentative -> " (tentative)"
    }
  }
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data(
      "frameworks",
      json.array(found, fn(pair) {
        json.object([
          #("name", json.string(pair.0)),
          #(
            "confidence",
            json.string(case pair.1 {
              Confirmed -> "confirmed"
              Tentative -> "tentative"
            }),
          ),
        ])
      }),
    )
    |> step.with_details([Table(["Probe", "Response", "Markers of"], rows)])
  }
  let answered = list.any(probes, fn(probe) { probe.1 != None })
  case answered, found {
    False, _ ->
      step.inconclusive(
        id,
        "no_responses",
        "No unauthenticated request got a response.",
      )
      |> decorate
    True, [] ->
      step.ran(id, Informational, "No known gateway software was recognised.")
      |> decorate
    True, found ->
      step.ran(
        id,
        Informational,
        "Markers of: " <> string.join(list.map(found, describe), ", ") <> ".",
      )
      |> step.with_finding(
        step.Note,
        "Running a known gateway is not a finding against a relay; markers can also be removed or forged.",
      )
      |> decorate
  }
}
