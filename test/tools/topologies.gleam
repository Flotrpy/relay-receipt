//// Controlled evaluation of Step 16 on the cache simulator.
////
//// gleam run -m tools/topologies
////
//// Eight topologies with known cache domains, in the spirit of the
//// controlled evaluation of arXiv:2608.20732 (RQ3). Each endpoint routes
//// round-robin over its domains, so containment and sharing are known by
//// construction. Reported per preset: the relation Step 16 recovered for
//// every pair against the true one.

import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import receipt/config
import receipt/ctx.{Ctx}
import receipt/steps/s16_upstream_map
import support/cachesim
import support/world

pub type Case {
  Case(
    name: String,
    topology: List(#(String, List(String))),
    expected: List(#(String, String, String)),
  )
}

pub fn cases() -> List(Case) {
  [
    Case("one shared domain", [#("target", ["d1"]), #("b", ["d1"])], [
      #("target", "b", "clone"),
    ]),
    Case("superset", [#("target", ["d1", "d2"]), #("b", ["d1"])], [
      #("target", "b", "contains"),
    ]),
    Case("subset", [#("target", ["d1"]), #("b", ["d1", "d2"])], [
      #("target", "b", "contained_in"),
    ]),
    Case("disjoint", [#("target", ["d1"]), #("b", ["d2"])], [
      #("target", "b", "no_observed"),
    ]),
    Case("overlap", [#("target", ["d1", "d2"]), #("b", ["d2", "d3"])], [
      #("target", "b", "partial"),
    ]),
    Case(
      "three-to-two",
      [#("target", ["d1", "d2", "d3"]), #("b", ["d1", "d2"])],
      [#("target", "b", "contains")],
    ),
    Case(
      "four-to-one",
      [#("target", ["d1", "d2", "d3", "d4"]), #("b", ["d4"])],
      [#("target", "b", "contains")],
    ),
    Case(
      "chain of three",
      [#("target", ["d1", "d2", "d3"]), #("b", ["d1", "d2"]), #("c", ["d1"])],
      [
        #("target", "b", "contains"),
        #("b", "c", "contains"),
        #("target", "c", "contains"),
      ],
    ),
  ]
}

fn relations(
  data: List(#(String, json.Json)),
) -> List(#(String, String, String)) {
  case list.key_find(data, "adjacency") {
    Error(Nil) -> []
    Ok(adjacency) -> {
      let decoder =
        decode.dict(
          decode.string,
          decode.list({
            use to <- decode.field("to", decode.string)
            use relation <- decode.field("relation", decode.string)
            decode.success(#(to, relation))
          }),
        )
      case json.parse(json.to_string(adjacency), decoder) {
        Ok(found) ->
          found
          |> dict.to_list
          |> list.flat_map(fn(entry) {
            list.map(entry.1, fn(pair) { #(entry.0, pair.0, pair.1) })
          })
        Error(_) -> []
      }
    }
  }
}

pub fn evaluate(
  preset: config.MapPreset,
  case_: Case,
) -> #(Int, Int, List(String)) {
  let extra =
    list.filter_map(case_.topology, fn(pair) {
      case pair.0 {
        "target" -> Error(Nil)
        name -> Ok(world.endpoint(name))
      }
    })
  let base = world.ctx(cachesim.start(case_.topology, []))
  let result =
    s16_upstream_map.run(Ctx(..base, endpoints: extra, map_preset: preset))
  let found = relations(result.data)
  let checks =
    list.map(case_.expected, fn(expected) {
      let #(a, b, relation) = expected
      let got =
        list.find(found, fn(r) { r.0 == a && r.1 == b })
        |> fn(r) {
          case r {
            Ok(r) -> r.2
            Error(Nil) -> "missing"
          }
        }
      #(
        got == relation,
        a <> " / " <> b <> ": expected " <> relation <> ", got " <> got,
      )
    })
  #(
    list.count(checks, fn(c) { c.0 }),
    list.length(checks),
    list.map(checks, fn(c) { c.1 }),
  )
}

pub fn main() -> Nil {
  let lines =
    list.flat_map([config.Coarse, config.Paper], fn(preset) {
      let rows =
        list.map(cases(), fn(case_) {
          let #(right, total, details) = evaluate(preset, case_)
          "| "
          <> config.map_preset_to_string(preset)
          <> " | "
          <> case_.name
          <> " | "
          <> string.inspect(right)
          <> " / "
          <> string.inspect(total)
          <> " | "
          <> string.join(details, "; ")
          <> " |"
        })
      rows
    })
  io.println(string.join(
    [
      "| Preset | Topology | Pairs right | Detail |",
      "| --- | --- | --- | --- |",
      ..lines
    ],
    "\n",
  ))
}
