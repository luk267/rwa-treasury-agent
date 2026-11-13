import {
  BaseError,
  ContractFunctionRevertedError,
  decodeEventLog,
  encodeFunctionData,
  type Account,
  type PublicClient,
} from "viem";
import { VAULT_ABI } from "../abi.js";
import {
  findToken,
  parseAmount,
  resolveCounterparty,
  type Deployment,
} from "../config.js";
import { describeRejection } from "../outcome.js";
import {
  inputSchema,
  toolError,
  transferInput,
  type TransferInput,
  type VaultTool,
} from "./types.js";

export function createCheckTransferTool(
  deployment: Deployment,
  publicClient: PublicClient,
  account: Account,
): VaultTool<TransferInput> {
  return {
    definition: {
      name: "check_transfer_feasibility",
      description:
        "Simulate a transfer to check if it would succeed or be rejected, without sending a real transaction. Always call this before execute_transfer.",
      input_schema: inputSchema(transferInput),
      strict: true,
    },
    parse: (input) => transferInput.parse(input),
    requiresApproval: false,
    async run({ token, to, amount }) {
      try {
        const tokenInfo = findToken(deployment, token);
        const recipient = resolveCounterparty(deployment, to);
        const amountWei = parseAmount(amount, tokenInfo);

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
              return { feasible: false, reason: errorName };
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
            return { feasible: true };
          }
          if (decoded.eventName === "TransferRejected") {
            const args = decoded.args as {
              reason: number;
              detail: `0x${string}`;
            };
            return {
              feasible: false,
              ...describeRejection(Number(args.reason), args.detail),
            };
          }
        }

        return {
          feasible: false,
          reason: "UnknownOutcome",
          detail: "Simulation succeeded but emitted no vault event.",
        };
      } catch (err) {
        return { feasible: false, ...toolError(err) };
      }
    },
  };
}
