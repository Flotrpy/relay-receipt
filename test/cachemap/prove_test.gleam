import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import receipt/cachemap/params.{type Params, Params}
import receipt/cachemap/prove.{
  Contained, Counts, Covered, Failed, FloodFailed, Hit, Inconclusive, Miss,
  NoObserved, Partial, TimedOut,
}
import receipt/config
import support/sequence

fn paper() -> Params {
  params.preset(config.Paper)
}

fn coarse() -> Params {
  params.preset(config.Coarse)
}

pub fn paper_preset_reproduces_the_published_thresholds_test() {
  let Params(
    n_flood: n_flood,
    m_contain: m_contain,
    n_prove: n_prove,
    m_partial: m_partial,
    m_nohit: m_nohit,
    l_probe: l_probe,
    flood_attempts: flood_attempts,
    error_abort: error_abort,
    ..,
  ) = paper()
  assert #(n_flood, m_contain, n_prove, m_partial, m_nohit, l_probe)
    == #(59, 4, 181, 15, 59, 59)
  assert #(flood_attempts, error_abort) == #(1000, 8)
}

pub fn coarse_preset_matches_the_design_document_test() {
  let p = coarse()
  assert #(p.n_flood, p.m_contain, p.n_prove, p.m_partial, p.m_nohit, p.l_probe)
    == #(14, 2, 30, 11, 14, 14)
  assert p.flood_attempts == 250
}

pub fn derivation_rejects_impossible_parameters_test() {
  assert params.from_resolution(0.0, 0.05, 4, 100) == Error(Nil)
  assert params.from_resolution(0.05, 1.5, 4, 100) == Error(Nil)
}

pub fn flood_stops_after_enough_consecutive_hits_test() {
  let feed = sequence.start(list.repeat(Hit, 100), Hit)
  assert prove.flood(coarse(), fn() { sequence.next(feed) }) == Covered(14)
  assert sequence.served(feed) == 14
}

pub fn a_miss_resets_the_flood_streak_test() {
  let script =
    list.flatten([list.repeat(Hit, 13), [Miss], list.repeat(Hit, 14)])
  let feed = sequence.start(script, Miss)
  assert prove.flood(coarse(), fn() { sequence.next(feed) }) == Covered(28)
}

pub fn flood_gives_up_at_the_attempt_cap_test() {
  let feed = sequence.start([], Miss)
  assert prove.flood(coarse(), fn() { sequence.next(feed) })
    == FloodFailed(250, "attempt cap reached")
}

pub fn flood_gives_up_after_consecutive_errors_test() {
  let feed = sequence.start([Hit, Hit], Failed)
  assert prove.flood(coarse(), fn() { sequence.next(feed) })
    == FloodFailed(10, "consecutive errors")
}

pub fn an_error_between_hits_does_not_reset_the_streak_test() {
  let script =
    list.flatten([list.repeat(Hit, 7), [Failed], list.repeat(Hit, 7)])
  let feed = sequence.start(script, Miss)
  assert prove.flood(coarse(), fn() { sequence.next(feed) }) == Covered(15)
}

pub fn all_hits_are_contained_test() {
  let #(outcome, counts) = prove.prove(coarse(), fn(_) { Hit })
  assert outcome == Contained
  assert counts == Counts(30, 30, 0)
}

pub fn a_few_misses_are_still_contained_test() {
  let script = list.flatten([[Miss, Hit, Miss], list.repeat(Hit, 40)])
  let feed = sequence.start(script, Hit)
  let #(outcome, counts) = prove.prove(coarse(), fn(_) { sequence.next(feed) })
  assert outcome == Contained
  assert counts == Counts(30, 28, 2)
}

pub fn straight_misses_are_no_observed_test() {
  let #(outcome, counts) = prove.prove(coarse(), fn(_) { Miss })
  assert outcome == NoObserved
  assert counts == Counts(14, 0, 14)
}

pub fn a_hit_then_many_misses_is_partial_test() {
  let feed = sequence.start([Hit], Miss)
  let #(outcome, counts) = prove.prove(coarse(), fn(_) { sequence.next(feed) })
  assert outcome == Partial
  assert counts == Counts(12, 1, 11)
}

pub fn too_many_misses_for_containment_without_partial_is_inconclusive_test() {
  // 3 misses spread among hits: more than M_contain = 2, fewer than
  // M_partial = 11, and the probe budget runs out.
  let script =
    list.flatten([[Hit, Miss, Hit, Miss, Hit, Miss], list.repeat(Hit, 40)])
  let feed = sequence.start(script, Hit)
  let #(outcome, counts) = prove.prove(coarse(), fn(_) { sequence.next(feed) })
  assert outcome == Inconclusive
  assert counts == Counts(30, 27, 3)
}

pub fn a_miss_advances_the_ladder_and_a_hit_does_not_test() {
  let feed = sequence.start([Hit, Hit, Miss, Hit, Miss], Hit)
  let record = recorder()
  let _ =
    prove.prove(coarse(), fn(position) {
      record.push(position)
      sequence.next(feed)
    })
  assert list.take(record.all(), 7) == [0, 0, 0, 1, 1, 2, 2]
}

pub fn timeouts_consume_prefixes_but_are_not_probes_test() {
  let record = recorder()
  let #(outcome, counts) =
    prove.prove(coarse(), fn(position) {
      record.push(position)
      TimedOut
    })
  // Eight consecutive errors abort before the ladder runs out.
  assert outcome == Inconclusive
  assert counts == Counts(0, 0, 0)
  assert record.all() == [0, 1, 2, 3, 4, 5, 6, 7]
}

pub fn errors_do_not_consume_prefixes_test() {
  let record = recorder()
  let feed = sequence.start([Failed, Failed, Hit], Hit)
  let _ =
    prove.prove(coarse(), fn(position) {
      record.push(position)
      sequence.next(feed)
    })
  assert list.take(record.all(), 4) == [0, 0, 0, 0]
}

pub fn exhausting_the_ladder_is_inconclusive_test() {
  // Timeouts spaced by hits never reach the error cap but use up all 14
  // prefixes before 30 probes.
  let script = list.flatten(list.repeat([TimedOut, Hit], 14))
  let feed = sequence.start(script, Hit)
  let #(outcome, counts) = prove.prove(coarse(), fn(_) { sequence.next(feed) })
  assert outcome == Inconclusive
  assert counts.misses == 0
  assert counts.probes < 30
}

pub fn paper_preset_needs_181_probes_for_containment_test() {
  let #(outcome, counts) = prove.prove(paper(), fn(_) { Hit })
  assert outcome == Contained
  assert counts.probes == 181
}

pub fn outcome_names_test() {
  assert prove.outcome_to_string(Contained) == "contained"
  assert prove.outcome_to_string(NoObserved) == "no_observed"
  assert prove.outcome_to_string(Partial) == "partial"
  assert prove.outcome_to_string(Inconclusive) == "inconclusive"
}

type Recorder {
  Recorder(push: fn(Int) -> Nil, all: fn() -> List(Int))
}

type RecorderMessage {
  Push(Int)
  All(process.Subject(List(Int)))
}

fn recorder() -> Recorder {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(items: List(Int), message) {
      case message {
        Push(item) -> actor.continue([item, ..items])
        All(reply) -> {
          process.send(reply, list.reverse(items))
          actor.continue(items)
        }
      }
    })
    |> actor.start
  Recorder(push: fn(item) { process.send(started.data, Push(item)) }, all: fn() {
    process.call(started.data, 5000, All)
  })
}
