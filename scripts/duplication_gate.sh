#!/usr/bin/env bash
#
# Duplication ratchet. Fails only on clones absent from the committed baseline,
# so the known backlog never blocks a build while new duplication does.
#
#   scripts/duplication_gate.sh check   # CI / mix precommit
#   scripts/duplication_gate.sh bless   # record the current set as accepted

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-check}"
BASELINE=".duplication-baseline.json"
REPORT="$(mktemp "${TMPDIR:-/tmp}/ptc-manager-clones.XXXXXX")"
RAW="$(mktemp "${TMPDIR:-/tmp}/ptc-manager-clones-raw.XXXXXX")"
trap 'rm -f "$REPORT" "$RAW"' EXIT

mix compile >&2

mix ex_dna lib/ test/ --format json --max-clones 1000000 >"$RAW"

sed -n '/^{/,$p' "$RAW" >"$REPORT"

if [ ! -s "$REPORT" ]; then
  echo "duplication gate: ex_dna produced no JSON report. Raw output:" >&2
  tail -20 "$RAW" >&2
  exit 1
fi

exec python3 scripts/duplication_gate.py "$MODE" "$REPORT" "$BASELINE"
