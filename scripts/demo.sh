#!/usr/bin/env bash
# Replay the five demo scenes against the running local stack.
# Start ./scripts/local-dev.sh in another terminal first.
# Scenes 1-4 are agent runs with --yes, so no transfer prompt interrupts them.
# Every agent run calls the Claude API and costs a little API credit.
# Scene 5 needs no API: it sends a refused transfer from the agent's account
# with cast and reads the vault's TransferRejected entry back from the chain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC_URL="http://127.0.0.1:8545"
DEPLOYMENT="$REPO_ROOT/deployments/local.json"
# Public Anvil test mnemonic. Account #5 holds AGENT_ROLE and nothing else.
ANVIL_MNEMONIC="test test test test test test test test test test test junk"
AGENT_INDEX=5
SCENES=5

if ! cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "ERROR: No chain at $RPC_URL. Start ./scripts/local-dev.sh in another terminal first." >&2
  exit 1
fi

scene() {
  local number=$1 title=$2 prompt=$3
  echo ""
  echo "=== Scene $number/$SCENES: $title ==="
  echo "> $prompt"
  echo ""
  (cd "$REPO_ROOT/agent" && npm start --silent -- --yes "$prompt")
}

# Scene 5: the transfer from scene 4, sent without the agent's pre-check.
# The vault refuses it at gate 5 and logs TransferRejected; this is the entry
# a monitor finds with one eth_getLogs filter.
rejected_on_chain() {
  local vault token cp3 agent sender receipt
  read -r vault token cp3 agent < <(node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const token = d.tokens.find((t) => t.symbol === "MOCK");
    const cp3 = d.counterparties.find((c) => c.name === "cp3");
    console.log(d.vault, token.address, cp3.address, d.roles.agent);' "$DEPLOYMENT")
  sender=$(cast wallet address --mnemonic "$ANVIL_MNEMONIC" --mnemonic-index "$AGENT_INDEX")
  if [[ "$(cast to-check-sum-address "$sender")" != "$(cast to-check-sum-address "$agent")" ]]; then
    echo "ERROR: Anvil account #$AGENT_INDEX ($sender) is not roles.agent ($agent). Re-run ./scripts/local-dev.sh." >&2
    exit 1
  fi

  echo ""
  echo "=== Scene 5/$SCENES: The refusal in the on-chain log ==="
  echo "> no agent: send scene 4's transfer from the agent account with cast"
  echo ""
  echo "cast send <vault> \"executeTransfer(address,address,uint256)\" <MOCK> <cp3> 100ether"
  receipt=$(cast send --rpc-url "$RPC_URL" --mnemonic "$ANVIL_MNEMONIC" --mnemonic-index "$AGENT_INDEX" \
    --json "$vault" "executeTransfer(address,address,uint256)" "$token" "$cp3" 100ether)
  echo "$receipt" | node -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const status = r.status === "0x1" ? "success" : "reverted";
    console.log(`  from ${r.from}, block ${BigInt(r.blockNumber)}, status ${status}`);'

  echo ""
  echo "cast logs --address <vault> --from-block 0 \"TransferRejected(...)\""
  local reasons=(None AssetNotAllowed NotWhitelisted DailyCapExceeded AssetDailyCapExceeded ERC3643Compliance)
  local unverified entries count block tx to data fields reason detail
  unverified=$(cast sig "UnverifiedIdentity()")
  # One line per entry: block, tx hash, recipient (indexed), non-indexed data.
  entries=$(cast logs --rpc-url "$RPC_URL" --from-block 0 --address "$vault" --json \
    "TransferRejected(address indexed token,address indexed to,uint256 amount,uint8 reason,bytes detail)" |
    node -e '
      const logs = JSON.parse(require("fs").readFileSync(0, "utf8"));
      for (const l of logs) {
        console.log(String(BigInt(l.blockNumber)), l.transactionHash, "0x" + l.topics[2].slice(26), l.data);
      }')
  count=$(grep -c . <<<"$entries" || true)
  echo "  TransferRejected entries in the chain: $count"
  while read -r block tx to data; do
    [[ -z "$block" ]] && continue
    fields=$(cast decode-abi --input "f(uint256,uint8,bytes)" "$data")
    reason=$(sed -n 2p <<<"$fields")
    detail=$(sed -n 3p <<<"$fields")
    echo "  block $block, tx $tx"
    echo "    to     $to"
    echo "    amount $(cast from-wei "$(sed -n 1p <<<"$fields" | awk '{print $1}')" | sed 's/\.0*$//') MOCK"
    echo "    reason $reason = ${reasons[$reason]:-unknown}"
    if [[ "$detail" == "$unverified" ]]; then
      echo "    detail $detail = UnverifiedIdentity()"
    else
      echo "    detail $detail"
    fi
  done <<<"$entries"
}

scene 1 "Holdings" "show the vault holdings"
scene 2 "Transfer within all limits" "transfer 500 MOCK to cp1"
scene 3 "Refused in the pre-check: daily cap" "transfer 6000 MOCK to cp1"
scene 4 "Refused in the pre-check: unverified identity" "transfer 100 MOCK to cp3"
rejected_on_chain
