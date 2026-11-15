//// Step 16: Upstream map.
////
//// CacheTracer (arXiv:2608.20732) over the endpoints the user supplies:
//// Calibrate, Profile, then for each pair Flood one endpoint and Prove
//// the other in both directions, Classify, and assemble the cache-reach
//// graph. Implemented as specified in `docs/steps/16-upstream-map.md`.
////
//// Verdicts come from the cached-token count the API reports. Timing is
//// used only to order the pairs.

import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/chat
import receipt/api/types as api
import receipt/cachemap/graph.{type Edge, type Relation, Edge, Unresolved}
import receipt/cachemap/ladder
import receipt/cachemap/params.{type Params}
import receipt/cachemap/prove.{
  type Observation, type Outcome, Failed, Hit, Inconclusive, Miss, TimedOut,
}
import receipt/client
import receipt/config
import receipt/ctx.{type Ctx}
import receipt/endpoint.{type Endpoint}
import receipt/http/types as http
import receipt/prng.{type Prng}
import receipt/report/block.{Mermaid, Paragraph, Table}
import receipt/seq
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Informational}

const id = 16

/// What calibration learned about an endpoint.
pub type Calibration {
  Calibration(
    /// Cache chunk length in tokens used in hit tests.
    chunk: Int,
    /// Tokens billed per padding word.
    tokens_per_word: Float,
    /// Time to first byte of the first calibration request.
    first_byte_us: Int,
  )
}

type Sent {
  Sent(prompt_tokens: Int, cached_tokens: Option(Int), first_byte_us: Int)
}

fn send_prompt(
  ctx: Ctx,
  endpoint: Endpoint,
  label: String,
  prompt: String,
) -> Result(Sent, http.TransportError) {
  let params =
    api.simple(endpoint.model, prompt, 2) |> api.with_temperature(0.0)
  let request = chat.build(endpoint, params, thresholds.request_timeout_ms)
  // Single attempts: the algorithms count errors themselves.
  case client.attempt(ctx.net, endpoint.name, id, label, request) {
    Error(error) -> Error(error)
    Ok(response) ->
      case chat.interpret(endpoint, Ok(response)) {
        Ok(completion) ->
          case completion.usage.prompt_tokens {
            Some(prompt_tokens) ->
              Ok(Sent(
                prompt_tokens,
                completion.usage.cached_tokens,
                option.unwrap(response.timing.first_byte_us, 0),
              ))
            None -> Error(http.Other("no prompt_tokens in usage"))
          }
        Error(error) -> Error(http.Other(chat.describe(error)))
      }
  }
}

fn observe(
  ctx: Ctx,
  endpoint: Endpoint,
  label: String,
  prompt: String,
  chunk: Int,
) -> Observation {
  case send_prompt(ctx, endpoint, label, prompt) {
    Error(http.Timeout) -> TimedOut
    Error(_) -> Failed
    Ok(sent) ->
      case
        ladder.is_hit(
          sent.prompt_tokens,
          option.unwrap(sent.cached_tokens, 0),
          chunk,
        )
      {
        True -> Hit
        False -> Miss
      }
  }
}

