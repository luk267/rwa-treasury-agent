import { createInterface } from "node:readline/promises";
import type { PublicClient } from "viem";
import { ConfigError, type Deployment, type Network } from "./config.js";

/** The chain RPC is unreachable. */
export class RpcUnavailableError extends Error {
  override name = "RpcUnavailableError";
}

/**
 * Fail before spending API credits if the chain is unreachable or not the one the
 * deployment file is for. The Sepolia URL is not printed: it usually carries a provider key.
 */
export async function checkChain(
  publicClient: Pick<PublicClient, "getChainId">,
  deployment: Deployment,
  network: Network,
): Promise<void> {
  let chainId: number;
  try {
    chainId = await publicClient.getChainId();
  } catch {
    throw new RpcUnavailableError(
      network === "local"
        ? `Cannot reach the RPC at ${deployment.rpcUrl}. Is ./scripts/local-dev.sh running?`
        : "Cannot reach the RPC in RPC_URL_SEPOLIA.",
    );
  }
  if (chainId !== deployment.chainId) {
    throw new ConfigError(
      `The RPC serves chain ${chainId}, but deployments/${network}.json is for chain ${deployment.chainId}.`,
    );
  }
}

/** Where the operator answers. Tests pass a fake one. */
export interface OperatorTerminal {
  /** False when stdin is a pipe or file: nobody can answer. */
  isTTY: boolean;
  question(prompt: string): Promise<string>;
  warn(line: string): void;
}

/** The process's own terminal. Opens readline only when asked. */
export const processTerminal: OperatorTerminal = {
  get isTTY() {
    return process.stdin.isTTY === true;
  },
  async question(prompt) {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    try {
      return await rl.question(prompt);
    } finally {
      rl.close();
    }
  },
  warn: (line) => console.error(line),
};

/** Terminal confirmation before a real transfer. Convenience, not a security boundary. */
export async function askOperator(terminal: OperatorTerminal = processTerminal): Promise<boolean> {
  if (!terminal.isTTY) {
    terminal.warn("No terminal to confirm the transfer: declined. Pass --yes to approve.");
    return false;
  }
  const answer = await terminal.question("Proceed? [y/N] ");
  return /^y(es)?$/i.test(answer.trim());
}
