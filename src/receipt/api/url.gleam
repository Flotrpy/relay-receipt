//// Building endpoint URLs from the base URL a user supplies.
////
//// Users give base URLs in several styles: `https://host`,
//// `https://host/v1`, `https://host/v1beta/openai`, or the full chat URL.
//// The rule here is deterministic and documented, never a guess-and-retry.

import gleam/list
import gleam/option
import gleam/regexp
import gleam/string
import gleam/uri
import receipt/api/types.{type ApiFormat, Anthropic, OpenAi}

/// The base URL without trailing slashes.
pub fn normalise(base_url: String) -> String {
  case string.ends_with(base_url, "/") {
    True -> normalise(string.drop_end(base_url, 1))
    False -> base_url
  }
}

/// Whether the last path segment already names an API version or an
/// OpenAI-compatibility prefix, such as `v1`, `v1beta` or `openai`.
fn has_api_prefix(base: String) -> Bool {
  let last = case uri.parse(base) {
    Ok(parsed) -> uri.path_segments(parsed.path) |> list.last
    Error(Nil) -> Error(Nil)
  }
  case last {
    Error(Nil) -> False
    Ok(segment) -> {
      let assert Ok(version) = regexp.from_string("^v[0-9]+[a-z0-9]*$")
      segment == "openai" || regexp.check(version, segment)
    }
  }
}

fn api_root(base_url: String) -> String {
  let base = normalise(base_url)
  case has_api_prefix(base) {
    True -> base
    False -> base <> "/v1"
  }
}

/// URL of the chat endpoint for a format.
pub fn chat(base_url: String, format: ApiFormat) -> String {
  let base = normalise(base_url)
  let suffix = case format {
    OpenAi -> "/chat/completions"
    Anthropic -> "/messages"
  }
  case string.ends_with(base, suffix) {
    True -> base
    False -> api_root(base) <> suffix
  }
}

/// URL of the model list.
pub fn models(base_url: String) -> String {
  api_root(base_url) <> "/models"
}

/// URL of an arbitrary path under the API root, for error probes.
pub fn under_root(base_url: String, path: String) -> String {
  api_root(base_url) <> "/" <> path
}

/// The scheme and authority only, for unauthenticated landing-page probes.
pub fn origin(base_url: String) -> String {
  case uri.parse(base_url) {
    Ok(parsed) ->
      case uri.origin(parsed) {
        Ok(origin) -> origin
        Error(Nil) -> normalise(base_url)
      }
    Error(Nil) -> normalise(base_url)
  }
}

/// The host name, or an empty string if the URL cannot be parsed.
pub fn host(base_url: String) -> String {
  case uri.parse(base_url) {
    Ok(uri.Uri(host: option_host, ..)) ->
      case option_host {
        option.Some(host) -> host
        option.None -> ""
      }
    Error(Nil) -> ""
  }
}
