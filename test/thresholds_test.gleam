//// Keeps `receipt/thresholds` in step with `docs/THRESHOLDS.md`.

import gleam/list
import gleam/string
import receipt/thresholds as t
import simplifile

fn document() -> String {
  let assert Ok(text) = simplifile.read("docs/THRESHOLDS.md")
  text
}

fn assert_documented(fragments: List(String)) {
  let text = document()
  list.each(fragments, fn(fragment) {
    case string.contains(text, fragment) {
      True -> Nil
      False -> panic as { "docs/THRESHOLDS.md is missing: " <> fragment }
    }
  })
}

pub fn alpha_is_five_percent_test() {
  assert t.alpha == 0.05
  assert_documented(["`alpha = 0.05`"])
}

pub fn transport_values_are_documented_test() {
  assert t.request_timeout_ms == 60_000
  assert t.long_request_timeout_ms == 180_000
  assert t.max_retries == 2
  assert t.backoff_base_ms == 1000
  assert t.backoff_cap_ms == 30_000
  assert t.retry_after_cap_ms == 60_000
  assert t.default_rpm == 20
  assert t.rate_limit_give_up == 3
  assert_documented([
    "| Request timeout | 60 s (180 s for Step 7 requests) |", "| Retries | 2,",
    "base 1 s, factor 2, full jitter, cap 30 s", "honoured up to 60 s",
    "at most 20 requests per minute", "3 consecutive HTTP 429",
  ])
}

pub fn token_injection_values_are_documented_test() {
  assert t.injection_texts == 30
  assert t.injection_min_valid_pairs == 20
  assert t.injection_min_coverage == 0.8
  assert t.injection_score_threshold == 0.725
  assert t.injection_anomaly_tokens == 100
  assert t.injection_clean_tokens == 20
  assert t.injection_estimate_overhead == 12
  assert #(t.injection_repeats_general, t.injection_repeats_full) == #(1, 3)
  assert_documented([
    "30 built-in controlled texts", "at least 20 paired counts",
    "coverage is at least 0.8", "`s >= 0.725`", "`m > 100`", "`-20 <= m <= 20`",
    "`ceil(characters / 4) + 12`", "| Repeats | 1 in `general`, 3 in `full` |",
  ])
}

pub fn override_and_leak_values_are_documented_test() {
  assert t.leak_min_chars == 40
  assert t.override_trials == 3
  assert t.override_min_failures == 2
  assert t.leak_fragment_chars == 12
  assert_documented([
    "at least 40 characters", "| Adherence trials | 3 |",
    "At least 2 of 3 trials fail", "any 12 or more consecutive characters",
  ])
}

pub fn context_values_are_documented_test() {
  assert t.context_canaries == 5
  assert t.context_sizes_general == [8000, 32_000]
  assert t.context_sizes_full == [8000, 32_000, 128_000, 400_000]
  assert t.context_window_fraction == 0.6
  assert_documented([
    "| Canaries per request | 5, evenly spaced |", "8 000 and 32 000 characters",
    "8 000, 32 000, 128 000 and 400 000 characters", "above 60% of",
  ])
}

pub fn latency_values_are_documented_test() {
  assert t.latency_probes == 10
  assert #(t.latency_probes_min, t.latency_probes_max) == #(3, 50)
  assert t.latency_max_tokens == 8
  assert t.latency_bimodal_gap == 0.5
  assert t.latency_cv_stable == 0.25
  assert t.latency_cv_variable == 0.5
  assert t.channel_min_confidence == 0.5
  assert_documented([
    "10 identical requests (`--latency-probes`, 3 to 50), `max_tokens = 8`",
    "exceeds 0.5 x the median", "below 0.25 stable; below 0.5 variable",
    "only at confidence 0.5 or more",
  ])
}

pub fn inflation_values_are_the_papers_test() {
  assert t.inflation_questions == 20
  assert t.inflation_tau == 0.6
  assert t.inflation_top_k == 3
  assert t.inflation_threshold == 3
  assert t.inflation_max_tokens == 1024
  assert t.inflation_block == 5
  assert t.inflation_min_valid_pairs == 16
  assert_documented([
    "| Questions `n` | 20 |", "| Relative-gain threshold `tau` | 0.60 |",
    "| Top-`k` | 3 |", "| Decision threshold `H` | 3 |",
    "temperature 0, `max_tokens = 1024`", "| Block size | 5 questions |",
    "| Minimum valid pairs for `clean` | 16 |",
  ])
}

pub fn upstream_map_values_are_documented_test() {
  assert #(t.map_delta_paper, t.map_delta_coarse) == #(0.05, 0.2)
  assert #(t.map_contain_misses_paper, t.map_contain_misses_coarse) == #(4, 2)
  assert #(t.map_flood_attempts_paper, t.map_flood_attempts_coarse)
    == #(1000, 250)
  assert t.map_error_abort == 8
  assert t.map_keep_warm_workers == 2
  assert t.map_keep_warm_interval_ms == 20_000
  assert t.map_base_prefix_tokens == 1280
  assert t.map_default_chunk_tokens == 128
  assert t.map_calibration_attempts == 3
  assert_documented([
    "| Resolution `delta` | 0.05 | 0.20 |", "| `M_contain` | 4 | 2 |",
    "| Flood attempt cap `A_max` | 1000 | 250 |",
    "| Consecutive error cap `E_abort` | 8 | 8 |",
    "| Keep-warm workers | 2 | 2 |", "20 s per worker", "1 280 tokens",
    "128 tokens", "| Calibration attempts | 3 |",
  ])
}

pub fn identity_values_are_documented_test() {
  assert t.identity_templates == 20
  assert t.identity_samples_per_batch == 5
  assert t.identity_tool_temperature == 0.7
  assert t.identity_tool_max_tokens == 256
  assert t.identity_prompts_per_batch == 10
  assert t.identity_reference_samples == 10
  assert t.identity_text_temperature == 0.5
  assert t.identity_text_max_tokens == 30
  assert t.identity_permutations == 4999
  assert t.identity_reject_at == 20.0
  assert #(t.identity_batches_general, t.identity_batches_full) == #(2, 5)
  assert t.identity_min_valid_samples == 4
  assert t.identity_min_valid_templates == 16
  assert t.identity_min_valid_prompts == 8
  assert t.identity_min_valid_references == 8
  assert_documented([
    "| Templates `K` (component A) | 20 |",
    "| Samples per template per batch, each side | 5 |",
    "temperature 0.7, `max_tokens = 256`",
    "| Prompts per batch (component B) | 10 |",
    "| Reference samples per prompt `m` | 10 |",
    "temperature 0.5, `max_tokens = 30`", "| 4 999 |", "`E >= 20`",
    "2 in `general`, 5 in `full`", "at least 4 of 5 valid samples",
    "at least 16 of 20 templates", "at least 8 of 10 prompts",
  ])
}

pub fn rejection_threshold_is_one_over_alpha_test() {
  assert t.identity_reject_at == 1.0 /. t.alpha
}