/// Calibrate one endpoint: send a fresh prompt, then repeat it up to
/// three times looking for a reported cache hit.
pub fn calibrate(
  ctx: Ctx,
  endpoint: Endpoint,
  prng: Prng,
) -> #(Result(Calibration, String), Prng) {
  let #(nonce, prng) = ladder.nonce(prng)
  let words = thresholds.map_base_prefix_tokens
  let prompt = ladder.prompt(nonce, words)
  let label = endpoint.name <> "/calibrate"
  let result = case send_prompt(ctx, endpoint, label, prompt) {
    Error(error) ->
      Error("calibration request failed: " <> http.describe_error(error))
    Ok(first) -> {
      let repeats =
        seq.range(1, thresholds.map_calibration_attempts)
        |> list.filter_map(fn(_) {
          case send_prompt(ctx, endpoint, label, prompt) {
            Ok(sent) ->
              case sent.cached_tokens {
                Some(cached) if cached > 0 -> Ok(sent.prompt_tokens - cached)
                _ -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        })
      case list.reduce(repeats, int.min) {
        Error(Nil) ->
          Error("no cached tokens were reported for a repeated prompt")
        Ok(gap) ->
          Ok(Calibration(
            chunk: int.max(thresholds.map_default_chunk_tokens, gap),
            tokens_per_word: int.to_float(first.prompt_tokens)
              /. int.to_float(words),
            first_byte_us: first.first_byte_us,
          ))
      }
    }
  }
  #(result, prng)
}

pub type Direction {
  Direction(
    flood: String,
    probe: String,
    outcome: Outcome,
    counts: prove.Counts,
    note: String,
  )
}

type KeepWarm {
  KeepWarm(stop: fn() -> Nil)
}

/// Start low-rate workers that keep a planted prompt warm. Only live runs
/// wait between requests, so only live runs start workers.
fn keep_warm(ctx: Ctx, endpoint: Endpoint, prompt: String) -> KeepWarm {
  case client.is_live(ctx.net) {
    False -> KeepWarm(fn() { Nil })
    True -> {
      let workers =
        seq.range(1, thresholds.map_keep_warm_workers)
        |> list.map(fn(worker) {
          process.spawn_unlinked(fn() {
            // Stagger the workers across the interval.
            process.sleep(
              thresholds.map_keep_warm_interval_ms
              * worker
              / { thresholds.map_keep_warm_workers + 1 },
            )
            warm_loop(ctx, endpoint, prompt)
          })
        })
      KeepWarm(fn() { list.each(workers, process.kill) })
    }
  }
}

fn warm_loop(ctx: Ctx, endpoint: Endpoint, prompt: String) -> Nil {
  let _ = send_prompt(ctx, endpoint, endpoint.name <> "/keep-warm", prompt)
  process.sleep(thresholds.map_keep_warm_interval_ms)
  warm_loop(ctx, endpoint, prompt)
}

/// Flood `flooder` with a fresh prompt, then prove `prober` against its
/// prefix ladder.
fn run_direction(
  ctx: Ctx,
  params: Params,
  flooder: #(Endpoint, Calibration),
  prober: #(Endpoint, Calibration),
  prng: Prng,
) -> #(Direction, Prng) {
  let #(nonce, prng) = ladder.nonce(prng)
  let counts =
    ladder.word_counts(
      thresholds.map_base_prefix_tokens,
      2 * { prober.1 }.chunk,
      params.l_probe,
      { prober.1 }.tokens_per_word,
    )
  let prompts = ladder.build(nonce, counts)
  let full = list.last(prompts) |> option.from_result |> option.unwrap("")
  let direction = fn(outcome, probe_counts, note) {
    Direction(
      { flooder.0 }.name,
      { prober.0 }.name,
      outcome,
      probe_counts,
      note,
    )
  }
  let flooded =
    prove.flood(params, fn() {
      observe(
        ctx,
        flooder.0,
        { flooder.0 }.name <> "/flood",
        full,
        { flooder.1 }.chunk,
      )
    })
  case flooded {
    prove.FloodFailed(attempts, reason) -> #(
      direction(
        Inconclusive,
        prove.Counts(0, 0, 0),
        "flood failed after "
          <> int.to_string(attempts)
          <> " attempts: "
          <> reason,
      ),
      prng,
    )
    prove.Covered(attempts) -> {
      let warm = keep_warm(ctx, flooder.0, full)
      let #(outcome, probe_counts) =
        prove.prove(params, fn(position) {
          case seq.at(prompts, position) {
            Ok(prefix) ->
              observe(
                ctx,
                prober.0,
                { prober.0 }.name <> "/prove/" <> int.to_string(position),
                prefix,
                { prober.1 }.chunk,
              )
            Error(Nil) -> Failed
          }
        })
      warm.stop()
      #(
        direction(
          outcome,
          probe_counts,
          "flood covered after " <> int.to_string(attempts) <> " requests",
        ),
        prng,
      )
    }
  }
}

