# agent

TypeScript orchestrator for the [rwa-treasury-agent](../README.md). Exposes
the `TreasuryVault` contract as three tools, drives a Claude model through its
own tool loop over the Messages API, and surfaces every transfer outcome in
plain language.

## Stack

- [viem](https://viem.sh) - Ethereum client (`simulateContract`,
  `simulateCalls`, `writeContract`)
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
| `get_portfolio`              | Read vault holdings via `balanceOf` on each known token.            |
| `check_transfer_feasibility` | Two-phase off-chain simulation (no transaction). See below.         |
| `execute_transfer`           | `writeContract` + receipt parsing. Returns the decoded vault event. |

The system prompt ([`src/prompt.ts`](src/prompt.ts)) requires the model to
call `get_portfolio` first, then `check_transfer_feasibility` before any
`execute_transfer`. On rejection, the model maps the vault's `RejectReason`
enum back to a human-readable cause.

Bad tool arguments come back as `UnknownToken`, `UnknownCounterparty` or
`InvalidAmount`. Any other failure in a tool is reported as `RpcError`.

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
revert data as `detail` in `TransferRejected`. [`src/outcome.ts`](src/outcome.ts)
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

Empty data or an unknown selector gives `"decoded": null` and a `note`.

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

The simulation is an aid for the model and the operator, not a control.
`execute_transfer` sends a real transaction, and the vault runs every check
again.

## Local development

The agent reads `deployments/local.json`, which is written by the repo's
local stack script:

```bash
# from the repo root, in a separate terminal:
./scripts/local-dev.sh        # starts Anvil + deploys contracts
```

Then, in `agent/`:

```bash
cp ../.env.example .env                    # then set ANTHROPIC_API_KEY
npm install
npm run typecheck                          # tsc --noEmit
npm test                                   # decoder tests (node:test)
npm start "show the vault holdings"
npm start "transfer 500 MOCK to cp1"       # asks before sending
npm start -- --yes "try to transfer 10000 MOCK to cp1"   # hits the daily cap
npm start -- --yes "transfer 100 MOCK to cp3"            # token: unverified identity
../scripts/demo.sh                                       # the four demo scenes
```

Note the `--` before `--yes`: without it, npm reads `--yes` as its own flag.

The runtime prints each tool call (`→ name(args)`), each tool result
(`← ...`) and the model's text, so the policy decisions are visible during
the run.

### Exit codes

| Code | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | The agent finished (a rejected or declined transfer is still 0).     |
| 1    | Bad input or configuration: no prompt, no API key, no deployment.    |
| 2    | Anthropic API or RPC failure, or the model stopped unexpectedly.     |

Errors go to stderr as one line, without a stack trace. The agent checks the
API key and the RPC before its first API call, so a stopped Anvil costs no
API credits.

## Configuration

Copy `../.env.example` to `.env`. The agent reads three variables:

| Variable             | Required | Purpose                                         |
| -------------------- | -------- | ----------------------------------------------- |
| `ANTHROPIC_API_KEY`  | yes      | Authenticates against the Claude Messages API.  |
| `AGENT_MODEL`        | no       | Claude model ID. Defaults to `claude-opus-5-5`. |
| `AGENT_AUTO_APPROVE` | no       | `1` skips the transfer prompt, like `--yes`.    |

The agent only runs against the local Anvil stack.
[`src/config.ts`](src/config.ts) hardcodes Anvil account #5 and the `foundry`
chain. The agent does not read `RPC_URL_SEPOLIA` or `PRIVATE_KEY`. Account #5
holds `AGENT_ROLE` and no other role. At startup the agent checks that its key
matches `roles.agent` in `deployments/local.json` and exits with an error
otherwise.

## Source layout

```
src/
  index.ts        entry point: env, deployment, pre-flight checks, operator prompt, exit codes
  loop.ts         tool loop over the Messages API
  outcome.ts      decodes TransferRejected detail, maps RejectReason
  outcome.test.ts decoder tests (node:test)
  config.ts       loads deployments/local.json, viem clients, token/counterparty/amount parsing
  prompt.ts       system prompt: rules, token errors, tokens, counterparties, exposure caps
  abi.ts          vault + ERC-3643 ABI fragments, token errors, RejectReason enum
  tools/
    types.ts                     VaultTool interface, shared input schema, error naming
    get-portfolio.ts             balanceOf across all known tokens
    check-transfer.ts            two-phase simulation
    execute-transfer.ts          writeContract + receipt event decoding
```
