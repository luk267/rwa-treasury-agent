# agent

TypeScript orchestrator for the [rwa-treasury-agent](../README.md). Wraps the
`TreasuryVault` contract as an MCP server with three tools, drives a Claude
model through the Agent SDK, and surfaces every transfer outcome in plain
language.

## Stack

- [viem](https://viem.sh) - Ethereum client (`simulateContract`,
  `simulateCalls`, `writeContract`)
- [`@anthropic-ai/claude-agent-sdk`](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) -
  agent loop and MCP server primitives
- [zod](https://zod.dev) - tool input schemas
- `tsx` for running TypeScript directly, `dotenv` for environment loading

## Tools

The MCP server in [`src/index.ts`](src/index.ts) exposes three tools to the
model:

| Tool                         | Effect                                                              |
| ---------------------------- | ------------------------------------------------------------------- |
| `get_portfolio`              | Read vault holdings via `balanceOf` on each known token.            |
| `check_transfer_feasibility` | Two-phase off-chain simulation (no transaction). See below.         |
| `execute_transfer`           | `writeContract` + receipt parsing. Returns the decoded vault event. |

The system prompt ([`src/prompt.ts`](src/prompt.ts)) requires the model to
call `get_portfolio` first, then `check_transfer_feasibility` before any
`execute_transfer`. On rejection, the model maps the vault's `RejectReason`
enum back to a human-readable cause.

### Two-phase simulation

`check_transfer_feasibility` mirrors the vault's own design choice (emit
don't revert) on the off-chain side. Some failures revert, others emit a
`TransferRejected` event:

| Failure mode                                       | How it surfaces                |
| -------------------------------------------------- | ------------------------------ |
| `VaultPaused`, `AccessControlUnauthorizedAccount`  | Hard revert                    |
| `NotWhitelisted`, `DailyCapExceeded`               | `TransferRejected` event       |
| `ExposureCapExceeded`, `ERC3643Compliance`         | `TransferRejected` event       |

The tool runs `simulateContract` first to catch any revert, then
`simulateCalls` to decode the event log. The model therefore sees the same
outcome an on-chain submission would produce - including which gate would
have rejected it.

## Local development

The agent reads `deployments/local.json`, which is written by the repo's
local stack script:

```bash
# from the repo root, in a separate terminal:
./scripts/local-dev.sh        # starts Anvil + deploys contracts
```

Then, in `agent/`:

```bash
npm install
npm run typecheck                          # tsc --noEmit
npm start "show the vault holdings"
npm start "transfer 500 MOCK to cp1"
npm start "try to transfer 10000 MOCK to cp1"   # should hit the daily cap
```

The runtime prints each tool call (`→ name(args)`) and tool result (`← ...`)
so the policy decisions are visible during the run.

## Configuration

For non-local networks, copy `../.env.example` to `.env` and fill in
`RPC_URL_SEPOLIA`, `PRIVATE_KEY`, and `ANTHROPIC_API_KEY`. Sepolia wiring is
not yet enabled - the current [`src/config.ts`](src/config.ts) hardcodes the
Anvil account and the `foundry` chain, with a Sepolia path planned as the
next milestone.

## Source layout

```
src/
  index.ts        entry point: loads deployment, builds MCP server, runs query loop
  config.ts      loads deployments/local.json, viem clients, token/counterparty resolution
  prompt.ts      system prompt: rules, available tokens, counterparties, exposure caps
  abi.ts         vault + ERC-3643 ABI fragments, RejectReason enum
  tools/
    get-portfolio.ts             balanceOf across all known tokens
    check-transfer.ts            two-phase simulation
    execute-transfer.ts          writeContract + receipt event decoding
```
