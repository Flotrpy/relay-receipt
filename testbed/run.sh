#!/usr/bin/env bash
# Run Receipt against the evil relay under every fault, and against no
# fault, and keep the JSON reports and traces for the confusion matrix.
#
# Requirements: Erlang/OTP, Gleam, a LiteLLM gateway on 127.0.0.1:4000
# started from testbed/litellm/config.yaml, and network access to the
# Groq API (the trusted reference). Everything runs on free tiers.
#
# Usage: testbed/run.sh <matrix> <out-dir>
#   matrix a  steps 3,4,5,6,8,9,10,15 under none/inject/pad/swap/rewrite
#   matrix b  step 17 under none/swap
#   matrix c  honest controls: Groq direct and Gemini via the gateway
#   matrix d  step 16 over two relays that share one gateway
#
# Keys: the relay accepts any client key, so RECEIPT_API_KEY can be a
# placeholder. RECEIPT_REFERENCE_KEY must be a Groq key (or be injected by
# an egress proxy). LITELLM_MASTER_KEY is the gateway's key.
set -euo pipefail

matrix="${1:?matrix a|b|c|d}"
out="${2:?output directory}"
root="$(cd "$(dirname "$0")/.." && pwd)"
receipt="$root/receipt"
relay_dir="$root/testbed/evilrelay"
groq="https://api.groq.com/openai/v1"
mkdir -p "$out"

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
        --reference-url "$groq" --reference-model "$model"
      stop_relay
    done
    ;;
  b)
    model="qwen/qwen3.8-27b"
    for fault in swap none; do
      start_relay "$fault" 4100 "openai/gpt-oss-20b"
      audit "b-$fault" "http://127.0.0.1:4100/v1" "$model" 17 \
        --reference-url "$groq" --reference-model "$model" --rpm 20
      stop_relay
    done
    ;;
  c)
    model="openai/gpt-oss-120b"
    RECEIPT_API_KEY="$RECEIPT_REFERENCE_KEY" audit "c-groq-direct" "$groq" "$model" \
      1,3,4,5,6,7,8,9,10,12,13,14,15 --reference-url "$groq" --reference-model "$model"
    RECEIPT_API_KEY="$LITELLM_MASTER_KEY" audit "c-gemini-gateway" \
      "http://127.0.0.1:4000/v1" "gemma-4-26b-a4b-it" 3,4,5,6,8,9,10,12,13,14,15
    ;;
  d)
    start_relay none 4100
    first="$relay_pid"
    start_relay none 4200
    audit "d-shared" "http://127.0.0.1:4100/v1" "qwen/qwen3.8-27b" 16 \
      --profile full --endpoint "relay2=http://127.0.0.1:4200/v1,qwen/qwen3.8-27b,RECEIPT_API_KEY"
    kill "$first" 2>/dev/null || true
    ;;
  *)
    echo "unknown matrix: $matrix" >&2
    exit 2
    ;;
esac
