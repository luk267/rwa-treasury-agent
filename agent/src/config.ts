import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

// Anvil default mnemonic - Account #0. Same key the deploy script broadcasts with.
// Local-dev only; for Sepolia/Mainnet this would come from process.env.
const ANVIL_ACCOUNT_0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

export interface Token {
  address: `0x${string}`;
  symbol: string;
  decimals: number;
}

export interface Counterparty {
  address: `0x${string}`;
  name: string;
  dailyCap: string;
}

export interface ExposureCap {
  token: `0x${string}`;
  cap: string;
}

export interface Deployment {
  chainId: number;
  rpcUrl: string;
  vault: `0x${string}`;
  tokens: Token[];
  counterparties: Counterparty[];
  exposureCaps: ExposureCap[];
  vaultFunding: string;
}

export function loadDeployment(path?: string): Deployment {
  const file = path ?? resolve(process.cwd(), "deployments/local.json");
  const raw = readFileSync(file, "utf8");
  return JSON.parse(raw) as Deployment;
}

export function createClients(deployment: Deployment) {
  const account = privateKeyToAccount(ANVIL_ACCOUNT_0);
  const transport = http(deployment.rpcUrl);

  const publicClient = createPublicClient({
    chain: foundry,
    transport,
  });

  const walletClient = createWalletClient({
    account,
    chain: foundry,
    transport,
  });

  return { publicClient, walletClient, account };
}

export function resolveCounterparty(
  deployment: Deployment,
  identifier: string,
): `0x${string}` {
  const lower = identifier.toLowerCase();
  const byName = deployment.counterparties.find((cp) => cp.name.toLowerCase() === lower);
  if (byName) return byName.address;
  if (identifier.startsWith("0x") && identifier.length === 42) {
    return identifier as `0x${string}`;
  }
  throw new Error(
    `Unknown counterparty "${identifier}". Available: ${deployment.counterparties.map((cp) => cp.name).join(", ")}`,
  );
}

export function findToken(deployment: Deployment, identifier: string): Token {
  const lower = identifier.toLowerCase();
  const bySymbol = deployment.tokens.find((t) => t.symbol.toLowerCase() === lower);
  if (bySymbol) return bySymbol;
  const byAddress = deployment.tokens.find((t) => t.address.toLowerCase() === lower);
  if (byAddress) return byAddress;
  throw new Error(
    `Unknown token "${identifier}". Available: ${deployment.tokens.map((t) => t.symbol).join(", ")}`,
  );
}
