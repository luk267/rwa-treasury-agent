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
import { z } from "zod";

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

const address = z.custom<`0x${string}`>(
  (value) => typeof value === "string" && isAddress(value),
  "expected a 0x-prefixed 20-byte address",
);

const tokenSchema = z.object({
  address,
  symbol: z.string().min(1),
  decimals: z.number().int().min(0).max(255),
});

/** Name and address only. Status and caps are read from the vault at run time. */
const counterpartySchema = z.object({
  address,
  name: z.string().min(1),
});

const rolesSchema = z.object({
  admin: address,
  treasurer: address,
  pauser: address,
  agent: address,
});

/** Shape of deployments/local.json, as written by scripts/local-dev.sh. */
const deploymentSchema = z.object({
  chainId: z.number().int(),
  rpcUrl: z.string().min(1),
  vault: address,
  roles: rolesSchema,
  tokens: z.array(tokenSchema),
  counterparties: z.array(counterpartySchema),
  vaultFunding: z.string(),
});

export type Token = z.infer<typeof tokenSchema>;
export type Counterparty = z.infer<typeof counterpartySchema>;
export type Roles = z.infer<typeof rolesSchema>;
export type Deployment = z.infer<typeof deploymentSchema>;

/** Read and validate deployments/local.json. Any problem is a ConfigError (exit code 1). */
export function loadDeployment(path?: string): Deployment {
  const file = path ?? resolve(process.cwd(), "deployments/local.json");
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    throw new ConfigError(`Cannot read ${file}. Start the local stack with ./scripts/local-dev.sh.`);
  }
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new ConfigError(`${file} is not valid JSON. Re-run ./scripts/local-dev.sh.`);
  }
  const result = deploymentSchema.safeParse(json);
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("; ");
    throw new ConfigError(`${file} is invalid (${issues}). Re-run ./scripts/local-dev.sh.`);
  }
  return result.data;
}

export function createClients(deployment: Deployment) {
  const account = privateKeyToAccount(ANVIL_ACCOUNT_5);
  if (!isAddressEqual(account.address, deployment.roles.agent)) {
    throw new ConfigError(
      `Agent key ${account.address} is not the agent in deployments/local.json ` +
        `(roles.agent = ${deployment.roles.agent}). Re-run ./scripts/local-dev.sh.`,
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

/**
 * Parse a human-readable amount such as "500" or "0.5" into base units.
 * An amount finer than the token's decimals is refused, not rounded.
 */
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
  // parseUnits rounds away digits beyond token.decimals. Trailing zeros there are exact.
  const beyondPrecision = (amount.split(".")[1] ?? "").slice(token.decimals);
  if (/[1-9]/.test(beyondPrecision)) {
    throw new ToolInputError(
      "InvalidAmount",
      `"${amount}" is finer than ${token.decimals} decimal places, the precision of ${token.symbol}.`,
    );
  }
  return value;
}
