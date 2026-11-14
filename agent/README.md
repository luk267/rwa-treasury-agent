# agent

TypeScript orchestrator for the [rwa-treasury-agent](../README.md). Exposes
the `TreasuryVault` contract as three tools, drives a Claude model through its
own tool loop over the Messages API, and surfaces every transfer outcome in
plain language.

## Stack

- [viem](https://viem.sh) - Ethereum client (`simulateContract`,
  `writeContract`)
- [`@anthropic-ai/sdk`](https://www.npmjs.com/package/@anthropic-ai/sdk) -
  Claude Messages API client (no beta features)
- [zod](https://zod.dev) - tool input schemas, also turned into the JSON
  Schema the API sees
- `tsx` for running TypeScript directly, `dotenv` for environment loading

## Tools

Each tool in [`src/tools/`](src/tools/) implements the `VaultTool` interface
from [`src/tools/types.ts`](src/tools/types.ts): an API definition with
`strict: true`, a zod parser, a `requiresApproval` flag and a `run` function.
The model sees three tools:

| Tool                         | Effect                                                              |
| ---------------------------- | ------------------------------------------------------------------- |
| `get_portfolio`              | Read balances, token config, caps and today's usage from the chain. |
| `check_transfer_feasibility` | One `eth_call` of `executeTransfer` (no transaction). See below.    |
| `execute_transfer`           | `writeContract` + receipt parsing. Returns the decoded vault event. |

The system prompt ([`src/prompt.ts`](src/prompt.ts)) requires the model to
call `get_portfolio` first, then `check_transfer_feasibility` before any
`execute_transfer`. On rejection, the model maps the vault's `RejectReason`
enum back to a human-readable cause.

Bad tool arguments come back as `UnknownToken`, `UnknownCounterparty` or
`InvalidAmount`. An amount finer than the token's decimals is
`InvalidAmount`, not rounded. Any other failure in a tool is reported as
`RpcError`.

### Agent loop

[`src/loop.ts`](src/loop.ts) is the whole agent runtime, about 100 lines:

1. Send the history and the three tool definitions to `messages.create`
   (no streaming, `max_tokens: 16000`).
2. Append the model's reply to the history unchanged.
3. `stop_reason` `end_turn` ends the run. `tool_use` continues. Any other stop
   reason is an error.
4. Run each requested tool: look it up, validate the input with zod, ask the
   operator if the tool requires it, call `run`.
5. Send all `tool_result` blocks back in one user message and repeat, at most
   12 turns.

`strict: true` makes the API guarantee that tool inputs match the schema. The
agent still validates them locally with zod.

### Operator approval

Before `execute_transfer` runs, the agent prints the call and asks
`Proceed? [y/N]`. Anything but `y` declines, and the model receives
`{ "success": false, "reason": "DeclinedByOperator" }` as the tool result.
`--yes` or `AGENT_AUTO_APPROVE=1` skips the prompt. Without a terminal and
without `--yes`, the answer is no.

The prompt is a convenience for the operator, not a security boundary. The
agent key could call the vault directly. The vault's gates and the token's
compliance check are what actually stop a bad transfer.

### Readable rejection reasons

When the token itself refuses a transfer, the vault forwards the token's
revert data as `detail` in `TransferRejected` and in its return value.
[`src/outcome.ts`](src/outcome.ts)
decodes it with viem against the T-REX v5 errors (`UnverifiedIdentity`,
`ComplianceNotFollowed`, `FrozenWallet`, `EnforcedPause`,
`ERC20InsufficientBalance`) plus `Error(string)` and `Panic`:

```json
{
  "feasible": false,
  "reason": "ERC3643Compliance",
  "detail": { "raw": "0x58c10a24", "decoded": "UnverifiedIdentity()" }
}
```

An unknown selector gives `"decoded": null` and a `note`. Empty data does
not reach the agent: when the token gives no reason, the vault reverts with
`TokenTransferFailedWithoutReason`.

### Pre-check

`check_transfer_feasibility` calls `executeTransfer` once with
`simulateContract`, a plain `eth_call`. The vault returns
`(bool executed, RejectReason reason, bytes detail)`, the same values it
emits in its events, so no logs are needed. Some failures revert, others are
returned as a rejection:

| Failure mode                                       | How it surfaces                |
| -------------------------------------------------- | ------------------------------ |
| `VaultPaused`, `AccessControlUnauthorizedAccount`  | Revert                         |
| `ZeroAmount`, `TokenTransferFailedWithoutReason`   | Revert                         |
| `AssetNotAllowed`, `NotWhitelisted`                | Return value (`executed: false`) |
| `DailyCapExceeded`, `AssetDailyCapExceeded`        | Return value (`executed: false`) |
| `ERC3643Compliance`                                | Return value, token error in `detail` |

A revert is reported by its error name. The model therefore sees the same
outcome an on-chain submission would produce - including which gate would
have rejected it. `execute_transfer` gets no return value from a mined
transaction, so it reads the vault's event from the receipt.

The pre-check is an aid for the model and the operator, not a control.
`execute_transfer` sends a real transaction, and the vault runs every check
again.

A refusal in the pre-check leaves nothing on the chain: the prompt forbids
the model to send a transfer the dry run refused. Only a sent and refused
transfer emits `TransferRejected`. In the demo, scenes 3 and 4 stop at the
pre-check. Scene 5 sends scene 4's transfer from the agent's account with
`cast`, without the agent, and shows the `TransferRejected` entry a monitor
finds.

## Local development

By default the agent reads `deployments/local.json` (for Sepolia, see
[Configuration](#configuration)). The repo's local stack script writes it:

```bash
# from the repo root, in a separate terminal:
./scripts/local-dev.sh        # starts Anvil + deploys contracts
```

Then, in `agent/`:

```bash
cp ../.env.example .env                    # then set ANTHROPIC_API_KEY
npm install
npm run typecheck                          # tsc --noEmit
npm test                                   # unit tests (node:test), no network
npm start "show the vault holdings"
npm start "transfer 500 MOCK to cp1"       # asks before sending
npm start -- --yes "try to transfer 10000 MOCK to cp1"   # hits the daily cap
npm start -- --yes "transfer 100 MOCK to cp3"            # token: unverified identity
../scripts/demo.sh                                       # the five demo scenes
```

Note the `--` before `--yes`: without it, npm reads `--yes` as its own flag.

The runtime prints each tool call (`→ name(args)`), each tool result
(`← ...`) and the model's text, so the policy decisions are visible during
the run.

### Exit codes

| Code | Meaning                                                                      |
| ---- | ---------------------------------------------------------------------------- |
| 0    | The agent finished (a rejected or declined transfer is still 0).             |
| 1    | Bad input or configuration: no prompt, no API key, no or invalid deployment, unknown network, missing Sepolia variable, wrong key or chain. |
| 2    | Anthropic API or RPC failure, or the model stopped unexpectedly.             |

Errors go to stderr as one line, without a stack trace. The agent checks the
API key and the RPC before its first API call, so a stopped Anvil costs no
API credits.

## Configuration

Copy `../.env.example` to `.env`. The agent reads six variables:

| Variable             | Required     | Purpose                                                    |
| -------------------- | ------------ | ---------------------------------------------------------- |
| `ANTHROPIC_API_KEY`  | yes          | Authenticates against the Claude Messages API.             |
| `AGENT_MODEL`        | no           | Claude model ID. Defaults to `claude-opus-5-5`.            |
| `AGENT_AUTO_APPROVE` | no           | `1` skips the transfer prompt, like `--yes`.               |
| `AGENT_NETWORK`      | no           | `local` (default) or `sepolia`.                            |
| `RPC_URL_SEPOLIA`    | with sepolia | Sepolia RPC endpoint.                                      |
| `AGENT_PRIVATE_KEY`  | with sepolia | The agent's key. Must hold `AGENT_ROLE` in the vault.      |

[`src/config.ts`](src/config.ts) picks the network:

| `AGENT_NETWORK` | Deployment file            | Chain     | RPC                        | Key                          |
| --------------- | -------------------------- | --------- | -------------------------- | ---------------------------- |
| `local`         | `deployments/local.json`   | `foundry` | `rpcUrl` in the file       | Anvil account #5, hardcoded  |
| `sepolia`       | `deployments/sepolia.json` | `sepolia` | `RPC_URL_SEPOLIA`          | `AGENT_PRIVATE_KEY`          |

The Anvil key is used only for `local`, and `local` ignores the two Sepolia
variables. `sepolia.json` is committed and has no `rpcUrl`, because an RPC URL
usually carries a provider key. At startup the agent checks that its key
matches `roles.agent` in the deployment file, that the file is for the
network's chain, and that the RPC serves that chain. Any mismatch exits with
code 1. Error messages name the variable, never its value.

## Source layout

```
src/
  index.ts        entry point: env, deployment, pre-flight checks, operator prompt, exit codes
  loop.ts         tool loop over the Messages API
  loop.test.ts    loop against a fake client: stop reasons, turn limit, approval, input errors
  outcome.ts      decodes TransferRejected detail, maps RejectReason
  outcome.test.ts decoder tests
  config.ts       network choice, validates deployments/<network>.json (zod), key and RPC, viem clients, token/counterparty/amount parsing
  config.test.ts  names, addresses, amounts, broken deployment files, networks, keys, the committed sepolia.json
  prompt.ts       system prompt: rules, gate order, reverts, token errors, token and counterparty names
  prompt.test.ts  the prompt explains every reject reason, vault revert and token error
  abi.ts          vault + ERC-3643 ABI fragments, token errors, RejectReason enum
  tools/
    types.ts                     VaultTool interface, shared input schema, transfer arguments, revert and error naming
    get-portfolio.ts             balances, token config, caps and today's usage, read from the vault
    check-transfer.ts            pre-check: one eth_call, decodes the return value
    execute-transfer.ts          writeContract + receipt event decoding (vault logs only)
    tools.test.ts                shared helpers, revert and failure paths, receipt decoding
```
