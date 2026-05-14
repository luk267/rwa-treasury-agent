import { tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeEventLog,
  parseUnits,
  type Account,
  type Chain,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { REJECT_REASON, VAULT_ABI } from "../abi.js";
import {
  findToken,
  resolveCounterparty,
  type Deployment,
} from "../config.js";

export function createExecuteTransferTool(
  deployment: Deployment,
  publicClient: PublicClient,
  walletClient: WalletClient<Transport, Chain, Account>,
) {
  return tool(
    "execute_transfer",
    "Execute a real token transfer through the treasury vault. The transfer goes through all policy gates and the ERC-3643 compliance layer. Always call check_transfer_feasibility first.",
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

        // Submission. Returns tx hash before inclusion. May throw if the RPC
        // rejects the tx - typically because its internal gas-estimate eth_call
        // reverts (e.g. VaultPaused, AccessControlUnauthorizedAccount).
        let txHash: `0x${string}`;
        try {
          txHash = await walletClient.writeContract({
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
              return ok({ success: false, reason: errorName, txHash: null });
            }
          }
          throw err;
        }

        // Wait for inclusion. On Anvil this is sub-second.
        const receipt = await publicClient.waitForTransactionReceipt({
          hash: txHash,
        });

        // Defensive: the vault is designed so policy fails emit events instead
        // of reverting, so a reverted status here is rare (e.g. pause flipped
        // between simulation and submission).
        if (receipt.status === "reverted") {
          return ok({
            success: false,
            reason: "TransactionReverted",
            txHash,
          });
        }

        // Same log-decoding shape as check_transfer_feasibility - but on a real
        // receipt rather than simulated logs.
        for (const log of receipt.logs) {
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
            return ok({
              success: true,
              txHash,
              event: "TransferExecuted",
              amount,
              to: recipient,
            });
          }
          if (decoded.eventName === "TransferRejected") {
            const args = decoded.args as {
              reason: number;
              detail: `0x${string}`;
            };
            const reasonIdx = Number(args.reason);
            return ok({
              success: false,
              txHash,
              reason: REJECT_REASON[reasonIdx] ?? `Reason${reasonIdx}`,
              detail: args.detail,
            });
          }
        }

        return ok({
          success: false,
          txHash,
          reason: "UnknownOutcome",
          detail: "Transaction mined but emitted no vault event.",
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return ok({
          success: false,
          reason: "NetworkError",
          detail: message,
          txHash: null,
        });
      }
    },
  );
}

function ok(payload: object) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
  };
}
