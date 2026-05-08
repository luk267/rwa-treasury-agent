#!/usr/bin/env bash
# Start Anvil, deploy contracts, write deployments/local.json, keep Anvil running.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC_URL="http://127.0.0.1:8545"
DEPLOYMENTS_DIR="$REPO_ROOT/deployments"
LOG_FILE="$REPO_ROOT/.anvil.log"

# Default Foundry mnemonic - Account #0 is deployer + agent.
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
    echo "Stopping Anvil (pid=$ANVIL_PID)..."
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if lsof -ti :8545 >/dev/null 2>&1; then
  echo "ERROR: Port 8545 is already in use. Stop the existing process first." >&2
  exit 1
fi

echo "Starting Anvil..."
anvil >"$LOG_FILE" 2>&1 &
ANVIL_PID=$!

echo "Waiting for RPC..."
for i in {1..50}; do
  if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 50 ]]; then
    echo "ERROR: Anvil did not become ready in 5s. See $LOG_FILE" >&2
    exit 1
  fi
done

echo "Deploying contracts..."
DEPLOY_OUT=$(
  cd "$REPO_ROOT/contracts" && \
  forge script script/DeployLocal.s.sol:DeployLocal \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --broadcast \
    -vvv
)

extract() {
  echo "$DEPLOY_OUT" | grep -oE "^  $1=\s*[^ ]+\s*[^ ]*" | head -1 | awk '{print $NF}'
}

VAULT=$(extract vault)
MOCK=$(extract mock)
CP1=$(extract cp1)
CP2=$(extract cp2)
CP1_CAP_WEI=$(extract cp1DailyCap)
CP2_CAP_WEI=$(extract cp2DailyCap)
EXPOSURE_WEI=$(extract mockExposureCap)
FUNDING_WEI=$(extract vaultFunding)

to_human() {
  local wei=$1
  local len=${#wei}
  if (( len <= 18 )); then echo "0"; else echo "${wei:0:len-18}"; fi
}

mkdir -p "$DEPLOYMENTS_DIR"
cat > "$DEPLOYMENTS_DIR/local.json" <<EOF
{
  "chainId": 31337,
  "rpcUrl": "$RPC_URL",
  "vault": "$VAULT",
  "tokens": [
    { "address": "$MOCK", "symbol": "MOCK", "decimals": 18 }
  ],
  "counterparties": [
    { "address": "$CP1", "name": "cp1", "dailyCap": "$(to_human "$CP1_CAP_WEI")" },
    { "address": "$CP2", "name": "cp2", "dailyCap": "$(to_human "$CP2_CAP_WEI")" }
  ],
  "exposureCaps": [
    { "token": "$MOCK", "cap": "$(to_human "$EXPOSURE_WEI")" }
  ],
  "vaultFunding": "$(to_human "$FUNDING_WEI")"
}
EOF

echo ""
echo "Ready."
echo "  Vault:     $VAULT"
echo "  Mock:      $MOCK"
echo "  Funding:   $(to_human "$FUNDING_WEI") MOCK"
echo "  Anvil PID: $ANVIL_PID  (Ctrl+C to stop)"
echo ""

wait "$ANVIL_PID"
