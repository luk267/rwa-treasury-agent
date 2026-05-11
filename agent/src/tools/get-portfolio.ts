import { tool } from "@anthropic-ai/claude-agent-sdk";
import { formatUnits, type PublicClient } from "viem";
import { IERC3643_ABI } from "../abi.js";
import type { Deployment } from "../config.js";

export function createGetPortfolioTool(
  deployment: Deployment,
  publicClient: PublicClient,
) {
  return tool(
    "get_portfolio",
    "Read the current token holdings of the treasury vault. Returns each token with its address, symbol, and balance in human-readable form (not wei).",
    {},
    async () => {
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

      const payload = {
        vault: deployment.vault,
        holdings,
      };

      return {
        content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
      };
    },
  );
}
