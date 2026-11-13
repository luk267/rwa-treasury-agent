# ADR-0002: Separate roles, a guarded admin, and no upgrade mechanism

- **Status:** Accepted
- **Date:** 2026-11-13

## Context

The vault holds regulated assets for a treasury and lets an untrusted AI
agent move them within limits. Someone has to set those limits, stop the
agent in an emergency, and manage who holds which right. Every one of these
powers is also an attack path if a single key holds them all. The vault
also has to be fixable if a bug is found.

## Decision

**Four roles, one account each.** The constructor takes one address per role
and grants nothing to the deployer:

| Role                 | Powers                                                    |
| -------------------- | --------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE` | Grant and revoke the other roles.                         |
| `TREASURER_ROLE`     | Token allowlist, whitelist, daily caps.                   |
| `PAUSER_ROLE`        | Pause and unpause.                                        |
| `AGENT_ROLE`         | `executeTransfer`, nothing else.                          |

**A guarded admin.** The admin role uses OpenZeppelin's
`AccessControlDefaultAdminRules`: exactly one admin, no direct
`grantRole(DEFAULT_ADMIN_ROLE, …)`, and a two-step handover
(`beginDefaultAdminTransfer`, then `acceptDefaultAdminTransfer` after a
delay). The local stack uses a one-day delay.

**For production** (not part of this repo): the admin and the treasurer are
multisigs, and admin and treasurer changes go through a timelock, so a
compromised signer set cannot change the policy without warning. The pauser
stays fast to act, because pausing can only stop transfers, never move tokens.

**No upgrade mechanism.** The vault is a plain contract, not a proxy. To fix
a bug, deploy a new vault and migrate:

1. Deploy the new vault with its roles.
2. The issuer registers the new vault in the token's identity registry.
3. In the old vault, the treasurer whitelists the new vault and gives it a
   daily cap per token (and a token cap) that covers the balance.
4. The `AGENT_ROLE` holder moves the balance with `executeTransfer`.
5. The admin revokes all roles in the old vault.

## Consequences

- No single key can both change the policy and use it. A stolen agent key
  cannot whitelist, raise a cap, unpause or grant a role.
- The code that reviewers read is the code that runs. There is no proxy
  admin that could swap the gates, and no storage-layout risk.
- A bug fix costs a migration, and the migration itself passes the gates.
  Large balances may need a raised cap or several days.
- The vault's address changes on migration. The issuer, monitoring and the
  agent configuration must follow it.
- The admin is still a single EOA locally. The delay only helps if someone
  watches for `DefaultAdminTransferScheduled`.

## Rejected alternatives

- **`Ownable` with one owner.** One key for everything, which is the problem
  this design avoids.
- **A UUPS or transparent proxy.** Allows fixes in place, but the upgrade key
  could replace the gates in one transaction. It adds a second, stronger
  admin to protect.
- **An admin sweep or rescue function.** Would make migration easy, but would
  also be a second path out of the vault that skips the gates. See L8 in the
  [threat model](../threat-model.md#known-limitations).
