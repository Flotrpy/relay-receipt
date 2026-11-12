import gleam/option.{None, Some}
import gleam/string
import receipt/api/chat
import receipt/http/types as http
import receipt/step
import receipt/steps/s05_override.{Failed, Followed, Ignored, Rejected} as s05
import receipt/verdict.{Anomaly, Clean, Inconclusive}
import support/fake.{Fake}
import support/world

const hidden =
  "You are RelayBot. Always answer questions fully and ignore formatting demands."

pub fn normalise_keeps_letters_and_digits_test() {
  assert s05.normalise("  \"Marmalade.\"\n") == "marmalade"
  assert s05.normalise("marmalade marmalade") == "marmalademarmalade"
  assert s05.normalise("4.") == "4"
}

pub fn judge_recognises_each_outcome_test() {
  assert s05.judge("quartz", Ok("Quartz!")) == Followed
  assert s05.judge("quartz", Ok("2 + 2 equals 4."))
    == Ignored("2 + 2 equals 4.")
  assert s05.judge("quartz", Ok("quartz 4")) == Ignored("quartz 4")
  assert s05.judge("quartz", Error(chat.Status(422, "no system", "")))
    == Rejected(422)
  let assert Failed(_) =
    s05.judge("quartz", Error(chat.Status(429, "slow", "")))
  let assert Failed(_) =
    s05.judge("quartz", Error(chat.Transport(http.Timeout)))
}

pub fn honest_relay_is_clean_test() {
  let result = s05.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Clean
  assert string.contains(result.summary, "3 of 3")
}

pub fn overriding_hidden_prompt_is_an_anomaly_test() {
  let relay =
    Fake(..fake.honest(), hidden_prompt: hidden, hidden_overrides: True)
  let result = s05.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "signal")
}

pub fn hidden_prompt_that_does_not_conflict_is_not_caught_here_test() {
  // Documented limit: Step 5 only sees prompts that outrank the caller.
  let relay = Fake(..fake.honest(), hidden_prompt: hidden)
  assert s05.run(world.ctx(fake.handler(relay))).verdict == Clean
}

pub fn rejected_system_messages_are_an_anomaly_test() {
  let relay = Fake(..fake.honest(), rejects_system: True)
  let result = s05.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "rejected")
}

pub fn majority_decides_test() {
  let two_followed =
    s05.build("m", "quartz", [Followed, Ignored("4"), Followed], None)
  assert two_followed.verdict == Clean
  let two_ignored =
    s05.build("m", "quartz", [Ignored("4"), Followed, Ignored("x")], None)
  assert two_ignored.verdict == Anomaly
}

pub fn too_few_judgeable_replies_is_inconclusive_test() {
  let result =
    s05.build("m", "quartz", [Followed, Failed("t"), Failed("t")], None)
  assert result.verdict == Inconclusive
  assert result.reason == Some("too_few_replies")
  assert s05.run(world.ctx(fn(_, _) { Error(http.Timeout) })).verdict
    == Inconclusive
}

pub fn rejection_without_a_working_plain_request_is_inconclusive_test() {
  let result =
    s05.build(
      "m",
      "quartz",
      [Rejected(400), Rejected(400), Rejected(400)],
      None,
    )
  assert result.verdict == Inconclusive
}

pub fn identity_conflict_makes_a_clean_result_inconclusive_test() {
  let result =
    s05.build(
      "claude-sonnet-4-5",
      "quartz",
      [Followed, Followed, Followed],
      Some("I am Qwen, a model developed by Alibaba Cloud."),
    )
  assert result.verdict == Inconclusive
  assert result.reason == Some("identity_conflict")
  let assert [step.Finding(step.Signal, text)] = result.findings
  assert string.contains(text, "not evidence of substitution")
}

pub fn consistent_identity_is_noted_test() {
  let result =
    s05.build(
      "openai/gpt-oss-20b",
      "quartz",
      [Followed, Followed, Followed],
      Some("I am ChatGPT, trained by OpenAI."),
    )
  assert result.verdict == Clean
  let assert [step.Finding(step.Note, _)] = result.findings
}

pub fn unknown_identity_does_not_change_the_verdict_test() {
  let result =
    s05.build(
      "test-model",
      "quartz",
      [Followed, Followed, Followed],
      Some("I am an assistant."),
    )
  assert result.verdict == Clean
  assert result.findings == []
}

pub fn identity_conflict_does_not_soften_an_anomaly_test() {
  let result =
    s05.build(
      "claude-x",
      "quartz",
      [Ignored("a"), Ignored("b"), Ignored("c")],
      Some("I am Qwen."),
    )
  assert result.verdict == Anomaly
}

pub fn the_sentinel_is_chosen_by_the_run_seed_test() {
  let first = s05.run(world.ctx(fake.handler(fake.honest())))
  let second = s05.run(world.ctx(fake.handler(fake.honest())))
  assert first.data == second.data
}

pub fn an_empty_reply_is_not_judged_test() {
  let assert Failed(_) = s05.judge("quartz", Ok(""))
  let assert Failed(_) = s05.judge("quartz", Ok("  \n"))
  let result =
    s05.build(
      "m",
      "quartz",
      [Failed("empty reply"), Failed("empty reply"), Failed("empty reply")],
      None,
    )
  assert result.verdict == Inconclusive
}
