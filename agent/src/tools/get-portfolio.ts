import { formatUnits, type PublicClient } from "viem";
import { z } from "zod";
import { IERC3643_ABI } from "../abi.js";
import type { Deployment } from "../config.js";
import { inputSchema, type VaultTool } from "./types.js";

const noInput = z.object({});

export function createGetPortfolioTool(
  deployment: Deployment,
  publicClient: PublicClient,
): VaultTool<z.infer<typeof noInput>> {
  return {
    definition: {
      name: "get_portfolio",
      description:
        "Read the current token holdings of the treasury vault. Returns each token with its address, symbol, and balance in human-readable form (not wei).",
      input_schema: inputSchema(noInput),
      strict: true,
    },
    parse: (input) => noInput.parse(input),
    requiresApproval: false,
    async run() {
      const holdings = await Promise.all(
        deployment.tokens.map(async (token) => {
          const balanceWei = await publicClient.readContract({
            address: token.address,
            abi: IERC3643_ABI,
            functionName: "balanceOf",
            args: [deployment.vault],
          });
          return {
            token: token.address,
            symbol: token.symbol,
            balance: formatUnits(balanceWei, token.decimals),
          };
        }),
      );

      return { vault: deployment.vault, holdings };
    },
  };
}
