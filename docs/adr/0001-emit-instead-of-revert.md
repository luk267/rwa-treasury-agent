# ADR-0001: Policy rejections emit an event instead of reverting

- **Status:** Accepted
- **Date:** 2026-11-13

## Context

`executeTransfer` can refuse a transfer for two kinds of reasons:

- **Authorization:** the caller has no `AGENT_ROLE`, or the vault is paused.
  Invalid input (an amount of 0) belongs here too.
- **Policy:** the token is not allowed, the recipient is not whitelisted, the
  counterparty's or the token's daily cap has no room, or the ERC-3643 token
  rejects the transfer.

The usual answer in Solidity is to revert in every case. Comparable designs do
that: Zodiac Roles reverts with `ConditionViolation`, and the reference token
gate of ERC-8226 reverts with `MandateBlocked(reason)`.

An earlier version of this repo justified events with "the agent can read the
reason without parsing revert bytes". That argument no longer holds: the agent
decodes custom errors with viem at no extra cost.

## Decision

One rule, two channels:

- **Authorization reverts.** A caller without the right to ask gets a revert,
  and so does invalid input.
- **Policy decisions are logged and returned.** Each of the five gates either
  passes or emits `TransferRejected(token, to, amount, reason, detail)` and
  returns normally. `executeTransfer` returns
  `(bool executed, RejectReason reason, bytes detail)` with the same values;
  a transfer that goes through returns `(true, None, "")`. `reason` is a typed
  `RejectReason`. For gate 5, `detail` holds the token's revert data, for
  example `UnverifiedIdentity()`.
- **No reason, no log.** If the token reverts without data or returns
  `false`, the vault reverts with `TokenTransferFailedWithoutReason`. That is
  not a policy decision, and an out-of-gas inside the token looks exactly
  like it.

The reason for this is the audit trail. A reverted transaction is still on
chain (sender, calldata, status 0), but it has no logs, and its revert reason
is not in the receipt. A monitor would need a trace API or an archive node to
find it. With the event, every blocked attempt by the agent is found with one
`eth_getLogs` filter on `TransferRejected`, with a typed reason and the
token's own error.

ERC-8226 shares the idea of a typed reason: `canExecute(...)` returns
`(bool ok, MandateReason reason)` with the first failing check. It uses the
reason as a pre-check and still reverts at execution. This vault applies the
reason at execution and keeps it in the log.

## Consequences

- A monitor sees every refusal without special infrastructure.
- The agent pays gas for refused attempts. It can fill the log with
  rejections, but only at its own cost and without moving tokens.
- Wallets and explorers show "Success" for a refused transfer. Readers must
  look at the events, not the transaction status.
- A contract that calls the vault (a Safe, a multicall) reads the outcome
  from the return value and does not need the logs. The agent's pre-check is
  a plain `eth_call` of `executeTransfer`, so the check and the execution run
  the same code and cannot drift apart.
- An out-of-gas inside `token.transfer` reverts the whole call instead of
  being logged as a compliance rejection. A token that catches its own
  out-of-gas and reverts with data still produces a logged rejection (see
  L12 in the [threat model](../threat-model.md#known-limitations)).

## Rejected alternatives

- **Revert for everything, with `TransferBlocked(RejectReason reason, bytes detail)`.**
  Closer to Zodiac and ERC-8226, and simpler for integrators. Rejected
  because the on-chain trail of blocked attempts disappears, and the change
  would touch the contract, every test, the agent and the docs without
  fixing a real defect.
- **Emit an event and then revert.** Not possible: a revert discards the
  events of the reverted call.
- **A separate `checkTransfer` view.** Gives callers a pre-check, but
  duplicates the policy logic in a second function that can drift from
  `executeTransfer`. The return value gives the same pre-check from the same
  code path.
