# Threat model

This document lists what the system protects, who can act on it, what it
assumes, and which threats it handles. Each mitigation names the test that
shows it. Gaps that are known but not yet fixed are listed at the end, so a
reviewer does not have to find them.

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
- The vault's policy: whitelist, daily caps, exposure caps, pause flag.
- The role assignment: who holds `DEFAULT_ADMIN_ROLE`, `TREASURER_ROLE`,
  `AGENT_ROLE` and `PAUSER_ROLE`.
- The audit trail: `TransferExecuted` and `TransferRejected` events.

## Actors

| Actor                     | Can do                                                                                 | Trusted? |
| ------------------------- | -------------------------------------------------------------------------------------- | -------- |
| AI agent                  | Call `executeTransfer` with any token, recipient and amount. Read chain state via RPC. | No. Assume its key and its model can be misused (prompt injection, bugs, key theft). |
| Admin                     | Grant and revoke roles. Hand over the admin role in two steps with a delay.            | Yes      |
| Treasurer                 | Add and deactivate counterparties, set daily caps and exposure caps.                   | Yes      |
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
| 1 | A prompt injection or a bug makes the agent pay an attacker's address. | Gate 1: the recipient must be an active counterparty. | `test_executeTransfer_toUnknownCounterparty_emitsRejected_noRevert`, `test_executeTransfer_toDeactivatedCounterparty_emitsRejected` | The agent can still pay any whitelisted counterparty, up to its caps. |
| 2 | The agent sends too much to one counterparty, or loops. | Gate 2: daily cap per counterparty. | `test_executeTransfer_exceedsDailyCap_emitsRejected`, `test_executeTransfer_afterDayReset_capRefreshes` | Fixed UTC day (see L6). No limit on the number of calls. |
| 3 | The agent spreads one large outflow over many counterparties. | Gate 3: daily exposure cap per asset, summed over all counterparties. | `test_executeTransfer_twoCounterparties_exceedsExposureCap_rejected`, `test_executeTransfer_exposureCap_perAssetIsolation` | A token without a cap has no limit (see L3). |
| 4 | A stolen agent key tries to change the policy: whitelist itself, raise a cap, unpause, grant itself a role. | Each role on its own account. The agent key holds `AGENT_ROLE` only. | `test_agent_cannotAddCounterparty`, `test_agent_cannotSetExposureCap`, `test_agent_cannotPause`, `test_agent_cannotGrantRole` | Within its role the key can do everything in rows 1–3 until it is stopped. |
| 5 | The agent misbehaves and must be stopped now. | The pauser pauses: every `executeTransfer` reverts. The admin revokes `AGENT_ROLE` for good. | `test_executeTransfer_whenPaused_reverts`, `test_admin_revokeAgent_blocksExecuteTransfer` | Someone has to notice and act. The agent's rights never expire on their own (see L9). |
| 6 | Other roles call the agent's function. | `executeTransfer` requires `AGENT_ROLE`. | `test_treasurer_cannotExecuteTransfer`, `test_pauser_cannotExecuteTransfer` | None known. |
| 7 | The deployer keeps rights after deployment. | The constructor assigns each role to the address passed in; the deployer gets none by default. | `test_deployer_hasNoRoleAfterDeployment` | None known. |
| 8 | A typo or a stolen admin key moves the admin role in one transaction. | `AccessControlDefaultAdminRules`: two-step handover with a delay, no direct grant. | `test_adminTransfer_needsTwoStepsAndDelay`, `test_admin_cannotGrantAdminRoleDirectly` | The admin is a single EOA here. The delay helps only if someone watches. |
| 9 | The agent pays a recipient that is not eligible under the token's rules (no KYC). | Gate 4: the token rejects; the vault logs the token's error in `detail`. | `test_executeTransfer_recipientNotVerified_emitsRejectedWithUnverifiedIdentity` | Depends on the issuer's identity registry and compliance setup. |
| 10 | A failed token transfer still uses up a daily cap, blocking later valid transfers. | Counters are written only after `token.transfer` returns true. | `test_executeTransfer_erc3643Rejects_dailyCapNotConsumed`, `test_executeTransfer_erc3643Rejects_noTokensMoved` | A foreign token can still consume caps (see L1). |
| 11 | Blocked attempts stay invisible to monitoring. | Every policy rejection emits `TransferRejected` with a typed reason and the transaction succeeds. | `test_executeTransfer_erc3643Rejects_emitsRejectedWithReason`, `test_executeTransfer_exceedsDailyCap_emitsRejected` | The agent can fill the log with rejections, at its own gas cost. An out-of-gas can be logged as a compliance rejection (see L5). |
| 12 | The issuer freezes the vault or pauses the token. | Nothing moves. Gate 4 logs the token's error. | `test_executeTransfer_vaultFrozen_emitsRejectedWithFrozenWallet`, `test_executeTransfer_tokenPaused_emitsRejectedWithEnforcedPause` | Accepted: ERC-3643 requires these issuer rights. |
| 13 | The issuer moves tokens out of the vault with a forced transfer. | None in the vault, by design. The test documents the behaviour. | `test_forcedTransfer_movesVaultTokensWithoutVaultEvent`, `test_forcedTransfer_doesNotTouchDailyCounters` | Such outflows bypass the vault's log and caps (see L7). Monitor the token's events too. |
| 14 | A malicious RPC shows the agent or the operator a false simulation or balance. | The simulation is an aid, not a control. On submission the vault runs every gate again. | Every gate test above; for example `test_executeTransfer_toUnknownCounterparty_emitsRejected_noRevert` | The RPC can mislead the operator or withhold transactions. It cannot move tokens past the gates. |

