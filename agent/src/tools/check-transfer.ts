import type { Account, PublicClient } from "viem";
import { VAULT_ABI } from "../abi.js";
import type { Deployment } from "../config.js";
import { describeRejection } from "../outcome.js";
import {
  inputSchema,
  revertName,
  toolError,
  transferArgs,
  transferInput,
  type TransferInput,
  type VaultTool,
} from "./types.js";

export function createCheckTransferTool(
  deployment: Deployment,
  publicClient: Pick<PublicClient, "simulateContract">,
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
    async run(input) {
      try {
        const args = transferArgs(deployment, input);

        // One eth_call runs the same code as the real transaction. executeTransfer
        // returns its outcome, so no event logs are needed. A missing role, a paused
        // vault or invalid input reverts and throws ContractFunctionRevertedError.
        let outcome: readonly [boolean, number, `0x${string}`];
        try {
          const { result } = await publicClient.simulateContract({
            account,
            address: deployment.vault,
            abi: VAULT_ABI,
            functionName: "executeTransfer",
            args,
          });
          outcome = result;
        } catch (err) {
          const reverted = revertName(err);
          if (reverted) return { feasible: false, reason: reverted };
          throw err;
        }

        const [executed, reason, detail] = outcome;
        if (executed) return { feasible: true };
        return { feasible: false, ...describeRejection(reason, detail) };
      } catch (err) {
        return { feasible: false, ...toolError(err) };
      }
    },
  };
}
