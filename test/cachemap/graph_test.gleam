import gleam/option.{None, Some}
import gleam/string
import receipt/cachemap/graph.{
  AContainsB, BContainsA, Clone, Edge, NoneObserved, Shared, Unresolved,
}
import receipt/cachemap/prove.{Contained, Inconclusive, NoObserved, Partial}

pub fn classification_follows_algorithm_three_test() {
  assert graph.classify(Contained, Contained) == Clone
  assert graph.classify(Contained, Partial) == AContainsB
  assert graph.classify(Contained, NoObserved) == AContainsB
  assert graph.classify(Partial, Contained) == BContainsA
  assert graph.classify(Partial, Partial) == Shared
  assert graph.classify(Partial, NoObserved) == Shared
  assert graph.classify(NoObserved, Partial) == Shared
  assert graph.classify(NoObserved, NoObserved) == NoneObserved
}

pub fn any_inconclusive_direction_leaves_the_pair_unresolved_test() {
  assert graph.classify(Inconclusive, Contained) == Unresolved
  assert graph.classify(NoObserved, Inconclusive) == Unresolved
  assert graph.classify(Inconclusive, Inconclusive) == Unresolved
}

pub fn pairs_are_ordered_by_increasing_stride_test() {
  // The example of Section III-B of the paper.
  assert graph.pair_order(["A", "B", "C", "D"])
    == [
      #("A", "B"),
      #("B", "C"),
      #("C", "D"),
      #("A", "C"),
      #("B", "D"),
      #("A", "D"),
    ]
  assert graph.pair_order(["A"]) == []
  assert graph.pair_order([]) == []
}

pub fn containment_is_transitive_test() {
  let edges = [Edge("A", "B", AContainsB), Edge("B", "C", AContainsB)]
  assert graph.implied(edges, "A", "C") == Some(AContainsB)
  assert graph.implied(edges, "C", "A") == Some(BContainsA)
}

pub fn reversed_edges_are_followed_test() {
  let edges = [Edge("B", "A", BContainsA), Edge("C", "B", BContainsA)]
  assert graph.implied(edges, "A", "C") == Some(AContainsB)
}

pub fn clones_are_interchangeable_test() {
  let edges = [Edge("A", "B", Clone), Edge("B", "C", AContainsB)]
  assert graph.implied(edges, "A", "C") == Some(AContainsB)
  let both = [Edge("A", "B", Clone), Edge("B", "C", Clone)]
  assert graph.implied(both, "A", "C") == Some(Clone)
}

pub fn partial_and_unobserved_edges_imply_nothing_test() {
  let edges = [
    Edge("A", "B", Shared),
    Edge("B", "C", NoneObserved),
    Edge("C", "D", Unresolved),
  ]
  assert graph.implied(edges, "A", "C") == None
  assert graph.implied(edges, "A", "D") == None
}

pub fn unrelated_pairs_are_not_implied_test() {
  let edges = [Edge("A", "B", AContainsB), Edge("C", "D", AContainsB)]
  assert graph.implied(edges, "A", "D") == None
}

pub fn cycles_do_not_hang_test() {
  let edges = [
    Edge("A", "B", Clone),
    Edge("B", "C", Clone),
    Edge("C", "A", Clone),
  ]
  assert graph.implied(edges, "A", "Z") == None
}

pub fn mermaid_draws_only_observed_sharing_test() {
  let text =
    graph.mermaid(["relay-a", "relay-b", "relay-c", "relay-d"], [
      Edge("relay-a", "relay-b", AContainsB),
      Edge("relay-b", "relay-c", Clone),
      Edge("relay-a", "relay-d", Shared),
      Edge("relay-c", "relay-d", NoneObserved),
      Edge("relay-b", "relay-d", Unresolved),
    ])
  assert string.starts_with(text, "graph TD\n  n0[\"relay-a\"]")
  assert string.contains(text, "  n0 -->|contains| n1")
  assert string.contains(text, "  n1 === n2")
  assert string.contains(text, "  n0 -.-|partial| n3")
  assert !string.contains(text, "n2 -")
  assert !string.contains(text, "n1 -.")
}

pub fn mermaid_arrow_points_from_container_to_contained_test() {
  let text = graph.mermaid(["x", "y"], [Edge("x", "y", BContainsA)])
  assert string.contains(text, "  n1 -->|contains| n0")
}

pub fn adjacency_is_told_from_each_nodes_side_test() {
  let adjacency =
    graph.adjacency(["A", "B", "C"], [
      Edge("A", "B", AContainsB),
      Edge("B", "C", Unresolved),
    ])
  assert adjacency
    == [
      #("A", [#("B", "contains")]),
      #("B", [#("A", "contained_in"), #("C", "inconclusive")]),
      #("C", [#("B", "inconclusive")]),
    ]
}

pub fn unresolved_is_never_reported_as_no_edge_test() {
  // An unresolved pair must stay visible in the adjacency list.
  let adjacency = graph.adjacency(["A", "B"], [Edge("A", "B", Unresolved)])
  assert adjacency
    == [#("A", [#("B", "inconclusive")]), #("B", [#("A", "inconclusive")])]
}
