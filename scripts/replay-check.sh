#!/usr/bin/env bash
# Replay the committed synthetic trace through the built escript and
# require the committed sample report back (step durations aside).
# Used by CI; needs no network and no keys.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
"$root/receipt" audit \
  --replay "$root/test/fixtures/sample-relay.trace.jsonl" \
  --url https://relay.example/v1 --model test-model \
  --reference-url https://reference.example/v1 --reference-model test-model \
  --output "$out" 2>/dev/null
strip() { sed -E 's/Duration: [0-9]+ ms/Duration: - ms/' "$1"; }
if diff <(strip "$root/docs/examples/sample-report.md") <(strip "$out"); then
  echo "replay matches docs/examples/sample-report.md"
else
  echo "replay differs from docs/examples/sample-report.md" >&2
  exit 1
fi
