import { formatUnits, maxUint256, type PublicClient } from "viem";
import { z } from "zod";
import { IERC3643_ABI, VAULT_ABI } from "../abi.js";
import type { Deployment, Token } from "../config.js";
import { inputSchema, toolError, type VaultTool } from "./types.js";

const noInput = z.object({});

/** Human-readable amount. The vault uses type(uint256).max for "no limit". */
function formatCap(value: bigint, token: Token): string {
  return value === maxUint256 ? "unlimited" : formatUnits(value, token.decimals);
}

export function createGetPortfolioTool(
  deployment: Deployment,
  publicClient: Pick<PublicClient, "readContract">,
): VaultTool<z.infer<typeof noInput>> {
  const vault = deployment.vault;

  async function readToken(token: Token) {
    const [balance, config, spent] = await Promise.all([
      publicClient.readContract({
        address: token.address,
        abi: IERC3643_ABI,
        functionName: "balanceOf",
        args: [vault],
      }),
      publicClient.readContract({
        address: vault,
        abi: VAULT_ABI,
        functionName: "getAssetConfig",
        args: [token.address],
      }),
      publicClient.readContract({
        address: vault,
        abi: VAULT_ABI,
        functionName: "assetSpentToday",
        args: [token.address],
      }),
    ]);
    return {
      token: token.address,
      symbol: token.symbol,
      balance: formatUnits(balance, token.decimals),
      allowed: config.allowed,
      dailyOutflowCap: formatCap(config.dailyOutflowCap, token),
      spentToday: formatUnits(spent, token.decimals),
    };
  }

  async function readCounterparty(cp: Deployment["counterparties"][number]) {
    const record = await publicClient.readContract({
      address: vault,
      abi: VAULT_ABI,
      functionName: "getCounterparty",
      args: [cp.address],
    });
    const caps = await Promise.all(
      deployment.tokens.map(async (token) => {
        const [dailyCap, spent] = await Promise.all([
          publicClient.readContract({
            address: vault,
            abi: VAULT_ABI,
            functionName: "getCounterpartyDailyCap",
            args: [cp.address, token.address],
          }),
          publicClient.readContract({
            address: vault,
            abi: VAULT_ABI,
            functionName: "spentToday",
            args: [cp.address, token.address],
          }),
        ]);
        return {
          symbol: token.symbol,
          dailyCap: formatCap(dailyCap, token),
          spentToday: formatUnits(spent, token.decimals),
        };
      }),
    );
    return { name: cp.name, address: cp.address, active: record.active, caps };
  }

  return {
    definition: {
      name: "get_portfolio",
      description:
        "Read the vault's state from the chain: each token's balance, whether the vault allows it, its daily outflow cap and today's outflow; each counterparty's whitelist status and, per token, its daily cap and today's usage. Amounts are human-readable (not wei). A cap of 0 blocks transfers; \"unlimited\" means no cap.",
      input_schema: inputSchema(noInput),
      strict: true,
    },
    parse: (input) => noInput.parse(input),
    requiresApproval: false,
    async run() {
      try {
        const [holdings, counterparties] = await Promise.all([
          Promise.all(deployment.tokens.map(readToken)),
          Promise.all(deployment.counterparties.map(readCounterparty)),
        ]);
        return { vault, holdings, counterparties };
      } catch (err) {
        return { success: false, ...toolError(err) };
      }
    },
  };
}