---

## Known limitations

Gaps in the current vault. "Planned fix" says how each one is meant to be
closed; "none" means the behaviour is accepted.

| #   | Limitation | Effect | Planned fix |
| --- | ---------- | ------ | ----------- |
| L1  | **A foreign token consumes caps.** There is no token allowlist. Any contract whose `transfer` returns `true` passes gate 4. | The agent can pass a fake token and use up a counterparty's daily cap. No real tokens move. | Token allowlist (default-deny). |
| L2  | **One daily cap across all tokens.** `_dailySpent[to][day]` adds raw amounts of every token. | With several tokens of different decimals the cap compares numbers that do not compare. | Caps per counterparty and token. |
| L3  | **The exposure cap fails open.** `cap == 0` means unlimited. | A token without a cap has no per-asset limit. The whitelist, by contrast, is default-deny. | Default-deny: no cap set means no transfer; unlimited only as an explicit maximum. |
| L4  | **Overflow on huge amounts.** `spent + amount` can overflow after an earlier transfer on the same day. | The call reverts with `Panic(0x11)` instead of emitting `DailyCapExceeded`. Nothing moves, but the rejection is not logged. The same holds for the exposure cap. | Overflow-safe comparison. |
| L5  | **Out-of-gas can look like a compliance rejection.** If `token.transfer` runs out of gas, the `catch` branch emits `ERC3643Compliance` with empty `detail`. | The agent can provoke a false rejection by choosing the gas limit. Only possible when the token's `transfer` needs a lot of gas; not with the mock. Nothing moves. | Revert when the token gives no reason. |
| L6  | **Fixed UTC day.** The bucket is `block.timestamp / 1 days`. | Two full daily caps can go out seconds apart around midnight UTC. | None planned. The caps bound outflow per calendar day, not per 24 hours. |
| L7  | **Issuer outflows are not counted.** Forced transfer, recovery and burn act on the vault's balance directly. | They leave no vault event and do not touch the caps. | None: this is an ERC-3643 issuer right (see [Issuer rights](architecture.md#issuer-rights)). |
| L8  | **No exit except `executeTransfer`.** The vault has no rescue or sweep function. | Every outflow needs `AGENT_ROLE`, a whitelisted recipient and room in the caps, also a migration to a new vault (see [ADR-0002](adr/0002-admin-rights-and-no-upgradeability.md)). If the role holders cannot cooperate, only the issuer can move the tokens. | None: deliberate. A sweep function would be a second path around the gates. |
| L9  | **The agent's rights do not expire.** `AGENT_ROLE` holds until revoked. | A forgotten agent key stays usable. | Optional: an expiry for the agent role, like `validUntil` in ERC-8226. |
| L10 | **Re-entrancy is excluded by roles, not by a guard.** The counters are written after the external `token.transfer` call, on purpose. | Safe today, because re-entering needs `AGENT_ROLE`. A token that ever held that role could break the caps. | A re-entrancy guard. |
| L11 | **A transfer of 0 passes every gate.** | Emits `TransferExecuted` for nothing. Harmless but noisy. | Revert on a zero amount. |
