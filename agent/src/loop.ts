import type Anthropic from "@anthropic-ai/sdk";
import type { VaultTool } from "./tools/types.js";

const MAX_TURNS = 12;
const MAX_TOKENS = 16000;

/** The model stopped for a reason the loop cannot handle, or never finished. */
export class AgentLoopError extends Error {
  override name = "AgentLoopError";
}

/** The part of the Anthropic client the loop uses. Tests pass a fake. */
export interface MessagesClient {
  messages: {
    create(
      params: Anthropic.MessageCreateParamsNonStreaming,
    ): Promise<Pick<Anthropic.Message, "content" | "stop_reason">>;
  };
}

export interface RunAgentOptions {
  client: MessagesClient;
  model: string;
  system: string;
  userPrompt: string;
  tools: readonly VaultTool<unknown>[];
  /** Asked before any tool with requiresApproval runs. false = declined. */
  approve: (toolName: string, input: unknown) => Promise<boolean>;
  log: (line: string) => void;
}

/**
 * The agent loop: ask the model, run the tools it requests, send the results
 * back, repeat until it answers without a tool call.
 */
export async function runAgent(options: RunAgentOptions): Promise<{ turns: number }> {
  const { client, model, system, userPrompt, tools, approve, log } = options;
  const toolsByName = new Map(tools.map((tool) => [tool.definition.name, tool]));
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: userPrompt }];

  for (let turn = 1; turn <= MAX_TURNS; turn++) {
    // 1. Request: full history plus the tool definitions.
    const response = await client.messages.create({
      model,
      max_tokens: MAX_TOKENS,
      system,
      tools: tools.map((tool) => tool.definition),
      messages,
    });

    // 2. Keep the assistant turn unchanged (including blocks we don't print).
    messages.push({ role: "assistant", content: response.content });
    for (const block of response.content) {
      if (block.type === "text" && block.text.trim()) log(block.text);
    }

    // 3. Done, or tools to run. Any other stop reason is an error.
    if (response.stop_reason === "end_turn") return { turns: turn };
    if (response.stop_reason !== "tool_use") {
      throw new AgentLoopError(`Model stopped with stop_reason "${response.stop_reason}".`);
    }

    // 4. Run every requested tool. 5. Return all results in one user message.
    const results: Anthropic.ToolResultBlockParam[] = [];
    for (const block of response.content) {
      if (block.type !== "tool_use") continue;
      log(`\n→ ${block.name}(${JSON.stringify(block.input)})`);
      const result = await callTool(toolsByName.get(block.name), block, approve);
      log(`← ${result.content}\n`);
      results.push(result);
    }
    messages.push({ role: "user", content: results });
  }

  throw new AgentLoopError(`No final answer after ${MAX_TURNS} turns.`);
}

async function callTool(
  tool: VaultTool<unknown> | undefined,
  block: Anthropic.ToolUseBlock,
  approve: RunAgentOptions["approve"],
): Promise<Anthropic.ToolResultBlockParam & { content: string }> {
  const reply = (payload: Record<string, unknown>, isError = false) => ({
    type: "tool_result" as const,
    tool_use_id: block.id,
    content: JSON.stringify(payload, null, 2),
    ...(isError ? { is_error: true } : {}),
  });

  if (!tool) return reply({ error: `Unknown tool "${block.name}".` }, true);

  let input: unknown;
  try {
    input = tool.parse(block.input);
  } catch (err) {
    return reply({ error: "InvalidInput", detail: errorMessage(err) }, true);
  }

  if (tool.requiresApproval && !(await approve(block.name, input))) {
    return reply({ success: false, reason: "DeclinedByOperator" });
  }

  try {
    return reply(await tool.run(input));
  } catch (err) {
    return reply({ error: errorMessage(err) }, true);
  }
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
