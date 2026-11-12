import gleam/list
import gleam/option.{None, Some}
import gleam/string
import receipt/config
import receipt/ctx.{Ctx}
import receipt/http/types as http
import receipt/prng
import receipt/steps/s07_context.{
  AllFound, EdgeTruncated, Failed, Head, HitLimit, Limit, NoReply, RecallMiss,
  Replied, SizeResult, Tail,
} as s07
import receipt/verdict.{Anomaly, Clean, Inconclusive}
import support/fake.{Fake}
import support/world

pub fn canaries_are_five_unique_markers_test() {
  let #(markers, _) = s07.canaries(prng.new(1))
  assert list.length(markers) == 5
  assert list.unique(markers) == markers
  let assert [first, ..] = markers
  assert string.starts_with(first, "CANARY-1-")
  assert string.length(first) == 17
}

pub fn canaries_differ_between_requests_test() {
  let #(first, generator) = s07.canaries(prng.new(1))
  let #(second, _) = s07.canaries(generator)
  assert first != second
}

pub fn prompt_has_the_requested_size_and_all_markers_test() {
  let #(markers, _) = s07.canaries(prng.new(2))
  let prompt = s07.build_prompt(markers, 8000)
  assert string.length(prompt) > 7900 && string.length(prompt) < 8100
  assert s07.missing(markers, prompt) == []
  let assert [first, ..] = markers
  let assert Ok(last) = list.last(markers)
  assert string.ends_with(prompt, "[" <> last <> "]")
  assert string.contains(string.slice(prompt, 0, 200), first)
}

pub fn missing_reports_positions_test() {
  assert s07.missing(["a1", "b2", "c3"], "found a1 and c3") == [1]
  assert s07.missing(["a1", "b2"], "") == [0, 1]
}

pub fn edge_blocks_are_head_or_tail_runs_test() {
  assert s07.edge_block([3, 4], 5) == Some(Tail)
  assert s07.edge_block([4], 5) == Some(Tail)
  assert s07.edge_block([0, 1, 2], 5) == Some(Head)
  assert s07.edge_block([2], 5) == None
  assert s07.edge_block([0, 4], 5) == None
  assert s07.edge_block([1, 2], 5) == None
  assert s07.edge_block([], 5) == None
  // Everything missing is not positional evidence.
  assert s07.edge_block([0, 1, 2, 3, 4], 5) == None
}

pub fn classification_needs_the_same_edge_twice_test() {
  let tail = Replied([3, 4], None)
  assert s07.classify(Replied([], None), None) == AllFound
  assert s07.classify(tail, Some(Replied([4], None))) == EdgeTruncated(Tail)
  assert s07.classify(tail, Some(Replied([], None))) == RecallMiss
  assert s07.classify(tail, Some(Replied([0], None))) == RecallMiss
  assert s07.classify(Replied([2], None), Some(Replied([2], None)))
    == RecallMiss
  assert s07.classify(tail, Some(Limit("429"))) == RecallMiss
  assert s07.classify(Limit("413"), None) == HitLimit
  assert s07.classify(Failed("timeout"), None) == NoReply
}

pub fn sizes_follow_profile_and_context_cap_test() {
  assert s07.sizes(config.General, None) == [8000, 32_000]
  assert s07.sizes(config.Full, None) == [8000, 32_000, 128_000, 400_000]
  // 8192 tokens * 4 chars * 0.6 = 19 660 characters.
  assert s07.sizes(config.Full, Some(8192)) == [8000]
  assert s07.sizes(config.General, Some(1000)) == []
}

pub fn honest_relay_is_clean_test() {
  let result = s07.run(world.ctx(fake.handler(fake.honest())))
  assert result.verdict == Clean
  assert string.contains(result.summary, "32000 characters")
}

pub fn tail_truncation_is_an_anomaly_test() {
  let relay = Fake(..fake.honest(), truncate_chars: 20_000)
  let result = s07.run(world.ctx(fake.handler(relay)))
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "At 32000 characters")
  assert string.contains(result.summary, "end missing")
}

pub fn size_limit_is_inconclusive_and_stops_the_ladder_test() {
  let relay = Fake(..fake.honest(), max_prompt_chars: 10_000)
  let ctx = world.ctx(fake.handler(relay))
  let result = s07.run(Ctx(..ctx, profile: config.Full))
  assert result.verdict == Inconclusive
  assert result.reason == Some("size_or_rate_limit")
  assert string.contains(result.summary, "up to 8000 characters")
}

pub fn no_reply_at_all_is_inconclusive_test() {
  let result = s07.run(world.ctx(fn(_, _) { Error(http.Timeout) }))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_replies")
}

pub fn no_size_under_the_cap_is_inconclusive_test() {
  let ctx = world.ctx(fake.handler(fake.honest()))
  let result = s07.run(Ctx(..ctx, context_window: Some(500)))
  assert result.reason == Some("no_sizes")
}

pub fn recall_miss_is_inconclusive_not_an_anomaly_test() {
  let result =
    s07.build([
      SizeResult(8000, AllFound, Replied([], Some(2000))),
      SizeResult(32_000, RecallMiss, Replied([2], Some(8000))),
    ])
  assert result.verdict == Inconclusive
  assert result.reason == Some("recall_miss")
}

pub fn head_truncation_is_reported_as_start_missing_test() {
  let result =
    s07.build([SizeResult(8000, EdgeTruncated(Head), Replied([0, 1], None))])
  assert result.verdict == Anomaly
  assert string.contains(result.summary, "start missing")
}