pub type Mapped {
  Mapped(
    nodes: List(String),
    edges: List(Edge),
    directions: List(Direction),
    /// Pairs not measured because their relation followed from others.
    implied: List(Edge),
    /// Endpoints that could not be calibrated, with the reason.
    uncalibrated: List(#(String, String)),
  )
}

pub fn run(ctx: Ctx) -> StepResult {
  let params = params.preset(ctx.map_preset)
  let endpoints = [ctx.target, ..ctx.endpoints]
  let #(calibrated, prng) =
    list.fold(endpoints, #([], ctx.prng(ctx, id)), fn(acc, endpoint) {
      let #(done, prng) = acc
      ctx.progress("  calibrating " <> endpoint.name)
      let #(result, prng) = calibrate(ctx, endpoint, prng)
      #([#(endpoint, result), ..done], prng)
    })
  let calibrated = list.reverse(calibrated)
  let usable =
    list.filter_map(calibrated, fn(pair) {
      case pair.1 {
        Ok(calibration) -> Ok(#(pair.0, calibration))
        Error(_) -> Error(Nil)
      }
    })
  let uncalibrated =
    list.filter_map(calibrated, fn(pair) {
      case pair.1 {
        Error(reason) -> Ok(#({ pair.0 }.name, reason))
        Ok(_) -> Error(Nil)
      }
    })
  // Profile: rank by time to first byte, then order pairs by stride.
  let ranked =
    list.sort(usable, fn(a, b) {
      int.compare({ a.1 }.first_byte_us, { b.1 }.first_byte_us)
    })
    |> list.map(fn(pair) { { pair.0 }.name })
  let find = fn(name: String) {
    list.find(usable, fn(pair) { { pair.0 }.name == name })
  }
  let #(edges, directions, implied, _) =
    graph.pair_order(ranked)
    |> list.fold(#([], [], [], prng), fn(acc, pair) {
      let #(edges, directions, implied, prng) = acc
      let #(a, b) = pair
      case graph.implied(edges, a, b), find(a), find(b) {
        Some(relation), _, _ -> #(
          edges,
          directions,
          [Edge(a, b, relation), ..implied],
          prng,
        )
        None, Ok(first), Ok(second) -> {
          ctx.progress("  measuring " <> a <> " <-> " <> b)
          let #(forward, prng) = run_direction(ctx, params, first, second, prng)
          let #(backward, prng) =
            run_direction(ctx, params, second, first, prng)
          #(
            [
              Edge(a, b, graph.classify(forward.outcome, backward.outcome)),
              ..edges
            ],
            [backward, forward, ..directions],
            implied,
            prng,
          )
        }
        None, _, _ -> acc
      }
    })
  // Pairs involving an endpoint that could not be calibrated are unknown.
  let names = list.map(endpoints, fn(endpoint) { endpoint.name })
  let unknown =
    graph.pair_order(names)
    |> list.filter(fn(pair) {
      list.any(uncalibrated, fn(bad) { bad.0 == pair.0 || bad.0 == pair.1 })
    })
    |> list.map(fn(pair) { Edge(pair.0, pair.1, Unresolved) })
  build(
    ctx.map_preset,
    params,
    Mapped(
      nodes: names,
      edges: list.append(list.reverse(edges), unknown),
      directions: list.reverse(directions),
      implied: list.reverse(implied),
      uncalibrated: uncalibrated,
    ),
  )
}

fn relation_words(edge: Edge) -> String {
  case edge.relation {
    graph.Clone -> edge.a <> " and " <> edge.b <> " have equivalent cache reach"
    graph.AContainsB ->
      edge.b <> "'s cache reach lies inside " <> edge.a <> "'s"
    graph.BContainsA ->
      edge.a <> "'s cache reach lies inside " <> edge.b <> "'s"
    graph.Shared ->
      edge.a <> " and " <> edge.b <> " share part of their cache reach"
    graph.NoneObserved ->
      "no shared cache reach observed between " <> edge.a <> " and " <> edge.b
    Unresolved -> edge.a <> " and " <> edge.b <> ": unknown"
  }
}

fn is_resolved(relation: Relation) -> Bool {
  relation != Unresolved
}

