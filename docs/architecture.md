# Architecture

This document describes how `rwa-treasury-agent` is put together: the three
layers, the responsibilities of each component, the transfer flow through the
policy gates, and the trust assumptions behind it.

---

## Three layers

The system has three layers, each one untrusted by the layer below.

| Layer       | Component                | Responsibility                                                                  |
| ----------- | ------------------------ | ------------------------------------------------------------------------------- |
| Reasoning   | TypeScript agent         | Decide what transfer to attempt; explain the on-chain outcome in plain language.|
| Policy      | `TreasuryVault.sol`      | Enforce four deterministic gates; own the tokens; emit a structured outcome.    |
| Compliance  | ERC-3643 (T-REX) token   | Identity / claim / jurisdiction checks at the token level.                      |

The agent never holds tokens and is not trusted to follow rules. The vault
holds the tokens and is the only path to move them. The token has the final
say - even a vault-approved transfer can be blocked by ERC-3643 compliance.

---

## Components

| Component                 | Role                                                                                                                       | Lives in                       |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| `TreasuryVault.sol`       | Holds ERC-3643 tokens. Enforces four policy gates. Calls the token's `transfer` and surfaces the outcome as an event.      | `contracts/src/`               |
| `IERC3643.sol`            | Minimal interface used by the vault - `transfer`, `transferFrom`, `balanceOf`. Intentionally narrow.                       | `contracts/src/interfaces/`    |
| `MockERC3643.sol`         | Test double modelled on T-REX v5: checks pause, freeze, balance, recipient identity and compliance in that order and reverts with the v5 error names. Its deployer is the issuer agent: verifies wallets, freezes, pauses, forces transfers. | `contracts/test/mocks/`        |
| TypeScript agent          | Own tool loop over the Claude Messages API with three tools (read holdings, simulate, submit). Asks the operator before a real transfer. System prompt requires simulate before execute and maps `RejectReason` and the decoded token error back to plain language. | `agent/src/` |
| `DeployLocal.s.sol`       | Foundry script: deploys both contracts, verifies the vault, `cp1` and `cp2` in the token, funds the vault, whitelists three counterparties, sets an exposure cap. | `contracts/script/`            |
| `scripts/local-dev.sh`    | Starts Anvil, runs the deploy script, parses output, writes `deployments/local.json`.                                      | `scripts/`                     |

---

## Roles

The vault uses OpenZeppelin `AccessControlDefaultAdminRules` with three
role-gated capabilities and one admin.

| Role                 | Granted by  | Capabilities                                                                       |
| -------------------- | ----------- | ---------------------------------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE` | Constructor | Grant and revoke other roles.                                                      |
| `TREASURER_ROLE`     | Constructor | `addCounterparty`, `deactivateCounterparty`, `setExposureCap`.                     |
| `AGENT_ROLE`         | Constructor | `executeTransfer` - the only on-chain entry point that moves tokens.               |
| `PAUSER_ROLE`        | Constructor | `pause`, `unpause`.                                                                |

The constructor takes one address per role. The deployer gets no role unless
it passes its own address. The agent's key therefore holds `AGENT_ROLE` only:
it cannot whitelist a counterparty, raise a cap, unpause, or grant itself a
role. The admin can grant and revoke all roles later.

The local stack uses one Anvil account per role:

| Account | Role                                |
| ------- | ----------------------------------- |
| #0      | `DEFAULT_ADMIN_ROLE`, deployer and token issuer |
| #1, #2  | Counterparties `cp1`, `cp2`         |
| #3      | `TREASURER_ROLE`                    |
| #4      | `PAUSER_ROLE`                       |
| #5      | `AGENT_ROLE` (the agent's key)      |
| #6      | Counterparty `cp3`: whitelisted in the vault, not verified in the token |

**Admin handover.** There is exactly one admin. `grantRole(DEFAULT_ADMIN_ROLE, …)`
is blocked. A handover takes two steps: the admin calls
`beginDefaultAdminTransfer(newAdmin)`, and the new admin calls
`acceptDefaultAdminTransfer()` once the delay has passed (one day in the local
stack). A typo in the address or a stolen admin key cannot move the role in a
single transaction, and the current admin can cancel during the delay.

**Stopping the agent.** The pauser calls `pause()`: every `executeTransfer`
reverts until `unpause()`. To lock the agent out for good, the admin calls
`revokeRole(AGENT_ROLE, agent)`.

---

## Transfer flow

`executeTransfer(token, to, amount)` runs four gates in a fixed order. Each
gate either rejects the transfer (emit `TransferRejected`, return) or allows
it through to the next gate. The pause check is the only one that reverts;
all four policy gates emit instead.

```mermaid
flowchart TD
    Start(["agent.executeTransfer(token, to, amount)"]) --> Pause{"paused?"}
    Pause -->|"yes"| Revert["revert VaultPaused"]
    Pause -->|"no"| WL{"counterparty<br/>active?"}
    WL -->|"no"| RJ1["TransferRejected<br/>(NotWhitelisted)"]
    WL -->|"yes"| DC{"daily cap<br/>(per counterparty)<br/>still has room?"}
    DC -->|"no"| RJ2["TransferRejected<br/>(DailyCapExceeded)"]
    DC -->|"yes"| EX{"exposure cap<br/>(per asset)<br/>still has room?"}
    EX -->|"no"| RJ3["TransferRejected<br/>(ExposureCapExceeded)"]
    EX -->|"yes"| ERC["try token.transfer(to, amount)"]
    ERC -->|"reverts or<br/>returns false"| RJ4["TransferRejected<br/>(ERC3643Compliance, detail)"]
    ERC -->|"returns true"| OK["update daily counters<br/>emit TransferExecuted"]
