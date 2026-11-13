import {
  BaseError,
  ContractFunctionRevertedError,
  decodeEventLog,
  isAddressEqual,
  type Account,
  type Chain,
  type PublicClient,
  type Transport,
  type WalletClient,
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

export function createExecuteTransferTool(
  deployment: Deployment,
  publicClient: Pick<PublicClient, "waitForTransactionReceipt">,
  walletClient: Pick<WalletClient<Transport, Chain, Account>, "writeContract">,
): VaultTool<TransferInput> {
  return {
    definition: {
      name: "execute_transfer",
      description:
        "Execute a real token transfer through the treasury vault. The transfer goes through all policy gates and the ERC-3643 compliance layer. Always call check_transfer_feasibility first. The operator may decline the call.",
      input_schema: inputSchema(transferInput),
      strict: true,
    },
    parse: (input) => transferInput.parse(input),
    requiresApproval: true,
    async run({ token, to, amount }) {
      try {
        const tokenInfo = findToken(deployment, token);
        const recipient = resolveCounterparty(deployment, to);
        const amountWei = parseAmount(amount, tokenInfo);

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
              return { success: false, reason: errorName, txHash: null };
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
          return {
            success: false,
            reason: "TransactionReverted",
            txHash,
          };
        }

        // The receipt has no return value, so the outcome comes from the vault's event.
        // Only the vault's own logs count: a token could emit a look-alike event.
        for (const log of receipt.logs) {
          if (!isAddressEqual(log.address, deployment.vault)) continue;
          let decoded;
          try {
            decoded = decodeEventLog({
              abi: VAULT_ABI,
              topics: log.topics,
              data: log.data,
            });
          } catch {
            continue; // a vault event the ABI above does not list
          }
          if (decoded.eventName === "TransferExecuted") {
            return {
              success: true,
              txHash,
              event: "TransferExecuted",
              amount,
              to: recipient,
            };
          }
          if (decoded.eventName === "TransferRejected") {
            return {
              success: false,
              txHash,
              ...describeRejection(decoded.args.reason, decoded.args.detail),
            };
          }
        }

        return {
          success: false,
          txHash,
          reason: "UnknownOutcome",
          detail: "Transaction mined but emitted no vault event.",
        };
      } catch (err) {
        return { success: false, ...toolError(err), txHash: null };
      }
    },
  };
}
