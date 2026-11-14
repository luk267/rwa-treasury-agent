import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BaseError,
  ContractFunctionRevertedError,
  encodeAbiParameters,
  encodeErrorResult,
  encodeEventTopics,
  maxUint256,
  type Log,
  type TransactionReceipt,
} from "viem";
import { TOKEN_ERRORS_ABI, VAULT_ABI } from "../abi.js";
import { ToolInputError, type Deployment } from "../config.js";
import { createCheckTransferTool } from "./check-transfer.js";
import { createExecuteTransferTool } from "./execute-transfer.js";
import { createGetPortfolioTool } from "./get-portfolio.js";
import { revertName, toolError, transferArgs } from "./types.js";

const VAULT = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
const MOCK = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
const CP1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const AGENT = "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc";
const TX_HASH = `0x${"ab".repeat(32)}` as const;

const deployment: Deployment = {
  chainId: 31337,
  rpcUrl: "http://127.0.0.1:8545",
  vault: VAULT,
  roles: { admin: AGENT, treasurer: AGENT, pauser: AGENT, agent: AGENT },
  tokens: [{ address: MOCK, symbol: "MOCK", decimals: 18 }],
  counterparties: [{ address: CP1, name: "cp1" }],
  vaultFunding: "100000",
};

// --- toolError ---

test("toolError names a bad tool argument by its code", () => {
  const err = new ToolInputError("UnknownToken", 'Unknown token "USDC".');
  assert.deepEqual(toolError(err), { reason: "UnknownToken", detail: 'Unknown token "USDC".' });
});

test("toolError reports a viem error as RpcError with its short message", () => {
  const err = new BaseError("HTTP request failed.", { details: "connect ECONNREFUSED" });
  assert.match(err.message, /ECONNREFUSED/);
  assert.deepEqual(toolError(err), { reason: "RpcError", detail: "HTTP request failed." });
});

test("toolError reports any other failure as RpcError", () => {
  assert.deepEqual(toolError(new Error("boom")), { reason: "RpcError", detail: "boom" });
  assert.deepEqual(toolError("plain string"), { reason: "RpcError", detail: "plain string" });
});

// --- transferArgs ---

test("transferArgs resolves symbol, name and amount into executeTransfer arguments", () => {
  assert.deepEqual(transferArgs(deployment, { token: "mock", to: "cp1", amount: "2.5" }), [
    MOCK,
    CP1,
    25n * 10n ** 17n,
  ]);
});

test("transferArgs passes the input errors through", () => {
  assert.throws(
    () => transferArgs(deployment, { token: "MOCK", to: "cp9", amount: "1" }),
    (err: unknown) => err instanceof ToolInputError && err.code === "UnknownCounterparty",
  );
});

// --- revertName ---

/** A viem error as a reverted vault call throws it: the revert sits in the cause chain. */
function vaultRevert(data: `0x${string}`): BaseError {
  const reverted = new ContractFunctionRevertedError({
    abi: VAULT_ABI,
    data,
    functionName: "executeTransfer",
  });
  return new BaseError("Execution reverted.", { cause: reverted });
}

const ZERO_AMOUNT = encodeErrorResult({ abi: VAULT_ABI, errorName: "ZeroAmount" });
const VAULT_PAUSED = encodeErrorResult({ abi: VAULT_ABI, errorName: "VaultPaused" });

test("revertName reads the vault error from the cause chain", () => {
  assert.equal(revertName(vaultRevert(ZERO_AMOUNT)), "ZeroAmount");
});

test("revertName gives UnknownRevert for revert data it cannot decode", () => {
  assert.equal(revertName(vaultRevert("0xdeadbeef")), "UnknownRevert");
});

test("revertName gives null when the call did not revert", () => {
  assert.equal(revertName(new BaseError("HTTP request failed.")), null);
  assert.equal(revertName(new Error("boom")), null);
});

// --- check_transfer_feasibility ---

const agentAccount = { address: AGENT, type: "json-rpc" } as const;
const transfer = { token: "MOCK", to: "cp1", amount: "500" };

