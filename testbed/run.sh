#!/usr/bin/env bash
# Run Receipt against the evil relay under every fault, and against no
# fault, and keep the JSON reports and traces for the confusion matrix.
#
# Requirements: Erlang/OTP, Gleam, a LiteLLM gateway on 127.0.0.1:4000
# started from a local copy of testbed/litellm/config.example.yaml, and
# network access to the trusted reference. Everything runs on free tiers.
#
# Usage: testbed/run.sh <matrix> <out-dir>
#   matrix a  steps 3,4,5,6,8,9,10,15 under none/inject/pad/swap/rewrite
#   matrix b  step 17 under none/swap
#   matrix c  honest controls: provider A direct, provider B via the gateway
#   matrix d  step 16 over two relays that share one gateway
#   matrix e  head-to-head: api-relay-audit v2.5.0 on the same relay
#             conditions (set ARA_DIR to its checkout)
#
# Providers: REFERENCE_URL is provider A's OpenAI-compatible base URL (the
# trusted reference and the direct control). GATEWAY_CONTROL_MODEL is the
# gateway model name that routes to provider B. Neither is written in the
# repository, so published results can stay anonymous.
#
# Keys: the relay accepts any client key, so RECEIPT_API_KEY can be a
# placeholder. RECEIPT_REFERENCE_KEY must be a provider A key (or be
# injected by an egress proxy). LITELLM_MASTER_KEY is the gateway's key.
set -euo pipefail

matrix="${1:?matrix a|b|c|d}"
out="${2:?output directory}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "$0")/.." && pwd)"
receipt="$root/receipt"
relay_dir="$root/testbed/evilrelay"
reference="${REFERENCE_URL:?set REFERENCE_URL to the OpenAI-compatible base URL of provider A}"

: "${RECEIPT_API_KEY:=sk-testbed-client-0000000000000000}"
: "${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY}"
: "${RECEIPT_REFERENCE_KEY:?set RECEIPT_REFERENCE_KEY}"
export RECEIPT_API_KEY LITELLM_MASTER_KEY RECEIPT_REFERENCE_KEY

relay_pid=""
start_relay() { # fault port [substitute]
  (cd "$relay_dir" && RELAY_FAULT="$1" RELAY_PORT="$2" RELAY_SWAP_MODEL="${3:-}" \
    RELAY_UPSTREAM_KEY=LITELLM_MASTER_KEY exec gleam run >"$out/relay-$1-$2.log" 2>&1) &
  relay_pid=$!
  for _ in $(seq 1 60); do
    curl -s -o /dev/null "http://127.0.0.1:$2/v1/models" && return 0
    sleep 1
  done
  echo "relay on port $2 did not start" >&2
  return 1
}
stop_relay() {
  [ -n "$relay_pid" ] && kill "$relay_pid" 2>/dev/null || true
  pkill -f "evilrelay" 2>/dev/null || true
  relay_pid=""
  sleep 1
}
trap stop_relay EXIT

audit() { # name url model only [extra args...]
  local name="$1" url="$2" model="$3" only="$4"
  shift 4
  echo "== $name ($only)" >&2
  "$receipt" audit --url "$url" --model "$model" --api-format openai \
    --only "$only" --seed 20261112 --rpm "${RPM:-10}" --format json \
    --record "$out/$name.trace.jsonl" --output "$out/$name.json" "$@" \
    2>"$out/$name.log" || true
}

case "$matrix" in
  a)
    model="openai/gpt-oss-120b"
    for fault in none inject pad swap rewrite; do
      start_relay "$fault" 4100 "openai/gpt-oss-20b"
      audit "a-$fault" "http://127.0.0.1:4100/v1" "$model" 3,4,5,6,8,9,10,15 \
        --reference-url "$reference" --reference-model "$model"
      stop_relay
    done
    ;;
  b)
    model="qwen/qwen3.8-27b"
    for fault in swap none; do
      start_relay "$fault" 4100 "openai/gpt-oss-20b"
      audit "b-$fault" "http://127.0.0.1:4100/v1" "$model" 17 \
        --reference-url "$reference" --reference-model "$model" --rpm 20
      stop_relay
    done
    ;;
  c)
    # CONTROL_MODEL and CONTROL_STEPS let the direct control move to a
    # model whose daily free quota is not spent; CONTROL_ONLY=direct|gateway
    # runs one half.
    model="${CONTROL_MODEL:-openai/gpt-oss-120b}"
    steps="${CONTROL_STEPS:-1,3,4,5,6,7,8,9,10,12,13,14,15}"
    if [ "${CONTROL_ONLY:-direct}" != "gateway" ]; then
      RECEIPT_API_KEY="$RECEIPT_REFERENCE_KEY" audit "c-direct" "$reference" "$model" \
        "$steps" --reference-url "$reference" --reference-model "$model"
    fi
    if [ "${CONTROL_ONLY:-gateway}" != "direct" ]; then
      gateway_model="${GATEWAY_CONTROL_MODEL:?set GATEWAY_CONTROL_MODEL to the gateway model for provider B}"
      RECEIPT_API_KEY="$LITELLM_MASTER_KEY" audit "c-gateway" \
        "http://127.0.0.1:4000/v1" "$gateway_model" 3,4,5,6,8,9,10,12,13,14,15
    fi
    ;;
  d)
    start_relay none 4100
    first="$relay_pid"
    start_relay none 4200
    audit "d-shared" "http://127.0.0.1:4100/v1" "qwen/qwen3.8-27b" 16 \
      --profile full --endpoint "relay2=http://127.0.0.1:4200/v1,qwen/qwen3.8-27b,RECEIPT_API_KEY"
    kill "$first" 2>/dev/null || true
    ;;
  e)
    ara="${ARA_DIR:?set ARA_DIR to an api-relay-audit v2.5.0 checkout}"
    # A separate model from matrix A, to stay inside free daily quotas.
    model="openai/gpt-oss-20b"
    for fault in none inject rewrite; do
      start_relay "$fault" 4100
      echo "== e-$fault (api-relay-audit)" >&2
      (cd "$ara" && python3 audit.py --key-env RECEIPT_API_KEY \
        --url "http://127.0.0.1:4100/v1" --model "$model" \
        --skip-infra --skip-context --skip-latency-variance \
        --format json --output "$out/e-$fault.ara.json") \
        >"$out/e-$fault.ara.log" 2>&1 || true
      audit "e-$fault" "http://127.0.0.1:4100/v1" "$model" 3,4,5,6,8,9,10,12,14
      stop_relay
    done
    ;;
  *)
    echo "unknown matrix: $matrix" >&2
    exit 2
    ;;
esac
