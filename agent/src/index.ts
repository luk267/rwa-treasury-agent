import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { config as loadEnv } from "dotenv";
import { createClients, loadDeployment, ConfigError } from "./config.js";
import { AgentLoopError, runAgent } from "./loop.js";
import { buildSystemPrompt } from "./prompt.js";
import { createGetPortfolioTool } from "./tools/get-portfolio.js";
import { createCheckTransferTool } from "./tools/check-transfer.js";
import { createExecuteTransferTool } from "./tools/execute-transfer.js";

const EXIT_OK = 0;
const EXIT_INPUT = 1; // bad input or local configuration
const EXIT_SERVICE = 2; // Anthropic API or RPC failure

const DEFAULT_MODEL = "claude-opus-5-5";

/** The chain RPC is unreachable. */
class RpcUnavailableError extends Error {
  override name = "RpcUnavailableError";
}

loadEnv({ quiet: true });

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  const autoApprove = args.includes("--yes") || process.env.AGENT_AUTO_APPROVE === "1";
  const userPrompt = args
    .filter((arg) => arg !== "--yes")
    .join(" ")
    .trim();
  if (!userPrompt) {
    console.error('Usage: npm start -- [--yes] "your instruction"');
    return EXIT_INPUT;
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    throw new ConfigError("ANTHROPIC_API_KEY is not set. Add it to agent/.env.");
  }

  const here = dirname(fileURLToPath(import.meta.url));
  const deployment = loadDeployment(resolve(here, "../../deployments/local.json"));
  const { publicClient, walletClient, account } = createClients(deployment);

  // Fail before spending API credits if the local chain is not running.
  try {
    await publicClient.getChainId();
  } catch {
    throw new RpcUnavailableError(
      `Cannot reach the RPC at ${deployment.rpcUrl}. Is ./scripts/local-dev.sh running?`,
    );
  }

  const { turns } = await runAgent({
    client: new Anthropic(),
    model: process.env.AGENT_MODEL || DEFAULT_MODEL,
    system: buildSystemPrompt(deployment),
    userPrompt,
    tools: [
      createGetPortfolioTool(deployment, publicClient),
      createCheckTransferTool(deployment, publicClient, account),
      createExecuteTransferTool(deployment, publicClient, walletClient),
    ],
    approve: autoApprove ? async () => true : askOperator,
    log: (line) => console.log(line),
  });

  console.log(`\n--- done (turns: ${turns}) ---`);
  return EXIT_OK;
}

/** Terminal confirmation before a real transfer. Convenience, not a security boundary. */
async function askOperator(): Promise<boolean> {
  if (!process.stdin.isTTY) {
    console.error("No terminal to confirm the transfer: declined. Pass --yes to approve.");
    return false;
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = await rl.question("Proceed? [y/N] ");
    return /^y(es)?$/i.test(answer.trim());
  } finally {
    rl.close();
  }
}

/** Print one line to stderr and pick the exit code. No stack traces. */
function report(err: unknown): number {
  if (err instanceof ConfigError) {
    console.error(`Configuration error: ${err.message}`);
    return EXIT_INPUT;
  }
  if (err instanceof Anthropic.AuthenticationError) {
    console.error("Anthropic API rejected the API key (401). Check ANTHROPIC_API_KEY in agent/.env.");
    return EXIT_SERVICE;
  }
  if (err instanceof Anthropic.NotFoundError) {
    console.error(`Anthropic API: not found (404). Check AGENT_MODEL. ${err.message}`);
    return EXIT_SERVICE;
  }
  if (err instanceof Anthropic.RateLimitError) {
    console.error("Anthropic API: rate limit reached (429). Try again later.");
    return EXIT_SERVICE;
  }
  if (err instanceof Anthropic.APIConnectionError) {
    console.error(`Cannot reach the Anthropic API: ${err.message}`);
    return EXIT_SERVICE;
  }
  if (err instanceof Anthropic.APIError) {
    console.error(`Anthropic API error ${err.status ?? ""}: ${err.message}`);
    return EXIT_SERVICE;
  }
  if (err instanceof RpcUnavailableError || err instanceof AgentLoopError) {
    console.error(err.message);
    return EXIT_SERVICE;
  }
  console.error(`Unexpected error: ${err instanceof Error ? err.message : String(err)}`);
  return EXIT_SERVICE;
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    process.exitCode = report(err);
  },
);