```

Two design choices are worth flagging:

1. **Rejected transfers do not revert (except pause).** They emit a
   structured event so the agent can read the reason off-chain without
   parsing revert bytes. The agent layer treats `TransferRejected` as a
   normal outcome, not an error.
2. **Counters update only on success.** `_dailySpent[to][day]` and
   `_assetDailySpent[token][day]` are written *after* `token.transfer`
   returns true. A rejected ERC-3643 call leaves the counters untouched
   (verified by `test_executeTransfer_erc3643Rejects_dailyCapNotConsumed`).

For the source, see
[`contracts/src/TreasuryVault.sol:102-137`](../contracts/src/TreasuryVault.sol).

---

## Policy gates - reference

| Gate | Stored as                                       | Configured by               | Behaviour                                                                                                              |
| ---- | ----------------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| 1    | `bool _paused`                                  | `pause` / `unpause`         | Reverts `VaultPaused` if set. Hard stop - applies to every transfer attempt.                                           |
| 2    | `mapping(address => Counterparty) _counterparties` | `addCounterparty` / `deactivateCounterparty` | Recipient must have `active == true`. Deactivation is soft (preserves `addedAt` for audit).                            |
| 3    | `mapping(address => mapping(uint256 => uint256)) _dailySpent` | `addCounterparty(.., dailyCap)` | Per-counterparty per-day cap. Day bucket is `block.timestamp / 1 days`. Cap of zero means no transfer allowed.         |
| 4    | `mapping(address => uint256) _exposureCaps` and `_assetDailySpent` | `setExposureCap`             | Per-asset per-day outflow cap. `cap == 0` means unlimited. Aggregates across all counterparties for that token.        |
| 5    | (delegated)                                     | the token contract          | `try token.transfer(to, amount)` - captures revert bytes in `detail`, or rejects on `false` return.                    |

Reject reasons are carried in the `RejectReason` enum on the
`TransferRejected` event so an off-chain reader can branch on them without
string parsing.

---

## Why ERC-3643 (T-REX)

ERC-3643 (T-REX) is a standard for permissioned security tokens. The token
itself enforces identity-bound rules (KYC claim, jurisdiction, investor
type, transfer rules) via an attached compliance contract and an
`ONCHAINID`. A `transfer` call can revert if the recipient lacks a required
claim or violates a transfer rule.

The vault uses only the narrow surface needed for the policy work
(`transfer`, `transferFrom`, `balanceOf`) and treats compliance failures as
an outcome rather than an exception. This keeps the contract independent of
any specific compliance-module implementation while still slotting into a
real T-REX deployment.

---

## Trust model

| Component                       | Trusted to                                                             | Not trusted to                                        |
| ------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------- |
| Agent (TypeScript)              | Propose a transfer, simulate it, explain the resulting event.          | Choose recipients, choose amounts, bypass any gate.   |
| Operator prompt (`Proceed? [y/N]`) | Let a human stop a transfer before it is sent.                      | Act as a security boundary: the agent key can call the vault directly, so the gates must hold on their own. |
| `TreasuryVault.sol`             | Apply gates 1–4 in order. Emit a faithful outcome event.               | Decide jurisdiction / KYC / transfer-rule compliance. |
| ERC-3643 token                  | Final compliance decision (identity, claims, transfer rules).          | Provide reasoning suitable for off-chain explanation. |
| Admin / Treasurer / Pauser keys | Hold role management, the configuration authority and the kill-switch. | (Out of scope for this PoC - assumed non-malicious.)  |
| Token issuer (ERC-3643 "agent") | Verify identities, freeze wallets, pause the token, force transfers. ERC-3643 requires these rights. | Respect the vault's gates: a forced transfer moves the vault's tokens without a vault event and without touching its counters. |

The reasoning the agent emits off-chain is observability, not authorization.
The contract makes no assumption that the caller is honest, correct, or even
deterministic.

---

## Out of scope

These are deliberate omissions for the current iteration. They would be
required for a production deployment but are not part of the design goal,
which is to validate the three-layer policy + agent integration.

- **Multisig admin.** Each role sits on its own key, and the admin handover is
  two-step with a delay. The admin itself is still a single EOA, not a multisig.
- **`SafeERC20`.** The vault calls `token.transfer` directly inside
  `try`/`catch`. A real T-REX integration would use the safe wrapper.
- **`ONCHAINID` on the vault itself.** ERC-3643 only delivers to verified
  recipients, and the vault is one. Before it can be funded, the issuer must
  register it in the identity registry with an ONCHAINID. The mock stubs this
  with `setVerified`.
- **Mainnet or Sepolia deployment.** Currently local Anvil only. Sepolia
  is planned.

---

## Where to look in code

| Concern                                              | File                                                                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Policy gates in order, event emissions, role checks  | [`contracts/src/TreasuryVault.sol`](../contracts/src/TreasuryVault.sol)                                                         |
| ERC-3643 surface used by the vault                   | [`contracts/src/interfaces/IERC3643.sol`](../contracts/src/interfaces/IERC3643.sol)                                             |
| Test double modelled on T-REX v5                     | [`contracts/test/mocks/MockERC3643.sol`](../contracts/test/mocks/MockERC3643.sol)                                               |
| Token-side rejections and issuer rights              | [`contracts/test/unit/TreasuryVault.IssuerRights.t.sol`](../contracts/test/unit/TreasuryVault.IssuerRights.t.sol)               |
| Counters-not-consumed-on-reject test                 | [`contracts/test/unit/TreasuryVault.ERC3643Compliance.t.sol`](../contracts/test/unit/TreasuryVault.ERC3643Compliance.t.sol)     |
| Local deployment script                              | [`contracts/script/DeployLocal.s.sol`](../contracts/script/DeployLocal.s.sol)                                                   |
| Anvil bootstrap + deployment-info writer             | [`scripts/local-dev.sh`](../scripts/local-dev.sh)                                                                               |
| Agent entry point: pre-flight checks, exit codes     | [`agent/src/index.ts`](../agent/src/index.ts)                                                                                   |
| Tool loop over the Claude Messages API               | [`agent/src/loop.ts`](../agent/src/loop.ts)                                                                                     |
| Decoding the token's revert data in `detail`         | [`agent/src/outcome.ts`](../agent/src/outcome.ts)                                                                               |
| Two-phase simulation (revert + event logs)           | [`agent/src/tools/check-transfer.ts`](../agent/src/tools/check-transfer.ts)                                                     |
| System prompt with policy rules                      | [`agent/src/prompt.ts`](../agent/src/prompt.ts)                                                                                 |
