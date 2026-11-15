import gleam/list
import gleam/option.{Some}
import gleam/string
import receipt/cachemap/graph.{AContainsB, Edge, NoneObserved, Unresolved}
import receipt/cachemap/params
import receipt/cachemap/prove.{Contained, Counts}
import receipt/config
import receipt/ctx.{type Ctx, Ctx}
import receipt/prng
import receipt/report/block
import receipt/steps/s16_upstream_map.{Direction, Mapped} as s16
import receipt/verdict.{Inconclusive, Informational}
import support/cachesim
import support/world

fn ctx_for(
  topology: List(#(String, List(String))),
  silent: List(String),
  extra: List(String),
) -> Ctx {
  let base = world.ctx(cachesim.start(topology, silent))
  Ctx(..base, endpoints: list.map(extra, world.endpoint))
}

pub fn calibration_measures_chunk_and_token_rate_test() {
  let ctx = ctx_for([#("target", ["d1"])], [], [])
  let #(calibration, _) = s16.calibrate(ctx, ctx.target, prng.new(1))
  let assert Ok(found) = calibration
  // The simulator caches in chunks of 64; the default of 128 is larger.
  assert found.chunk == 128
  assert found.tokens_per_word >. 1.0 && found.tokens_per_word <. 1.05
}

pub fn calibration_fails_without_cache_telemetry_test() {
  let ctx = ctx_for([#("target", ["d1"])], ["target"], [])
  let #(calibration, _) = s16.calibrate(ctx, ctx.target, prng.new(1))
  let assert Error(reason) = calibration
  assert string.contains(reason, "no cached tokens")
}

pub fn endpoints_on_one_cache_domain_are_clones_test() {
  let result =
    s16.run(ctx_for([#("target", ["d1"]), #("b", ["d1"])], [], ["b"]))
  assert result.verdict == Informational
  assert string.contains(result.summary, "equivalent cache reach")
}

pub fn a_superset_of_domains_contains_the_subset_test() {
  // target reaches d1 and d2; b reaches only d1.
  let result =
    s16.run(ctx_for([#("target", ["d1", "d2"]), #("b", ["d1"])], [], ["b"]))
  assert result.verdict == Informational
  assert string.contains(result.summary, "b's cache reach lies inside target's")
}

pub fn disjoint_domains_show_no_sharing_test() {
  let result =
    s16.run(ctx_for([#("target", ["d1"]), #("b", ["d2"])], [], ["b"]))
  assert result.verdict == Informational
  assert string.contains(result.summary, "No shared cache reach was observed")
}

pub fn overlapping_but_not_nested_domains_are_partial_test() {
  let result =
    s16.run(
      ctx_for([#("target", ["d1", "d2"]), #("b", ["d2", "d3"])], [], ["b"]),
    )
  assert string.contains(result.summary, "share part of their cache reach")
}

pub fn an_endpoint_without_telemetry_is_unknown_not_unrelated_test() {
  let result =
    s16.run(ctx_for([#("target", ["d1"]), #("b", ["d1"])], ["b"], ["b"]))
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_cache_telemetry")
  assert string.contains(
    string.inspect(result.details),
    "Unknown, not unrelated",
  )
}

pub fn three_endpoints_give_a_graph_with_every_relation_test() {
  // target and b share d1; c is separate.
  let result =
    s16.run(
      ctx_for([#("target", ["d1"]), #("b", ["d1"]), #("c", ["d9"])], [], [
        "b",
        "c",
      ]),
    )
  assert result.verdict == Informational
  let assert [block.Mermaid(source), ..] = result.details
  assert string.contains(source, "===")
  assert string.contains(result.summary, "equivalent cache reach")
}

fn mapped(edges, implied) {
  Mapped(
    nodes: ["a", "b", "c"],
    edges: edges,
    directions: [
      Direction("a", "b", Contained, Counts(30, 30, 0), "flood covered"),
    ],
    implied: implied,
    uncalibrated: [],
  )
}

pub fn build_reports_error_rate_and_limits_test() {
  let result =
    s16.build(
      config.Coarse,
      params.preset(config.Coarse),
      mapped([Edge("a", "b", AContainsB)], [Edge("a", "c", AContainsB)]),
    )
  let assert Some(rate) = result.error_rate
  assert rate.bound == 0.05
  assert string.contains(rate.basis, "not corrected")
  assert list.length(result.findings) == 2
  assert string.contains(string.inspect(result.data), "implied")
}

pub fn all_pairs_unresolved_is_inconclusive_test() {
  let result =
    s16.build(
      config.Coarse,
      params.preset(config.Coarse),
      mapped([Edge("a", "b", Unresolved)], []),
    )
  assert result.verdict == Inconclusive
  assert result.reason == Some("no_pair_resolved")
}

pub fn one_resolved_pair_is_enough_to_be_informational_test() {
  let result =
    s16.build(
      config.Coarse,
      params.preset(config.Coarse),
      mapped([Edge("a", "b", Unresolved), Edge("b", "c", NoneObserved)], []),
    )
  assert result.verdict == Informational
}
