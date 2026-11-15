import receipt/probes/family.{Conflict, Consistent, Unknown}

pub fn model_ids_map_to_families_test() {
  assert family.of_model("openai/gpt-oss-20b") == Ok("openai")
  assert family.of_model("claude-sonnet-4-5") == Ok("anthropic")
  assert family.of_model("gemini-2.5-flash") == Ok("google")
  assert family.of_model("meta-llama/llama-3.1-8b-instant") == Ok("meta")
  assert family.of_model("qwen/qwen3.8-27b") == Ok("alibaba")
  assert family.of_model("deepseek-chat") == Ok("deepseek")
  assert family.of_model("allam-2-7b") == Ok("sdaia")
  assert family.of_model("my-private-model") == Error(Nil)
}

pub fn self_descriptions_name_families_test() {
  assert family.in_text(
      "I am ChatGPT, a large language model trained by OpenAI.",
    )
    == ["openai"]
  assert family.in_text("I'm Claude, made by Anthropic.") == ["anthropic"]
  assert family.in_text("I am a large language model, trained by Google.")
    == ["google"]
  assert family.in_text("我是通义千问，由阿里云开发。") == ["alibaba"]
  assert family.in_text("I'm Llama, created by Meta AI.") == ["meta"]
  assert family.in_text("I am an AI assistant.") == []
}

pub fn words_must_be_whole_words_test() {
  // "metadata" is not Meta, "phishing" is not Phi, "novel" is not Nova.
  assert family.in_text("I process metadata and avoid phishing in a novel way.")
    == []
  assert family.in_text("Egypt has gptpyramids") == []
}

pub fn matching_family_is_consistent_test() {
  assert family.compare("openai/gpt-oss-20b", "I am ChatGPT by OpenAI.")
    == Consistent("openai")
}

pub fn naming_another_family_is_a_conflict_test() {
  assert family.compare(
      "claude-sonnet-4-5",
      "I am Qwen, developed by Alibaba Cloud.",
    )
    == Conflict("anthropic", ["alibaba"])
}

pub fn naming_both_families_is_consistent_test() {
  assert family.compare(
      "gemini-2.5-flash",
      "I am Gemini from Google, not ChatGPT from OpenAI.",
    )
    == Consistent("google")
}

pub fn unknown_model_or_silent_reply_is_unknown_test() {
  assert family.compare("my-private-model", "I am Claude.") == Unknown
  assert family.compare("claude-x", "I am a helpful assistant.") == Unknown
}
