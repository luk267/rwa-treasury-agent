import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { query, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { createClients, loadDeployment } from "./config.js";
import { buildSystemPrompt } from "./prompt.js";
import { createGetPortfolioTool } from "./tools/get-portfolio.js";
import { createCheckTransferTool } from "./tools/check-transfer.js";
import { createExecuteTransferTool } from "./tools/execute-transfer.js";

loadEnv();

const userPrompt = process.argv.slice(2).join(" ").trim();
if (!userPrompt) {
  console.error('Usage: tsx src/index.ts "your instruction"');
  process.exit(1);
}

const here = dirname(fileURLToPath(import.meta.url));
const deployment = loadDeployment(
  resolve(here, "../../deployments/local.json"),
);
const { publicClient, walletClient, account } = createClients(deployment);

const vault = createSdkMcpServer({
  name: "vault",
  version: "0.1.0",
  tools: [
    createGetPortfolioTool(deployment, publicClient),
    createCheckTransferTool(deployment, publicClient, account),
    createExecuteTransferTool(deployment, publicClient, walletClient),
  ],
});

const q = query({
  prompt: userPrompt,
  options: {
    systemPrompt: buildSystemPrompt(deployment),
    mcpServers: { vault },
    tools: [],
    allowedTools: [
      "mcp__vault__get_portfolio",
      "mcp__vault__check_transfer_feasibility",
      "mcp__vault__execute_transfer",
    ],
    model: "claude-sonnet-4-6",
    permissionMode: "bypassPermissions",
    settingSources: [],
  },
});

for await (const msg of q) {
  if (msg.type === "assistant") {
    for (const block of msg.message.content) {
      if (block.type === "text") {
        console.log(block.text);
      } else if (block.type === "tool_use") {
        console.log(`\n→ ${block.name}(${JSON.stringify(block.input)})`);
      }
    }
  } else if (msg.type === "user") {
    const content = msg.message.content;
    if (Array.isArray(content)) {
      for (const block of content) {
        if (
          typeof block === "object" &&
          block !== null &&
          "type" in block &&
          block.type === "tool_result"
        ) {
          const result = (block as { content: unknown }).content;
          const text = Array.isArray(result)
            ? result
                .map((c) =>
                  typeof c === "object" && c && "text" in c
                    ? (c as { text: string }).text
                    : "",
                )
                .join("\n")
            : String(result ?? "");
          console.log(`← ${text}\n`);
        }
      }
    }
  } else if (msg.type === "result") {
    console.log(`\n--- done (${msg.subtype}, turns: ${msg.num_turns}) ---`);
  }
}
