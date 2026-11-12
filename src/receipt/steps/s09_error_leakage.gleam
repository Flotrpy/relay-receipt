//// Step 9: Error-response leakage.
////
//// Sends five deliberately broken requests and scans the error bodies and
//// headers for things a relay should never return: the caller's key, the
//// API host of an upstream provider, names of secret environment
//// variables, filesystem paths and stack traces. Severity grades and
//// verdicts: `docs/THRESHOLDS.md`.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import receipt/api/chat
import receipt/api/types as api
import receipt/api/url
import receipt/client
import receipt/ctx.{type Ctx}
import receipt/endpoint.{type Endpoint, Endpoint}
import receipt/http/types as http
import receipt/prng
import receipt/report/block.{Table}
import receipt/secret.{type Secret}
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{type Severity, Anomaly, Clean, Critical, High, Medium}

const id = 9

/// API hosts of upstream providers. Seeing one of these in an error from
/// a different host reveals where the relay forwards to.
pub const upstream_hosts = [
  "api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com",
  "aiplatform.googleapis.com", "api.groq.com", "openrouter.ai/api",
  "api.deepseek.com", "api.mistral.ai", "api.together.xyz", "api.fireworks.ai",
  "dashscope.aliyuncs.com", "api.x.ai", "api.cohere.com", "openai.azure.com",
  "bedrock-runtime", "api.moonshot.cn", "open.bigmodel.cn", "api.siliconflow.cn",
  "api.cerebras.ai",
]

pub type Hit {
  Hit(kind: String, severity: Severity, evidence: String)
}

fn pattern(source: String) -> regexp.Regexp {
  let assert Ok(compiled) = regexp.from_string(source)
  compiled
}

fn first_match(source: String, text: String) -> Option(String) {
  case regexp.scan(pattern(source), text) {
    [match, ..] -> Some(match.content)
    [] -> None
  }
}

fn key_hits(text: String, key: Secret) -> List(Hit) {
  let longest = secret.longest_fragment(text, key)
  let total = secret.length(key)
  case
    longest >= total && total > 0,
    longest >= thresholds.leak_fragment_chars
  {
    True, _ -> [
      Hit("full API key", Critical, "the complete key is present"),
    ]
    False, True -> [
      Hit(
        "partial API key",
        High,
        int.to_string(longest)
          <> " of "
          <> int.to_string(total)
          <> " consecutive key characters are present",
      ),
    ]
    False, False -> []
  }
}

fn upstream_hits(lower_text: String, own_host: String) -> List(Hit) {
  upstream_hosts
  |> list.filter(fn(host) {
    string.contains(lower_text, host)
    && !string.contains(string.lowercase(own_host), host)
    && !string.contains(host, string.lowercase(own_host))
  })
  |> list.take(1)
  |> list.map(fn(host) { Hit("upstream provider host", High, host) })
}

fn pattern_hits(text: String) -> List(Hit) {
  let check = fn(kind: String, severity: Severity, source: String) {
    case first_match(source, text) {
      Some(found) -> [Hit(kind, severity, string.slice(found, 0, 80))]
      None -> []
    }
  }
  list.flatten([
    check(
      "secret environment variable name",
      High,
      "\\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*_(?:KEY|TOKEN|SECRET|PASSWORD)\\b",
    ),
    check(
      "filesystem path",
      Medium,
      "(?:/(?:home|usr|var|app|opt|srv|root|etc|tmp|workspace)/[\\w./-]{3,})|(?:[A-Za-z]:\\\\[\\w\\\\.-]{3,})|site-packages|node_modules",
    ),
    check(
      "stack trace",
      Medium,
      "Traceback \\(most recent call last\\)|File \"[^\"]+\", line \\d+|goroutine \\d+ \\[|\\bpanic: |\\bat [\\w.$<>]+ ?\\([^)]*:\\d+(?::\\d+)?\\)|java\\.lang\\.\\w+|\\.go:\\d+",
    ),
  ])
}

/// Everything a piece of response text gives away.
pub fn scan(text: String, key: Secret, own_host: String) -> List(Hit) {
  list.flatten([
    key_hits(text, key),
    upstream_hits(string.lowercase(text), own_host),
    pattern_hits(text),
  ])
  |> list.map(fn(hit) { Hit(..hit, evidence: secret.redact(hit.evidence, key)) })
}

/// Scan a response's body and header values.
pub fn scan_response(
  response: http.Response,
  key: Secret,
  own_host: String,
) -> List(Hit) {
  let headers =
    list.map(response.headers, fn(pair) { pair.1 }) |> string.join("\n")
  scan(http.body_text(response) <> "\n" <> headers, key, own_host)
  |> list.unique
}

