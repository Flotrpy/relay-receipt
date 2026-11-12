//// Parameters of the upstream map, derived from a resolution `delta` and
//// a per-direction level `alpha` exactly as in Section III of
//// arXiv:2608.20732. See `docs/steps/16-upstream-map.md`.

import gleam/result
import receipt/config.{type MapPreset, Coarse, Paper}
import receipt/stats/binomial
import receipt/thresholds

pub type Params {
  Params(
    delta: Float,
    alpha: Float,
    /// Consecutive hits that end a flood.
    n_flood: Int,
    /// Misses tolerated by a `contained` decision.
    m_contain: Int,
    /// Successful probes a `contained` decision needs.
    n_prove: Int,
    /// Misses, after a hit, that reject containment.
    m_partial: Int,
    /// Straight misses that end a prove with `no_observed`.
    m_nohit: Int,
    /// Prefixes in the ladder.
    l_probe: Int,
    /// Flood attempts before giving up.
    flood_attempts: Int,
    /// Consecutive transport errors before giving up.
    error_abort: Int,
  )
}

/// Derive every threshold from `delta`, `alpha`, the miss allowance and
/// the flood attempt cap.
pub fn from_resolution(
  delta: Float,
  alpha: Float,
  m_contain: Int,
  flood_attempts: Int,
) -> Result(Params, Nil) {
  use streak <- result.try(binomial.streak_length(delta, alpha))
  use n_prove <- result.try(binomial.probes_for_misses(m_contain, delta, alpha))
  use m_partial <- result.try(binomial.misses_to_reject(n_prove, delta, alpha))
  Ok(Params(
    delta: delta,
    alpha: alpha,
    n_flood: streak,
    m_contain: m_contain,
    n_prove: n_prove,
    m_partial: m_partial,
    m_nohit: streak,
    l_probe: streak,
    flood_attempts: flood_attempts,
    error_abort: thresholds.map_error_abort,
  ))
}

/// The parameters of a preset.
pub fn preset(preset: MapPreset) -> Params {
  let derived = case preset {
    Paper ->
      from_resolution(
        thresholds.map_delta_paper,
        thresholds.alpha,
        thresholds.map_contain_misses_paper,
        thresholds.map_flood_attempts_paper,
      )
    Coarse ->
      from_resolution(
        thresholds.map_delta_coarse,
        thresholds.alpha,
        thresholds.map_contain_misses_coarse,
        thresholds.map_flood_attempts_coarse,
      )
  }
  // The preset inputs are constants for which derivation cannot fail.
  let assert Ok(params) = derived
  params
}