pub fn build(
  preset: config.MapPreset,
  params: Params,
  mapped: Mapped,
) -> StepResult {
  let all_edges = list.append(mapped.edges, mapped.implied)
  let resolved = list.filter(all_edges, fn(edge) { is_resolved(edge.relation) })
  let unresolved =
    list.filter(mapped.edges, fn(edge) { !is_resolved(edge.relation) })
  let sharing =
    list.filter(resolved, fn(edge) { edge.relation != graph.NoneObserved })
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data(
      "preset",
      json.string(config.map_preset_to_string(preset)),
    )
    |> step.with_data("delta", json.float(params.delta))
    |> step.with_data("nodes", json.array(mapped.nodes, json.string))
    |> step.with_data(
      "adjacency",
      json.object(
        graph.adjacency(mapped.nodes, all_edges)
        |> list.map(fn(entry) {
          #(
            entry.0,
            json.array(entry.1, fn(related) {
              json.object([
                #("to", json.string(related.0)),
                #("relation", json.string(related.1)),
              ])
            }),
          )
        }),
      ),
    )
    |> step.with_data(
      "directions",
      json.array(mapped.directions, fn(direction) {
        json.object([
          #("flood", json.string(direction.flood)),
          #("probe", json.string(direction.probe)),
          #("outcome", json.string(prove.outcome_to_string(direction.outcome))),
          #("n", json.int(direction.counts.probes)),
          #("h", json.int(direction.counts.hits)),
          #("m", json.int(direction.counts.misses)),
        ])
      }),
    )
    |> step.with_data(
      "implied",
      json.array(mapped.implied, fn(edge) {
        json.preprocessed_array([json.string(edge.a), json.string(edge.b)])
      }),
    )
    |> step.with_data(
      "inconclusive_pairs",
      json.array(unresolved, fn(edge) {
        json.preprocessed_array([json.string(edge.a), json.string(edge.b)])
      }),
    )
    |> step.with_error_rate(step.ErrorRate(
      "per_direction",
      params.alpha,
      "each directional decision errs with probability at most alpha at resolution delta = "
        <> float.to_string(params.delta)
        <> ", under the two assumptions of arXiv:2608.20732; "
        <> int.to_string(list.length(mapped.directions))
        <> " directions were tested and the level is not corrected for that",
    ))
    |> step.with_details(
      list.flatten([
        [Mermaid(graph.mermaid(mapped.nodes, all_edges))],
        [
          Table(
            ["Flooded", "Probed", "Outcome", "Probes", "Hits", "Misses", "Note"],
            list.map(mapped.directions, fn(direction) {
              [
                direction.flood,
                direction.probe,
                prove.outcome_to_string(direction.outcome),
                int.to_string(direction.counts.probes),
                int.to_string(direction.counts.hits),
                int.to_string(direction.counts.misses),
                direction.note,
              ]
            }),
          ),
        ],
        case unresolved, mapped.uncalibrated {
          [], [] -> []
          _, _ -> [
            Paragraph(
              "Unknown, not unrelated: "
              <> string.join(
                list.append(
                  list.map(unresolved, fn(edge) { edge.a <> " <-> " <> edge.b }),
                  list.map(mapped.uncalibrated, fn(bad) {
                    bad.0 <> " (" <> bad.1 <> ")"
                  }),
                ),
                "; ",
              )
              <> ".",
            ),
          ]
        },
      ]),
    )
    |> step.with_finding(
      step.Limit,
      "A relation shows overlapping or nested cache reach. It does not identify a supplier, a contract or a forwarding path, and a shared backend is not by itself wrongdoing.",
    )
    |> step.with_finding(
      step.Limit,
      "The map is an under-approximation: an endpoint that reports no cached tokens removes itself from it, and a missing relation is unknown, not absent.",
    )
  }
  case resolved {
    [] ->
      step.inconclusive(
        id,
        case mapped.uncalibrated {
          [] -> "no_pair_resolved"
          _ -> "no_cache_telemetry"
        },
        "No pair of endpoints could be classified.",
      )
      |> decorate
    _ ->
      step.ran(id, Informational, case sharing {
        [] ->
          "No shared cache reach was observed among "
          <> int.to_string(list.length(mapped.nodes))
          <> " endpoints at this resolution."
        found -> string.join(list.map(found, relation_words), "; ") <> "."
      })
      |> decorate
  }
}
