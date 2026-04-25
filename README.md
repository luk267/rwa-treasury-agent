# rwa-treasury-agent

## What this is

A compliant Real-World-Asset (RWA) treasury agent built for [ETHGlobal Open Agents](https://ethglobal.com/events/openagents) (April–May 2026). A Solidity Treasury Vault holds tokenized RWAs (ERC-3643) and enforces local policy guardrails before delegating to the Tokeny T-REX compliance layer. A TypeScript agent (Claude Agent SDK + viem) orchestrates transfers and explains its reasoning.

## Status

`pre-MVP, in active development for ETHGlobal Open Agents`

## Architecture

The Treasury Vault holds ERC-3643 tokens and enforces four policies — pause, per-asset exposure cap, whitelisted counterparties, daily cap — before forwarding any transfer to the Tokeny T-REX compliance layer. A TypeScript agent simulates each transaction off-chain (`simulateContract`) before submitting it on-chain (`writeContract`), giving structured, human-readable reasoning for every decision.

See [`docs/architecture.md`](docs/architecture.md) for details.

## Quick start

Prerequisites: [Foundry](https://book.getfoundry.sh) and Node 20+.

```bash
git submodule update --init --recursive
(cd contracts && forge build)
(cd agent && npm install && npm run typecheck)
```

See [`contracts/`](contracts/) and [`agent/`](agent/) for details.

## License

MIT — see [`LICENSE`](LICENSE).
