#!/usr/bin/env bash
# Replay the four demo scenes against the running local stack.
# Start ./scripts/local-dev.sh in another terminal first.
# Each scene is one agent run with --yes, so no transfer prompt interrupts it.
# Every run calls the Claude API and costs a little API credit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC_URL="http://127.0.0.1:8545"

if ! cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "ERROR: No chain at $RPC_URL. Start ./scripts/local-dev.sh in another terminal first." >&2
  exit 1
fi

scene() {
  local number=$1 title=$2 prompt=$3
  echo ""
  echo "=== Scene $number/4: $title ==="
  echo "> $prompt"
  echo ""
  (cd "$REPO_ROOT/agent" && npm start --silent -- --yes "$prompt")
}

scene 1 "Holdings" "show the vault holdings"
scene 2 "Transfer within all limits" "transfer 500 MOCK to cp1"
scene 3 "Rejected by the vault: daily cap" "transfer 6000 MOCK to cp1"
scene 4 "Rejected by the token: unverified identity" "transfer 100 MOCK to cp3"
