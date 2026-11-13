import type Anthropic from "@anthropic-ai/sdk";
import { BaseError, ContractFunctionRevertedError } from "viem";
import { z } from "zod";
import {
  ToolInputError,
  findToken,
  parseAmount,
  resolveCounterparty,
  type Deployment,
} from "../config.js";

/** A vault operation the model may call. The loop in loop.ts drives these. */
export interface VaultTool<Input> {
  /** Sent to the API: name, description, input_schema, strict: true. */
  definition: Anthropic.Tool;
  /** Validates the model's input locally. Throws on mismatch. */
  parse(input: unknown): Input;
  /** True means the operator must confirm before run() is called. */
  requiresApproval: boolean;
  run(input: Input): Promise<Record<string, unknown>>;
}

/** JSON Schema for a tool's input. zod emits `additionalProperties: false`, which strict mode needs. */
export function inputSchema(schema: z.ZodObject): Anthropic.Tool.InputSchema {
  return { ...z.toJSONSchema(schema), type: "object" };
}

/** Input fields shared by the two transfer tools. */
export const transferInput = z.object({
  token: z.string().describe("Token symbol (e.g. 'MOCK') or address"),
  to: z.string().describe("Counterparty name (e.g. 'cp1') or address"),
  amount: z.string().describe("Human-readable amount, e.g. '500'"),
});
export type TransferInput = z.infer<typeof transferInput>;

/**
 * Resolve the model's transfer input into the arguments of executeTransfer:
 * token address, recipient address, amount in base units. Throws ToolInputError.
 */
export function transferArgs(
  deployment: Deployment,
  { token, to, amount }: TransferInput,
): readonly [`0x${string}`, `0x${string}`, bigint] {
  const tokenInfo = findToken(deployment, token);
  return [tokenInfo.address, resolveCounterparty(deployment, to), parseAmount(amount, tokenInfo)];
}

/**
 * The vault error a viem call reverted with, e.g. "VaultPaused". "UnknownRevert"
 * if the revert data does not decode, null if the call did not revert.
 */
export function revertName(err: unknown): string | null {
  if (!(err instanceof BaseError)) return null;
  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError)) return null;
  return reverted.data?.errorName ?? "UnknownRevert";
}

/** Name the failure: a bad tool argument, or an RPC problem for everything else. */
export function toolError(err: unknown): { reason: string; detail: string } {
  if (err instanceof ToolInputError) return { reason: err.code, detail: err.message };
  const detail =
    err instanceof BaseError ? err.shortMessage : err instanceof Error ? err.message : String(err);
  return { reason: "RpcError", detail };
}
