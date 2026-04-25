# agent

TypeScript orchestrator for the [rwa-treasury-agent](../README.md). Simulates and executes compliant transfers via the Treasury Vault contract.

## Stack

- [viem](https://viem.sh) — Ethereum client
- [@anthropic-ai/claude-agent-sdk](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) — agent loop
- `dotenv` for env loading
- `tsx` for running TypeScript directly

## Quick start

```bash
npm install
cp ../.env.example .env      # fill in your keys
npm start                    # runs src/index.ts via tsx
```

## Typecheck

```bash
npm run typecheck   # tsc --noEmit
```