test("check_transfer_feasibility reports a revert by its error name", async () => {
  const publicClient = {
    async simulateContract(): Promise<never> {
      throw vaultRevert(ZERO_AMOUNT);
    },
  };
  const tool = createCheckTransferTool(deployment, publicClient, agentAccount);
  assert.deepEqual(await tool.run({ token: "MOCK", to: "cp1", amount: "500" }), {
    feasible: false,
    reason: "ZeroAmount",
  });
});

test("check_transfer_feasibility reports any other failure as RpcError", async () => {
  const publicClient = {
    async simulateContract(): Promise<never> {
      throw new BaseError("HTTP request failed.");
    },
  };
  const tool = createCheckTransferTool(deployment, publicClient, agentAccount);
  assert.deepEqual(await tool.run({ token: "MOCK", to: "cp1", amount: "500" }), {
    feasible: false,
    reason: "RpcError",
    detail: "HTTP request failed.",
  });
});

/** A pre-check whose dry run returns executeTransfer's outcome. */
function checkTool(outcome: readonly [boolean, number, `0x${string}`]) {
  const publicClient = {
    // viem's return type depends on the ABI generics; the tool reads only `result`.
    async simulateContract(): Promise<never> {
      return { result: outcome, request: {} } as never;
    },
  };
  return createCheckTransferTool(deployment, publicClient, agentAccount);
}

test("check_transfer_feasibility reports feasible for an executed dry run", async () => {
  assert.deepEqual(await checkTool([true, 0, "0x"]).run(transfer), { feasible: true });
});

test("check_transfer_feasibility reports a vault gate by its reason", async () => {
  assert.deepEqual(await checkTool([false, 3, "0x"]).run(transfer), {
    feasible: false,
    reason: "DailyCapExceeded",
  });
});

test("check_transfer_feasibility decodes the token error", async () => {
  assert.deepEqual(await checkTool([false, 5, "0x58c10a24"]).run(transfer), {
    feasible: false,
    reason: "ERC3643Compliance",
    detail: { raw: "0x58c10a24", decoded: "UnverifiedIdentity()" },
  });
});

// --- get_portfolio ---

test("get_portfolio formats balances, caps and usage, and shows the maximum as unlimited", async () => {
  const e18 = 10n ** 18n;
  // Distinct values per read, so a swapped field shows up.
  const reads: Record<string, unknown> = {
    balanceOf: 99_900n * e18,
    getAssetConfig: { allowed: true, dailyOutflowCap: maxUint256 },
    assetSpentToday: 100n * e18,
    getCounterparty: { active: true, addedAt: 1n },
    getCounterpartyDailyCap: 5_000n * e18,
    spentToday: 25n * 10n ** 17n,
  };
  const publicClient = {
    async readContract({ functionName }: { functionName: string }): Promise<never> {
      if (!(functionName in reads)) throw new Error(`unexpected read ${functionName}`);
      return reads[functionName] as never;
    },
  };
  const tool = createGetPortfolioTool(deployment, publicClient);
  assert.deepEqual(await tool.run({}), {
    vault: VAULT,
    holdings: [
      {
        token: MOCK,
        symbol: "MOCK",
        balance: "99900",
        allowed: true,
        dailyOutflowCap: "unlimited",
        spentToday: "100",
      },
    ],
    counterparties: [
      {
        name: "cp1",
        address: CP1,
        active: true,
        caps: [{ symbol: "MOCK", dailyCap: "5000", spentToday: "2.5" }],
      },
    ],
  });
});

test("get_portfolio reports a failed read as RpcError", async () => {
  const publicClient = {
    async readContract(): Promise<never> {
      throw new BaseError('The contract function "balanceOf" returned no data ("0x").', {
        details: "long viem text with a docs link",
      });
    },
  };
  const tool = createGetPortfolioTool(deployment, publicClient);
  assert.deepEqual(await tool.run({}), {
    success: false,
    reason: "RpcError",
    detail: 'The contract function "balanceOf" returned no data ("0x").',
  });
});

// --- execute_transfer ---

type MinedLog = Log<bigint, number, false>;
const BLOCK_HASH = `0x${"cd".repeat(32)}` as const;

