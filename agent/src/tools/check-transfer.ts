import { tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeEventLog,
  encodeFunctionData,
  parseUnits,
  type Account,
  type PublicClient,
} from "viem";
import { REJECT_REASON, VAULT_ABI } from "../abi.js";
import {
  findToken,
  resolveCounterparty,
  type Deployment,
} from "../config.js";

export function createCheckTransferTool(
  deployment: Deployment,
  publicClient: PublicClient,
  account: Account,
) {
  return tool(
    "check_transfer_feasibility",
    "Simulate a transfer to check if it would succeed or be rejected, without sending a real transaction. Always call this before execute_transfer.",
    {
      token: z.string().describe("Token symbol (e.g. 'MOCK') or address"),
      to: z.string().describe("Counterparty name (e.g. 'cp1') or address"),
      amount: z.string().describe("Human-readable amount, e.g. '500'"),
    },
    async ({ token, to, amount }) => {
      try {
        const tokenInfo = findToken(deployment, token);
        const recipient = resolveCounterparty(deployment, to);
        const amountWei = parseUnits(amount, tokenInfo.decimals);

        // Phase 1: hard-revert detection via simulateContract (eth_call).
        // Throws ContractFunctionRevertedError on revert; no logs returned.
        try {
          await publicClient.simulateContract({
            account,
            address: deployment.vault,
            abi: VAULT_ABI,
            functionName: "executeTransfer",
            args: [tokenInfo.address, recipient, amountWei],
          });
        } catch (err) {
          if (err instanceof BaseError) {
            const reverted = err.walk(
              (e) => e instanceof ContractFunctionRevertedError,
            );
            if (reverted instanceof ContractFunctionRevertedError) {
              const errorName = reverted.data?.errorName ?? "UnknownRevert";
              return ok({ feasible: false, reason: errorName });
            }
          }
          throw err;
        }

        // Phase 2: event-log inspection via simulateCalls (eth_simulateV1).
        // simulateContract returned no revert, so the call would succeed -
        // but the vault may emit TransferRejected instead of TransferExecuted.
        const calldata = encodeFunctionData({
          abi: VAULT_ABI,
          functionName: "executeTransfer",
          args: [tokenInfo.address, recipient, amountWei],
        });

        const { results } = await publicClient.simulateCalls({
          account: account.address,
          calls: [{ to: deployment.vault, data: calldata }],
        });

        const logs = results[0].logs ?? [];
        for (const log of logs) {
          let decoded;
          try {
            decoded = decodeEventLog({
              abi: VAULT_ABI,
              topics: log.topics,
              data: log.data,
            });
          } catch {
            continue; // foreign event (e.g. inner ERC-20 Transfer)
          }
          if (decoded.eventName === "TransferExecuted") {
            return ok({ feasible: true });
          }
          if (decoded.eventName === "TransferRejected") {
            const args = decoded.args as {
              reason: number;
              detail: `0x${string}`;
            };
            const reasonIdx = Number(args.reason);
            return ok({
              feasible: false,
              reason: REJECT_REASON[reasonIdx] ?? `Reason${reasonIdx}`,
              detail: args.detail,
            });
          }
        }

        return ok({
          feasible: false,
          reason: "UnknownOutcome",
          detail: "Simulation succeeded but emitted no vault event.",
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return ok({ feasible: false, reason: "NetworkError", detail: message });
      }
    },
  );
}

function ok(payload: object) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
  };
}
