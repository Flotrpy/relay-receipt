//// Flood and Prove: Algorithms 1 and 2 of arXiv:2608.20732.
////
//// Both are written against a function that performs one request and
//// says what was observed, so the decision logic can be tested without a
//// network.

import receipt/cachemap/params.{type Params}

/// What one request showed about the cache.
pub type Observation {
  /// The response reported the planted prefix as cached.
  Hit
  /// The response reported no (or too little) cached prefix.
  Miss
  /// No response; the request may still have reached the backend.
  TimedOut
  /// A transport or HTTP error that carries no cache information.
  Failed
}

pub type FloodResult {
  /// `n_flood` consecutive hits were seen after this many attempts.
  Covered(attempts: Int)
  /// The attempt cap or the error cap was reached.
  FloodFailed(attempts: Int, reason: String)
}

/// Algorithm 1: send the prompt until `n_flood` consecutive hits.
pub fn flood(params: Params, send: fn() -> Observation) -> FloodResult {
  flood_loop(params, send, 0, 0, 0)
}

fn flood_loop(
  params: Params,
  send: fn() -> Observation,
  streak: Int,
  attempts: Int,
  errors: Int,
) -> FloodResult {
  case
    streak >= params.n_flood,
    attempts >= params.flood_attempts,
    errors >= params.error_abort
  {
    True, _, _ -> Covered(attempts)
    False, True, _ -> FloodFailed(attempts, "attempt cap reached")
    False, False, True -> FloodFailed(attempts, "consecutive errors")
    False, False, False ->
      case send() {
        Hit -> flood_loop(params, send, streak + 1, attempts + 1, 0)
        Miss -> flood_loop(params, send, 0, attempts + 1, 0)
        TimedOut | Failed ->
          flood_loop(params, send, streak, attempts + 1, errors + 1)
      }
  }
}

pub type Outcome {
  /// The planted state covers the probed endpoint at the resolution.
  Contained
  /// No hit in `m_nohit` successful probes.
  NoObserved
  /// At least one hit, and enough misses to reject containment.
  Partial
  /// No decision: ladder exhausted, error cap, or too many misses.
  Inconclusive
}

pub type Counts {
  Counts(probes: Int, hits: Int, misses: Int)
}

/// Algorithm 2: probe a prefix ladder. `probe` is given the zero-based
/// ladder position to query.
///
/// A hit keeps the current prefix. A miss may itself have cached the
/// prefix it probed, so it consumes that prefix and moves to the next
/// longer one; so does a timeout, which is not counted as a probe.
pub fn prove(
  params: Params,
  probe: fn(Int) -> Observation,
) -> #(Outcome, Counts) {
  prove_loop(params, probe, Counts(0, 0, 0), 0, 0)
}

fn prove_loop(
  params: Params,
  probe: fn(Int) -> Observation,
  counts: Counts,
  position: Int,
  errors: Int,
) -> #(Outcome, Counts) {
  case
    counts.probes >= params.n_prove,
    position >= params.l_probe,
    errors >= params.error_abort
  {
    True, _, _ ->
      case counts.misses <= params.m_contain {
        True -> #(Contained, counts)
        False -> #(Inconclusive, counts)
      }
    False, True, _ | False, False, True -> #(Inconclusive, counts)
    False, False, False ->
      case probe(position) {
        Failed -> prove_loop(params, probe, counts, position, errors + 1)
        TimedOut -> prove_loop(params, probe, counts, position + 1, errors + 1)
        Hit -> {
          let counts =
            Counts(..counts, probes: counts.probes + 1, hits: counts.hits + 1)
          decide(params, probe, counts, position)
        }
        Miss -> {
          let counts =
            Counts(
              ..counts,
              probes: counts.probes + 1,
              misses: counts.misses + 1,
            )
          decide(params, probe, counts, position + 1)
        }
      }
  }
}

fn decide(
  params: Params,
  probe: fn(Int) -> Observation,
  counts: Counts,
  position: Int,
) -> #(Outcome, Counts) {
  case
    counts.hits == 0 && counts.misses >= params.m_nohit,
    counts.hits > 0 && counts.misses >= params.m_partial
  {
    True, _ -> #(NoObserved, counts)
    False, True -> #(Partial, counts)
    False, False -> prove_loop(params, probe, counts, position, 0)
  }
}

pub fn outcome_to_string(outcome: Outcome) -> String {
  case outcome {
    Contained -> "contained"
    NoObserved -> "no_observed"
    Partial -> "partial"
    Inconclusive -> "inconclusive"
  }
}
