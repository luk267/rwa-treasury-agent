import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  isAddressEqual,
  isHex,
  parseUnits,
  type Chain,
  type PrivateKeyAccount,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, sepolia } from "viem/chains";
import { z } from "zod";

// Anvil default mnemonic - Account #5. DeployLocal grants it AGENT_ROLE and nothing else.
// Used only when AGENT_NETWORK is local. On Sepolia the key comes from AGENT_PRIVATE_KEY.
const ANVIL_ACCOUNT_5 = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba" as const;

/** Missing or inconsistent setup. The agent exits with code 1. */
export class ConfigError extends Error {
  override name = "ConfigError";
}

/** Networks the agent runs on. `local` is the Anvil stack from scripts/local-dev.sh. */
export const NETWORKS = ["local", "sepolia"] as const;
export type Network = (typeof NETWORKS)[number];

/** Environment variables as the agent reads them. `process.env` fits. */
export type Env = Readonly<Record<string, string | undefined>>;

const CHAINS: Record<Network, Chain> = { local: foundry, sepolia };

/** What to do when deployments/<network>.json is missing or broken. */
const DEPLOYMENT_HINT: Record<Network, string> = {
  local: "Start the local stack with ./scripts/local-dev.sh.",
  sepolia: "The file is committed; restore it with git.",
};

/** Read AGENT_NETWORK. Unset or empty means local. */
export function resolveNetwork(value: string | undefined): Network {
  if (value === undefined || value === "") return "local";
  const network = NETWORKS.find((n) => n === value);
  if (network) return network;
  throw new ConfigError(`AGENT_NETWORK must be one of ${NETWORKS.join(", ")}, got "${value}".`);
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

/**
 * Shape of deployments/<network>.json. scripts/local-dev.sh writes local.json;
 * sepolia.json is committed.
 */
const deploymentSchema = z.object({
  chainId: z.number().int(),
  /** Local only. On Sepolia the URL comes from RPC_URL_SEPOLIA: it usually carries a provider key. */
  rpcUrl: z.string().min(1).optional(),
  /** Block of the first deployment transaction, on public networks. */
  deployBlock: z.number().int().nonnegative().optional(),
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

/**
 * Read and validate deployments/<network>.json. Any problem is a ConfigError (exit code 1).
 * `network` only picks the default path and the hint in the error message.
 */
export function loadDeployment(path?: string, network: Network = "local"): Deployment {
  const file = path ?? resolve(process.cwd(), `deployments/${network}.json`);
  const hint = DEPLOYMENT_HINT[network];
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    throw new ConfigError(`Cannot read ${file}. ${hint}`);
  }
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new ConfigError(`${file} is not valid JSON. ${hint}`);
  }
  const result = deploymentSchema.safeParse(json);
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("; ");
    throw new ConfigError(`${file} is invalid (${issues}). ${hint}`);
  }
  return result.data;
}

/** RPC URL and signing key for `network`. Error messages never contain either value. */
function networkAccess(
  deployment: Deployment,
  network: Network,
  env: Env,
): { rpcUrl: string; key: `0x${string}`; keyHint: string } {
  if (network === "local") {
    if (!deployment.rpcUrl) {
      throw new ConfigError(`deployments/local.json has no rpcUrl. ${DEPLOYMENT_HINT.local}`);
    }
    return { rpcUrl: deployment.rpcUrl, key: ANVIL_ACCOUNT_5, keyHint: "Re-run ./scripts/local-dev.sh." };
  }
  const rpcUrl = env.RPC_URL_SEPOLIA;
  if (!rpcUrl) throw new ConfigError("RPC_URL_SEPOLIA is not set. Add it to agent/.env.");
  const raw = env.AGENT_PRIVATE_KEY;
  if (!raw) throw new ConfigError("AGENT_PRIVATE_KEY is not set. Add it to agent/.env.");
  const key = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(key, { strict: true }) || key.length !== 66) {
    throw new ConfigError("AGENT_PRIVATE_KEY must be 32 bytes as hex: 64 characters, 0x optional.");
  }
  return { rpcUrl, key, keyHint: "Set AGENT_PRIVATE_KEY to the key that holds AGENT_ROLE." };
}

/**
 * Viem clients for `network`. Local signs with Anvil account #5 and ignores the
 * environment. Sepolia reads RPC_URL_SEPOLIA and AGENT_PRIVATE_KEY from `env`.
 * The key must belong to roles.agent, and the file must be for the network's chain.
 */
export function createClients(deployment: Deployment, network: Network = "local", env: Env = process.env) {
  const chain = CHAINS[network];
  if (deployment.chainId !== chain.id) {
    throw new ConfigError(
      `deployments/${network}.json is for chain ${deployment.chainId}, ` +
        `but AGENT_NETWORK=${network} means chain ${chain.id}.`,
    );
  }
  const { rpcUrl, key, keyHint } = networkAccess(deployment, network, env);
  let account: PrivateKeyAccount;
  try {
    account = privateKeyToAccount(key);
  } catch {
    throw new ConfigError("AGENT_PRIVATE_KEY is not a valid secp256k1 private key.");
  }
  if (!isAddressEqual(account.address, deployment.roles.agent)) {
    throw new ConfigError(
      `Agent key ${account.address} is not the agent in deployments/${network}.json ` +
        `(roles.agent = ${deployment.roles.agent}). ${keyHint}`,
    );
  }
  const transport = http(rpcUrl);

  const publicClient = createPublicClient({
    chain,
    transport,
  });

  const walletClient = createWalletClient({
    account,
    chain,
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
