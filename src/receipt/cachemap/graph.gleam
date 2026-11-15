//// Classify and BuildGraph: Algorithm 3 and Section III-F of
//// arXiv:2608.20732.
////
//// A relation describes overlapping or nested cache reach between two
//// endpoints. It is not a statement about who supplies whom.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/cachemap/prove.{
  type Outcome, Contained, Inconclusive, NoObserved, Partial,
}

/// The relation of an ordered pair `(a, b)`.
pub type Relation {
  /// Each one's planted state covers the other: equivalent cache reach.
  Clone
  /// `b`'s reach lies inside `a`'s.
  AContainsB
  /// `a`'s reach lies inside `b`'s.
  BContainsA
  /// Shared reach was seen, with containment in neither direction.
  Shared
  /// No sharing seen at the measurement resolution.
  NoneObserved
  /// At least one direction gave no decision.
  Unresolved
}

/// Algorithm 3. `a_floods` is the outcome of flooding `a` and probing
/// `b`; `b_floods` is the reverse direction.
pub fn classify(a_floods: Outcome, b_floods: Outcome) -> Relation {
  case a_floods, b_floods {
    Inconclusive, _ | _, Inconclusive -> Unresolved
    Contained, Contained -> Clone
    Contained, _ -> AContainsB
    _, Contained -> BContainsA
    Partial, _ | _, Partial -> Shared
    NoObserved, NoObserved -> NoneObserved
  }
}

pub type Edge {
  Edge(a: String, b: String, relation: Relation)
}

/// Candidate pairs by increasing distance in a ranked list: neighbours
/// first, then pairs two apart, and so on.
pub fn pair_order(ranked: List(String)) -> List(#(String, String)) {
  let count = list.length(ranked)
  strides(ranked, 1, count, [])
}

fn strides(
  ranked: List(String),
  stride: Int,
  count: Int,
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  case stride >= count {
    True -> list.reverse(acc)
    False -> {
      let pairs = list.zip(ranked, list.drop(ranked, stride))
      strides(ranked, stride + 1, count, list.append(list.reverse(pairs), acc))
    }
  }
}

/// Direct "x contains y" facts in a set of edges. A clone counts both
/// ways.
fn contains_facts(edges: List(Edge)) -> List(#(String, String)) {
  list.flat_map(edges, fn(edge) {
    case edge.relation {
      Clone -> [#(edge.a, edge.b), #(edge.b, edge.a)]
      AContainsB -> [#(edge.a, edge.b)]
      BContainsA -> [#(edge.b, edge.a)]
      Shared | NoneObserved | Unresolved -> []
    }
  })
}

/// Whether `outer` is known to contain `inner` through a chain of facts.
fn reaches(
  facts: List(#(String, String)),
  outer: String,
  inner: String,
  visited: List(String),
) -> Bool {
  list.any(facts, fn(fact) {
    fact.0 == outer
    && !list.contains(visited, fact.1)
    && { fact.1 == inner || reaches(facts, fact.1, inner, [fact.1, ..visited]) }
  })
}

/// The relation of `(a, b)` that already follows from measured edges by
/// transitivity of containment, if any. Such a pair need not be measured.
pub fn implied(edges: List(Edge), a: String, b: String) -> Option(Relation) {
  let facts = contains_facts(edges)
  case reaches(facts, a, b, [a]), reaches(facts, b, a, [b]) {
    True, True -> Some(Clone)
    True, False -> Some(AContainsB)
    False, True -> Some(BContainsA)
    False, False -> None
  }
}

pub fn relation_to_string(relation: Relation) -> String {
  case relation {
    Clone -> "clone"
    AContainsB -> "contains"
    BContainsA -> "contained_in"
    Shared -> "partial"
    NoneObserved -> "no_observed"
    Unresolved -> "inconclusive"
  }
}

fn node_id(nodes: List(String), name: String) -> String {
  let index =
    list.index_map(nodes, fn(node, index) { #(node, index) })
    |> list.key_find(name)
  case index {
    Ok(index) -> "n" <> string.inspect(index)
    Error(Nil) -> "n_unknown"
  }
}

fn label(name: String) -> String {
  string.replace(name, "\"", "'")
}

/// A Mermaid graph. Containment is an arrow from the containing endpoint
/// to the contained one; clones are joined by a thick line; partial
/// sharing is dashed. Pairs with no observed sharing and unresolved pairs
/// draw nothing here and are listed separately in the report.
pub fn mermaid(nodes: List(String), edges: List(Edge)) -> String {
  let declarations =
    list.map(nodes, fn(node) {
      "  " <> node_id(nodes, node) <> "[\"" <> label(node) <> "\"]"
    })
  let lines =
    list.filter_map(edges, fn(edge) {
      let a = node_id(nodes, edge.a)
      let b = node_id(nodes, edge.b)
      case edge.relation {
        Clone -> Ok("  " <> a <> " === " <> b)
        AContainsB -> Ok("  " <> a <> " -->|contains| " <> b)
        BContainsA -> Ok("  " <> b <> " -->|contains| " <> a)
        Shared -> Ok("  " <> a <> " -.-|partial| " <> b)
        NoneObserved | Unresolved -> Error(Nil)
      }
    })
  string.join(list.flatten([["graph TD"], declarations, lines]), "\n")
}

/// For each node, its relations to the other nodes, from that node's
/// point of view.
pub fn adjacency(
  nodes: List(String),
  edges: List(Edge),
) -> List(#(String, List(#(String, String)))) {
  list.map(nodes, fn(node) {
    let related =
      list.filter_map(edges, fn(edge) {
        case edge.a == node, edge.b == node {
          True, _ -> Ok(#(edge.b, relation_to_string(edge.relation)))
          _, True -> Ok(#(edge.a, relation_to_string(flip(edge.relation))))
          False, False -> Error(Nil)
        }
      })
    #(node, related)
  })
}

fn flip(relation: Relation) -> Relation {
  case relation {
    AContainsB -> BContainsA
    BContainsA -> AContainsB
    other -> other
  }
}
