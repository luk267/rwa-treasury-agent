import {
  BaseError,
  ContractFunctionRevertedError,
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
            args: [tokenInfo.address, recipient, amountWei],
          });
          outcome = result;
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

        const [executed, reason, detail] = outcome;
        if (executed) return { feasible: true };
        return { feasible: false, ...describeRejection(reason, detail) };
      } catch (err) {
        return { feasible: false, ...toolError(err) };
      }
    },
  };
}
