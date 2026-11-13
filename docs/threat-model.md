# Threat model

This document lists what the system protects, who can act on it, what it
assumes, and which threats it handles. Each mitigation names the test that
shows it. Known gaps are listed at the end, open ones first, then the ones
already fixed, so a reviewer does not have to find them.

Scope: `TreasuryVault.sol`, the TypeScript agent, and the local stack with
`MockERC3643`. The component layout is in [`architecture.md`](architecture.md).

**How to read the table.** A row starts from something an actor could try.
"Mitigation" is what stops or limits it. "Test" is the Foundry test in
`contracts/test` that shows the mitigation working. "Residual risk" is what is
left after the mitigation. A residual risk is not a bug; it is the part the
design accepts or leaves to a later fix.

---

## Assets

- The tokens the vault holds.
- The vault's policy: token allowlist, counterparty whitelist, daily caps per
  counterparty and token, daily outflow caps per token, pause flag.
- The role assignment: who holds `DEFAULT_ADMIN_ROLE`, `TREASURER_ROLE`,
  `AGENT_ROLE` and `PAUSER_ROLE`.
- The audit trail: `TransferExecuted` and `TransferRejected` events.

## Actors

| Actor                     | Can do                                                                                 | Trusted? |
| ------------------------- | -------------------------------------------------------------------------------------- | -------- |
| AI agent                  | Call `executeTransfer` with any token, recipient and amount. Read chain state via RPC. | No. Assume its key and its model can be misused (prompt injection, bugs, key theft). |
| Admin                     | Grant and revoke roles. Hand over the admin role in two steps with a delay.            | Yes      |
| Treasurer                 | Allow and block tokens, add and deactivate counterparties, set daily caps per counterparty and token and a daily outflow cap per token. | Yes      |
| Pauser                    | Pause and unpause the vault.                                                           | Yes      |
| Issuer (ERC-3643 agent)   | Verify identities, freeze, pause the token, force transfers, recover, mint, burn.      | Yes for its own token. Not bound by the vault. |
| Counterparty              | Receive tokens.                                                                        | No       |
| RPC provider              | Answer the agent's reads and simulations, relay its transactions.                      | No       |
| Operator                  | Answer `Proceed? [y/N]` before a real transfer.                                        | A convenience, not a security boundary. |

## Assumptions

- The admin, treasurer and pauser keys are held by honest parties and kept
  safe. For production this means a multisig and a timelock
  ([ADR-0002](adr/0002-admin-rights-and-no-upgradeability.md)).
- The issuer has registered the vault in the token's identity registry.
  Without it the vault cannot receive tokens at all.
- No contract other than the agent's key holds `AGENT_ROLE`.
- Validators cannot shift `block.timestamp` far enough to matter for a
  one-day bucket.
- The agent's text output is observability. Nothing on-chain depends on it.

---

## Threats and mitigations