/** A receipt log that looks like a vault event, emitted by `address`. */
function rejectedLog(address: `0x${string}`): MinedLog {
  const detail = encodeErrorResult({ abi: TOKEN_ERRORS_ABI, errorName: "UnverifiedIdentity" });
  return {
    address,
    topics: encodeEventTopics({
      abi: VAULT_ABI,
      eventName: "TransferRejected",
      args: { token: MOCK, to: CP1 },
    }) as Log["topics"],
    data: encodeAbiParameters(
      [{ type: "uint256" }, { type: "uint8" }, { type: "bytes" }],
      [500n * 10n ** 18n, 5, detail],
    ),
    blockHash: BLOCK_HASH,
    blockNumber: 15n,
    logIndex: 0,
    transactionHash: TX_HASH,
    transactionIndex: 0,
    removed: false,
  };
}

function executedLog(address: `0x${string}`): MinedLog {
  return {
    ...rejectedLog(address),
    topics: encodeEventTopics({
      abi: VAULT_ABI,
      eventName: "TransferExecuted",
      args: { token: MOCK, to: CP1, by: AGENT },
    }) as Log["topics"],
    data: encodeAbiParameters([{ type: "uint256" }], [500n * 10n ** 18n]),
  };
}

/** A mined receipt with these logs. Only status and logs matter to the tool. */
function receipt(
  logs: MinedLog[],
  status: TransactionReceipt["status"] = "success",
): TransactionReceipt {
  return {
    blockHash: BLOCK_HASH,
    blockNumber: 15n,
    contractAddress: null,
    cumulativeGasUsed: 0n,
    effectiveGasPrice: 0n,
    from: AGENT,
    gasUsed: 0n,
    logs,
    logsBloom: "0x",
    status,
    to: VAULT,
    transactionHash: TX_HASH,
    transactionIndex: 0,
    type: "eip1559",
  };
}

function executeTool(logs: MinedLog[], status: TransactionReceipt["status"] = "success") {
  const walletClient = {
    async writeContract() {
      return TX_HASH;
    },
  };
  const publicClient = {
    async waitForTransactionReceipt() {
      return receipt(logs, status);
    },
  };
  return createExecuteTransferTool(deployment, publicClient, walletClient);
}

test("execute_transfer reports a reverted receipt as TransactionReverted", async () => {
  // Even with a vault event in the logs: a reverted transaction changed nothing.
  assert.deepEqual(await executeTool([executedLog(VAULT)], "reverted").run(transfer), {
    success: false,
    reason: "TransactionReverted",
    txHash: TX_HASH,
  });
});

test("execute_transfer reads the outcome from the vault's event", async () => {
  const result = await executeTool([rejectedLog(VAULT)]).run(transfer);
  assert.equal(result.success, false);
  assert.equal(result.reason, "ERC3643Compliance");
  assert.deepEqual(result.detail, { raw: "0x58c10a24", decoded: "UnverifiedIdentity()" });
});

test("execute_transfer ignores a look-alike event from another contract", async () => {
  // The token emits a fake TransferRejected before the vault's real TransferExecuted.
  const result = await executeTool([rejectedLog(MOCK), executedLog(VAULT)]).run(transfer);
  assert.equal(result.success, true);
  assert.equal(result.event, "TransferExecuted");
});

test("execute_transfer reports a revert at submission by its error name", async () => {
  const walletClient = {
    async writeContract(): Promise<never> {
      throw vaultRevert(VAULT_PAUSED);
    },
  };
  const publicClient = {
    async waitForTransactionReceipt(): Promise<never> {
      throw new Error("not reached");
    },
  };
  const tool = createExecuteTransferTool(deployment, publicClient, walletClient);
  assert.deepEqual(await tool.run(transfer), {
    success: false,
    reason: "VaultPaused",
    txHash: null,
  });
});

test("execute_transfer returns the human-readable amount on success", async () => {
  const result = await executeTool([executedLog(VAULT)]).run(transfer);
  assert.deepEqual(result, {
    success: true,
    txHash: TX_HASH,
    event: "TransferExecuted",
    amount: "500",
    to: CP1,
  });
});

test("execute_transfer without a vault event reports UnknownOutcome", async () => {
  const result = await executeTool([executedLog(MOCK)]).run(transfer);
  assert.equal(result.success, false);
  assert.equal(result.reason, "UnknownOutcome");
});
