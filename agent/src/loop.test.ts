import { test } from "node:test";
import assert from "node:assert/strict";
import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { AgentLoopError, runAgent, type MessagesClient, type RunAgentOptions } from "./loop.js";
import type { VaultTool } from "./tools/types.js";

type Reply = Pick<Anthropic.Message, "content" | "stop_reason">;

/** A client that answers from a script and records every request. */
function fakeClient(replies: Reply[] | ((call: number) => Reply)) {
  const requests: Anthropic.MessageCreateParamsNonStreaming[] = [];
  const client: MessagesClient = {
    messages: {
      async create(params) {
        // The loop keeps appending to the same array, so copy it now.
        requests.push({ ...params, messages: [...params.messages] });
        const reply = typeof replies === "function" ? replies(requests.length) : replies.shift();
        if (!reply) throw new Error("fake client: no reply left");
        return reply;
      },
    },
  };
  return { client, requests };
}

function text(value: string): Anthropic.TextBlock {
  return { type: "text", text: value, citations: null };
}

function toolUse(id: string, name: string, input: unknown): Anthropic.ToolUseBlock {
  return { type: "tool_use", id, name, input, caller: { type: "direct" } };
}

const done: Reply = { content: [text("All done.")], stop_reason: "end_turn" };

const amountInput = z.object({ amount: z.number() });
type AmountInput = z.infer<typeof amountInput>;

/** A tool that records its runs. */
function fakeTool(name: string, requiresApproval = false) {
  const runs: AmountInput[] = [];
  const tool: VaultTool<AmountInput> = {
    definition: {
      name,
      description: `fake ${name}`,
      input_schema: { type: "object" },
    },
    parse: (input) => amountInput.parse(input),
    requiresApproval,
    async run(input) {
      runs.push(input);
      return { ok: true, amount: input.amount };
    },
  };
  return { tool, runs };
}

function run(
  client: MessagesClient,
  tools: VaultTool<unknown>[],
  approve: RunAgentOptions["approve"] = async () => true,
) {
  const lines: string[] = [];
  const result = runAgent({
    client,
    model: "test-model",
    system: "test",
    userPrompt: "do it",
    tools,
    approve,
    log: (line) => lines.push(line),
  });
  return { result, lines };
}

/** The tool_result blocks in the last message of a request. */
function toolResults(request: Anthropic.MessageCreateParamsNonStreaming | undefined) {
  const last = request?.messages.at(-1);
  assert.equal(last?.role, "user");
  assert.ok(Array.isArray(last.content));
  return last.content.map((block) => {
    assert.equal(block.type, "tool_result");
    return block;
  });
}

function payload(block: Anthropic.ToolResultBlockParam): Record<string, unknown> {
  assert.equal(typeof block.content, "string");
  return JSON.parse(String(block.content)) as Record<string, unknown>;
}

test("end_turn ends the run after one request", async () => {
  const { client, requests } = fakeClient([done]);
  const { result, lines } = run(client, []);
  assert.deepEqual(await result, { turns: 1 });
  assert.equal(requests.length, 1);
  assert.deepEqual(lines, ["All done."]);
});

test("an unknown tool comes back as an error result", async () => {
  const { client, requests } = fakeClient([
    { content: [toolUse("t1", "no_such_tool", {})], stop_reason: "tool_use" },
    done,
  ]);
  assert.deepEqual(await run(client, []).result, { turns: 2 });
  const [block] = toolResults(requests[1]);
  assert.ok(block);
  assert.equal(block.tool_use_id, "t1");
  assert.equal(block.is_error, true);
  assert.deepEqual(payload(block), { error: 'Unknown tool "no_such_tool".' });
});

test("invalid input gives InvalidInput and run is not called", async () => {
  const { tool, runs } = fakeTool("pay");
  const { client, requests } = fakeClient([
    { content: [toolUse("t1", "pay", { amount: "ten" })], stop_reason: "tool_use" },
    done,
  ]);
  await run(client, [tool]).result;
  const [block] = toolResults(requests[1]);
  assert.ok(block);
  assert.equal(block.is_error, true);
  assert.equal(payload(block).error, "InvalidInput");
  assert.equal(runs.length, 0);
});

test("a declined approval gives DeclinedByOperator and run is not called", async () => {
  const { tool, runs } = fakeTool("pay", true);
  const asked: [string, unknown][] = [];
  const { client, requests } = fakeClient([
    { content: [toolUse("t1", "pay", { amount: 5 })], stop_reason: "tool_use" },
    done,
  ]);
  await run(client, [tool], async (name, input) => {
    asked.push([name, input]);
    return false;
  }).result;
  assert.deepEqual(asked, [["pay", { amount: 5 }]]);
  assert.equal(runs.length, 0);
  const [block] = toolResults(requests[1]);
  assert.ok(block);
  assert.equal(block.is_error, undefined);
  assert.deepEqual(payload(block), { success: false, reason: "DeclinedByOperator" });
});

test("an approved tool runs, and a tool without approval is not asked", async () => {
  const guarded = fakeTool("pay", true);
  const open = fakeTool("read");
  const asked: string[] = [];
  const { client } = fakeClient([
    {
      content: [toolUse("t1", "read", { amount: 1 }), toolUse("t2", "pay", { amount: 2 })],
      stop_reason: "tool_use",
    },
    done,
  ]);
  await run(client, [guarded.tool, open.tool], async (name) => {
    asked.push(name);
    return true;
  }).result;
  assert.deepEqual(asked, ["pay"]);
  assert.deepEqual(open.runs, [{ amount: 1 }]);
  assert.deepEqual(guarded.runs, [{ amount: 2 }]);
});

test("all tool results go back in one user message, in order", async () => {
  const { tool } = fakeTool("read");
  const { client, requests } = fakeClient([
    {
      content: [
        text("Reading twice."),
        toolUse("t1", "read", { amount: 1 }),
        toolUse("t2", "read", { amount: 2 }),
      ],
      stop_reason: "tool_use",
    },
    done,
  ]);
  await run(client, [tool]).result;
  const second = requests[1];
  assert.ok(second);
  // user prompt, assistant turn, one user message with both results
  assert.equal(second.messages.length, 3);
  assert.equal(second.messages[1]?.role, "assistant");
  const blocks = toolResults(second);
  assert.deepEqual(
    blocks.map((block) => block.tool_use_id),
    ["t1", "t2"],
  );
  assert.deepEqual(
    blocks.map((block) => payload(block).amount),
    [1, 2],
  );
});

test("stop_reason max_tokens throws AgentLoopError", async () => {
  const { client } = fakeClient([{ content: [text("cut off")], stop_reason: "max_tokens" }]);
  await assert.rejects(run(client, []).result, (err: unknown) => {
    assert.ok(err instanceof AgentLoopError);
    assert.match(err.message, /max_tokens/);
    return true;
  });
});

test("the loop stops after 12 turns without a final answer", async () => {
  const { tool, runs } = fakeTool("read");
  const { client, requests } = fakeClient((call) => ({
    content: [toolUse(`t${call}`, "read", { amount: call })],
    stop_reason: "tool_use",
  }));
  await assert.rejects(run(client, [tool]).result, (err: unknown) => {
    assert.ok(err instanceof AgentLoopError);
    assert.equal(err.message, "No final answer after 12 turns.");
    return true;
  });
  assert.equal(requests.length, 12);
  assert.equal(runs.length, 12);
});