| # | Threat | Mitigation | Test | Residual risk |
| - | ------ | ---------- | ---- | ------------- |
| 1 | A prompt injection or a bug makes the agent pay an attacker's address. | Gate 2: the recipient must be an active counterparty. | `test_executeTransfer_toUnknownCounterparty_emitsRejected_noRevert`, `test_executeTransfer_toDeactivatedCounterparty_emitsRejected` | The agent can still pay any whitelisted counterparty, up to its caps. |
| 2 | The agent sends too much to one counterparty, or loops. | Gate 3: daily cap per counterparty and token. A token without a cap for that counterparty cannot go there. | `test_executeTransfer_exceedsDailyCap_emitsRejected`, `test_executeTransfer_afterDayReset_capRefreshes`, `test_dailyCap_isPerToken` | Fixed UTC day (see L6). No limit on the number of calls. |
| 3 | The agent spreads one large outflow over many counterparties. | Gate 4: daily outflow cap per token, summed over all counterparties. A token without a cap cannot move. | `test_executeTransfer_twoCounterparties_exceedsAssetCap_rejected`, `test_executeTransfer_assetCap_perAssetIsolation`, `test_executeTransfer_noCapSet_rejected` | Each token has its own cap. There is no common limit across tokens, because raw amounts of different tokens do not compare. |
| 4 | A stolen agent key tries to change the policy: allow a token, whitelist itself, raise a cap, unpause, grant itself a role. | Each role on its own account. The agent key holds `AGENT_ROLE` only. | `test_agent_cannotSetAssetConfig`, `test_agent_cannotAddCounterparty`, `test_agent_cannotSetCounterpartyDailyCap`, `test_agent_cannotPause`, `test_agent_cannotGrantRole` | Within its role the key can do everything in rows 1–3 until it is stopped. |
| 5 | The agent misbehaves and must be stopped now. | The pauser pauses: every `executeTransfer` reverts. The admin revokes `AGENT_ROLE` for good. | `test_executeTransfer_whenPaused_reverts`, `test_admin_revokeAgent_blocksExecuteTransfer` | Someone has to notice and act. The agent's rights never expire on their own (see L9). |
| 6 | Other roles call the agent's function. | `executeTransfer` requires `AGENT_ROLE`. | `test_treasurer_cannotExecuteTransfer`, `test_pauser_cannotExecuteTransfer` | None known. |
| 7 | The deployer keeps rights after deployment. | The constructor assigns each role to the address passed in; the deployer gets none by default. | `test_deployer_hasNoRoleAfterDeployment` | None known. |
| 8 | A typo or a stolen admin key moves the admin role in one transaction. | `AccessControlDefaultAdminRules`: two-step handover with a delay, no direct grant. | `test_adminTransfer_needsTwoStepsAndDelay`, `test_admin_cannotGrantAdminRoleDirectly` | The admin is a single EOA here. The delay helps only if someone watches. |
| 9 | The agent pays a recipient that is not eligible under the token's rules (no KYC). | Gate 5: the token rejects; the vault logs the token's error in `detail`. | `test_executeTransfer_recipientNotVerified_emitsRejectedWithUnverifiedIdentity` | Depends on the issuer's identity registry and compliance setup. |
| 10 | A failed token transfer still uses up a daily cap, blocking later valid transfers. | Counters are written only after `token.transfer` returns true. | `test_executeTransfer_erc3643Rejects_dailyCapNotConsumed`, `test_executeTransfer_erc3643Rejects_noTokensMoved` | None known. A foreign token no longer reaches the counters (row 15). |
| 11 | Blocked attempts stay invisible to monitoring. | Every policy rejection emits `TransferRejected` with a typed reason, returns the same values, and the transaction succeeds. A token failure without a reason reverts instead, so the log holds only real decisions. | `test_executeTransfer_erc3643Rejects_emitsRejectedWithReason`, `test_executeTransfer_exceedsDailyCap_emitsRejected`, `test_executeTransfer_outOfGasInToken_neverLogsRejection` | The agent can fill the log with rejections, at its own gas cost. A token that catches its own out-of-gas can still produce a logged rejection (see L12). |
| 12 | The issuer freezes the vault or pauses the token. | Nothing moves. Gate 5 logs the token's error. | `test_executeTransfer_vaultFrozen_emitsRejectedWithFrozenWallet`, `test_executeTransfer_tokenPaused_emitsRejectedWithEnforcedPause` | Accepted: ERC-3643 requires these issuer rights. |
| 13 | The issuer moves tokens out of the vault with a forced transfer. | None in the vault, by design. The test documents the behaviour. | `test_forcedTransfer_movesVaultTokensWithoutVaultEvent`, `test_forcedTransfer_doesNotTouchDailyCounters` | Such outflows bypass the vault's log and caps (see L7). Monitor the token's events too. |
| 14 | A malicious RPC shows the agent or the operator a false pre-check result or balance. | The pre-check (`eth_call`) is an aid, not a control. On submission the vault runs every gate again. | Every gate test above; for example `test_executeTransfer_toUnknownCounterparty_emitsRejected_noRevert` | The RPC can mislead the operator or withhold transactions. It cannot move tokens past the gates. |
| 15 | The agent passes a token the treasury never approved, or a fake contract whose `transfer` returns `true` without moving anything. | Gate 1: the token must be allowed by the treasurer (default-deny). Caps and counters are kept per token. | `test_executeTransfer_unknownToken_emitsAssetNotAllowed`, `test_executeTransfer_foreignToken_doesNotConsumeCaps` | An allowed token is trusted to report its own transfer result. |
| 16 | A token calls back into `executeTransfer` during its own `transfer`, so both calls read the same daily counter and the cap is paid out twice. | `executeTransfer` is `nonReentrant` (`ReentrancyGuardTransient`). The inner call reverts; the token's transfer fails with that error and nothing moves. | `test_executeTransfer_reentrantToken_cannotBypassCaps` | None known. The test gives the token `AGENT_ROLE`, the worst case. |

---

## Known limitations

### Open

Gaps in the current vault. "Planned fix" says how each one is meant to be
closed; "none" means the behaviour is accepted.

