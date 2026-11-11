import receipt/api/types.{Anthropic, OpenAi}
import receipt/api/url

pub fn bare_host_gets_v1_test() {
  assert url.chat("https://relay.example", OpenAi)
    == "https://relay.example/v1/chat/completions"
  assert url.chat("https://relay.example/", Anthropic)
    == "https://relay.example/v1/messages"
}

pub fn versioned_base_is_used_as_is_test() {
  assert url.chat("https://relay.example/v1", OpenAi)
    == "https://relay.example/v1/chat/completions"
  assert url.chat("https://relay.example/api/v1/", OpenAi)
    == "https://relay.example/api/v1/chat/completions"
  assert url.chat("https://api.example/v1", Anthropic)
    == "https://api.example/v1/messages"
}

pub fn openai_compat_prefix_is_used_as_is_test() {
  assert url.chat("https://api.groq.com/openai/v1", OpenAi)
    == "https://api.groq.com/openai/v1/chat/completions"
  assert url.chat(
      "https://generativelanguage.googleapis.com/v1beta/openai",
      OpenAi,
    )
    == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
}

pub fn full_chat_url_is_left_alone_test() {
  assert url.chat("https://relay.example/v1/chat/completions", OpenAi)
    == "https://relay.example/v1/chat/completions"
}

pub fn non_version_path_gets_v1_appended_test() {
  assert url.chat("https://relay.example/proxy", OpenAi)
    == "https://relay.example/proxy/v1/chat/completions"
  assert url.chat("http://127.0.0.1:4000", OpenAi)
    == "http://127.0.0.1:4000/v1/chat/completions"
}

pub fn models_url_test() {
  assert url.models("https://relay.example")
    == "https://relay.example/v1/models"
  assert url.models("https://api.groq.com/openai/v1/")
    == "https://api.groq.com/openai/v1/models"
}

pub fn under_root_test() {
  assert url.under_root("https://relay.example", "nope")
    == "https://relay.example/v1/nope"
}

pub fn origin_and_host_test() {
  assert url.origin("https://relay.example:8443/v1")
    == "https://relay.example:8443"
  assert url.origin("http://127.0.0.1:4000/x/y") == "http://127.0.0.1:4000"
  assert url.host("https://relay.example:8443/v1") == "relay.example"
  assert url.host("not a url") == ""
}

pub fn trailing_slashes_are_removed_test() {
  assert url.normalise("https://a.example///") == "https://a.example"
  assert url.normalise("https://a.example") == "https://a.example"
}
