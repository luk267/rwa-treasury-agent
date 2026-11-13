import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  isAddressEqual,
  parseUnits,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

// Anvil default mnemonic - Account #5. DeployLocal grants it AGENT_ROLE and nothing else.
// Local-dev only; for Sepolia/Mainnet this would come from process.env.
const ANVIL_ACCOUNT_5 = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba" as const;

/** Missing or inconsistent local setup. The agent exits with code 1. */
export class ConfigError extends Error {
  override name = "ConfigError";
}

export type ToolInputErrorCode = "UnknownToken" | "UnknownCounterparty" | "InvalidAmount";

/** A tool argument the agent cannot resolve. Returned to the model as `reason`. */
export class ToolInputError extends Error {
  override name = "ToolInputError";
  constructor(
    readonly code: ToolInputErrorCode,
    message: string,
  ) {
    super(message);
  }
}

export interface Token {
  address: `0x${string}`;
  symbol: string;
  decimals: number;
}

/** Name and address only. Status and caps are read from the vault at run time. */
export interface Counterparty {
  address: `0x${string}`;
  name: string;
}

export interface Roles {
  admin: `0x${string}`;
  treasurer: `0x${string}`;
  pauser: `0x${string}`;
  agent: `0x${string}`;
}

export interface Deployment {
  chainId: number;
  rpcUrl: string;
  vault: `0x${string}`;
  roles: Roles;
  tokens: Token[];
  counterparties: Counterparty[];
  vaultFunding: string;
}

export function loadDeployment(path?: string): Deployment {
  const file = path ?? resolve(process.cwd(), "deployments/local.json");
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    throw new ConfigError(`Cannot read ${file}. Start the local stack with ./scripts/local-dev.sh.`);
  }
  return JSON.parse(raw) as Deployment;
}

export function createClients(deployment: Deployment) {
  const account = privateKeyToAccount(ANVIL_ACCOUNT_5);
  if (!deployment.roles || !isAddressEqual(account.address, deployment.roles.agent)) {
    throw new ConfigError(
      `Agent key ${account.address} is not the agent in deployments/local.json ` +
        `(roles.agent = ${deployment.roles?.agent ?? "missing"}). Re-run ./scripts/local-dev.sh.`,
    );
  }
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
  if (isAddress(identifier)) return identifier;
  throw new ToolInputError(
    "UnknownCounterparty",
    `Unknown counterparty "${identifier}". Available: ${deployment.counterparties.map((cp) => cp.name).join(", ")}`,
  );
}

export function findToken(deployment: Deployment, identifier: string): Token {
  const lower = identifier.toLowerCase();
  const bySymbol = deployment.tokens.find((t) => t.symbol.toLowerCase() === lower);
  if (bySymbol) return bySymbol;
  const byAddress = deployment.tokens.find((t) => t.address.toLowerCase() === lower);
  if (byAddress) return byAddress;
  throw new ToolInputError(
    "UnknownToken",
    `Unknown token "${identifier}". Available: ${deployment.tokens.map((t) => t.symbol).join(", ")}`,
  );
}

/** Parse a human-readable amount such as "500" or "0.5" into base units. */
export function parseAmount(amount: string, token: Token): bigint {
  let value: bigint;
  try {
    if (amount.trim() === "") throw new Error("empty");
    value = parseUnits(amount, token.decimals);
  } catch {
    throw new ToolInputError("InvalidAmount", `"${amount}" is not a decimal number.`);
  }
  if (value < 0n) {
    throw new ToolInputError("InvalidAmount", `Amount must not be negative, got "${amount}".`);
  }
  return value;
}