pub type Probe {
  Probe(label: String, request: http.Request)
}

/// The five broken requests.
pub fn probes(ctx: Ctx) -> List(Probe) {
  let target = ctx.target
  let chat_url = url.chat(target.base_url, target.format)
  let auth = chat.auth_headers(target)
  let json_headers = [#("content-type", "application/json"), ..auth]
  let timeout = thresholds.request_timeout_ms
  let post = fn(headers, body) {
    http.Request(http.Post, chat_url, headers, body, timeout)
  }
  let #(suffix, _) = prng.int_below(ctx.prng(ctx, id), 0xFFFFFF)
  let valid_body = fn(model: String) {
    chat.build(
      endpoint_with_model(target, model),
      api.simple(model, "ping", 4),
      timeout,
    ).body
  }
  [
    Probe(
      "malformed JSON",
      post(
        json_headers,
        "{\"model\": \"" <> target.model <> "\", \"messages\": [",
      ),
    ),
    Probe(
      "unknown model",
      post(
        json_headers,
        valid_body("receipt-nonexistent-model-" <> int.to_base16(suffix)),
      ),
    ),
    Probe(
      "wrong content type",
      post([#("content-type", "text/plain"), ..auth], valid_body(target.model)),
    ),
    Probe(
      "missing messages",
      post(json_headers, "{\"model\": \"" <> target.model <> "\"}"),
    ),
    Probe(
      "unknown path",
      http.Request(
        http.Get,
        url.under_root(target.base_url, "receipt-no-such-path"),
        auth,
        "",
        timeout,
      ),
    ),
  ]
}

fn endpoint_with_model(endpoint: Endpoint, model: String) -> Endpoint {
  Endpoint(..endpoint, model: model)
}

pub type Observation {
  Observation(label: String, status: Option(Int), hits: List(Hit))
}

pub fn run(ctx: Ctx) -> StepResult {
  let host = url.host(ctx.target.base_url)
  probes(ctx)
  |> list.map(fn(probe) {
    // One attempt each: retrying a deliberate error would only repeat it.
    case
      client.attempt(ctx.net, ctx.target.name, id, probe.label, probe.request)
    {
      Ok(response) ->
        Observation(
          probe.label,
          Some(response.status),
          scan_response(response, ctx.target.key, host),
        )
      Error(_) -> Observation(probe.label, None, [])
    }
  })
  |> build
}

fn describe_severity(severity: Severity) -> String {
  verdict.severity_to_string(severity)
}

pub fn build(observations: List(Observation)) -> StepResult {
  let hits = list.flat_map(observations, fn(observation) { observation.hits })
  let worst =
    list.map(hits, fn(hit) { hit.severity })
    |> list.reduce(verdict.worst_severity)
  let error_surface =
    list.any(observations, fn(observation) {
      case observation.status {
        Some(status) -> status >= 400
        None -> False
      }
    })
  let rows =
    list.map(observations, fn(observation) {
      [
        observation.label,
        case observation.status {
          Some(status) -> "HTTP " <> int.to_string(status)
          None -> "no response"
        },
        case observation.hits {
          [] -> "-"
          found ->
            list.map(found, fn(hit) {
              hit.kind <> " [" <> describe_severity(hit.severity) <> "]"
            })
            |> string.join("; ")
        },
      ]
    })
  let evidence =
    list.unique(hits)
    |> list.map(fn(hit) {
      [hit.kind, describe_severity(hit.severity), hit.evidence]
    })
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data("hits", json.int(list.length(hits)))
    |> step.with_data(
      "kinds",
      json.array(list.unique(list.map(hits, fn(hit) { hit.kind })), json.string),
    )
    |> step.with_details(
      list.flatten([
        [Table(["Broken request", "Response", "Found"], rows)],
        case evidence {
          [] -> []
          _ -> [Table(["Kind", "Severity", "Evidence"], evidence)]
        },
      ]),
    )
  }
  case worst, error_surface {
    Ok(severity), _ ->
      step.ran(
        id,
        Anomaly,
        "Error responses contain "
          <> string.join(
          list.unique(list.map(hits, fn(hit) { hit.kind })),
          ", ",
        )
          <> ".",
      )
      |> step.with_severity(severity)
      |> decorate
    Error(Nil), True ->
      step.ran(
        id,
        Clean,
        "No key, upstream host, secret variable name, path or stack trace was found in the error responses.",
      )
      |> decorate
    Error(Nil), False ->
      step.inconclusive(
        id,
        "no_error_surface",
        "No broken request produced an HTTP error response, so there was nothing to inspect. An endpoint that answers malformed requests with success is unusual.",
      )
      |> decorate
  }
}