| #   | Limitation | Effect | Planned fix |
| --- | ---------- | ------ | ----------- |
| L6  | **Fixed UTC day.** The bucket is `block.timestamp / 1 days`. | Two full daily caps can go out seconds apart around midnight UTC. | None planned. The caps bound outflow per calendar day, not per 24 hours. |
| L7  | **Issuer outflows are not counted.** Forced transfer, recovery and burn act on the vault's balance directly. | They leave no vault event and do not touch the caps. | None: this is an ERC-3643 issuer right (see [Issuer rights](architecture.md#issuer-rights)). |
| L8  | **No exit except `executeTransfer`.** The vault has no rescue or sweep function. | Every outflow needs `AGENT_ROLE`, an allowed token, a whitelisted recipient and room in the caps, also a migration to a new vault (see [ADR-0002](adr/0002-admin-rights-and-no-upgradeability.md)). If the role holders cannot cooperate, only the issuer can move the tokens. | None: deliberate. A sweep function would be a second path around the gates. |
| L9  | **The agent's rights do not expire.** `AGENT_ROLE` holds until revoked. | A forgotten agent key stays usable. | Optional: an expiry for the agent role, like `validUntil` in ERC-8226. |
| L12 | **A token can still turn its own out-of-gas into a reason.** The vault reverts when the token gives no reason. A token that catches an out-of-gas inside its own checks (for example in a compliance module it calls) and reverts with data passes that data on as `ERC3643Compliance`. | The agent can still provoke a logged rejection with a tight gas limit, if the token behaves like this. Nothing moves. | None: the vault cannot tell such data from a real decision. |

### Fixed

L1–L4 were closed by the token allowlist and the caps per token. L5, L10 and
L11 were closed when `executeTransfer` started to return its outcome and got a
re-entrancy guard. The numbers stay, so older references still match.

| #   | Former limitation | Fix | Tests |
| --- | ----------------- | --- | ----- |
| L1  | **A foreign token consumed caps.** There was no token allowlist. Any contract whose `transfer` returned `true` passed the token gate and used up a counterparty's daily cap. | Gate 1: the token must be allowed by the treasurer (default-deny). Counters are also kept per token. | `test_executeTransfer_unknownToken_emitsAssetNotAllowed`, `test_executeTransfer_foreignToken_doesNotConsumeCaps` |
| L2  | **One daily cap across all tokens.** `_dailySpent[to][day]` added raw amounts of every token, so tokens with different decimals were compared as if they were one unit. | Cap and counter per counterparty and token, set with `setCounterpartyDailyCap(cp, token, cap)`. | `test_dailyCap_isPerToken`, `test_executeTransfer_noCounterpartyCapForToken_rejected` |
| L3  | **The per-asset cap failed open.** `cap == 0` meant unlimited, while the whitelist was default-deny. | Default-deny everywhere: a cap that was never set is 0 and blocks the transfer. Unlimited is the explicit value `type(uint256).max`. | `test_executeTransfer_noCapSet_rejected`, `test_executeTransfer_unlimitedAssetCap_allowsLargeTransfer` |
| L4  | **Overflow on huge amounts.** `spent + amount` could overflow after an earlier transfer on the same day. The call reverted with `Panic(0x11)` instead of logging the rejection. | Overflow-safe comparison `spent > cap \|\| amount > cap - spent`. It also rejects cleanly when a cap is lowered below what was already spent today. | `test_executeTransfer_hugeAmount_rejectedWithoutPanic`, `test_executeTransfer_hugeAmount_assetCap_rejectedWithoutPanic`, `test_setCounterpartyDailyCap_loweredBelowSpent_rejectsWithoutPanic`, `test_setAssetConfig_capLoweredBelowSpent_rejectsWithoutPanic` |
| L5  | **Out-of-gas looked like a compliance rejection.** If `token.transfer` ran out of gas, the `catch` branch emitted `ERC3643Compliance` with empty `detail`: the vault keeps 1/64 of its gas for after the call (EIP-150), enough for the event. The agent could fake a rejection by choosing the gas limit. | No reason, no log: a revert without data or a `false` return makes the vault revert with `TokenTransferFailedWithoutReason`. | `test_executeTransfer_outOfGasInToken_neverLogsRejection`, `test_executeTransfer_tokenRevertsWithoutReason_reverts`, `test_executeTransfer_tokenReturnsFalse_reverts` |
| L10 | **Re-entrancy was excluded by roles, not by a guard.** The counters are written after the external `token.transfer` call, on purpose. A token that held `AGENT_ROLE` could re-enter and pay out a cap twice. | `executeTransfer` is `nonReentrant` (`ReentrancyGuardTransient`). The counters still change only on success. | `test_executeTransfer_reentrantToken_cannotBypassCaps` |
| L11 | **A transfer of 0 passed every gate** and emitted `TransferExecuted` for nothing. | An amount of 0 reverts with `ZeroAmount` before any gate runs. | `test_executeTransfer_zeroAmount_reverts` |
