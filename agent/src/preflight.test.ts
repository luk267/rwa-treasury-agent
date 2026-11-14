import { test } from "node:test";
import assert from "node:assert/strict";
import { ConfigError, type Deployment } from "./config.js";
import { askOperator, checkChain, RpcUnavailableError, type OperatorTerminal } from "./preflight.js";

const AGENT = "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc";

const deployment: Deployment = {
  chainId: 31337,
  rpcUrl: "http://127.0.0.1:8545",
  vault: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  roles: { admin: AGENT, treasurer: AGENT, pauser: AGENT, agent: AGENT },
  tokens: [],
  counterparties: [],
  vaultFunding: "100000",
};

function chain(chainId: number) {
  return {
    async getChainId() {
      return chainId;
    },
  };
}

const unreachable = {
  async getChainId(): Promise<never> {
    throw new Error("connect ECONNREFUSED");
  },
};

// --- checkChain ---

test("checkChain passes when the RPC serves the deployment's chain", async () => {
  await checkChain(chain(31337), deployment, "local");
});

test("checkChain refuses an RPC that serves another chain", async () => {
  await assert.rejects(
    checkChain(chain(5), deployment, "local"),
    (err: unknown) =>
      err instanceof ConfigError &&
      err.message ===
        "The RPC serves chain 5, but deployments/local.json is for chain 31337.",
  );
});

test("checkChain names the local RPC it cannot reach", async () => {
  await assert.rejects(
    checkChain(unreachable, deployment, "local"),
    (err: unknown) =>
      err instanceof RpcUnavailableError && err.message.includes("http://127.0.0.1:8545"),
  );
});

test("checkChain does not print the Sepolia RPC URL", async () => {
  const sepolia = { ...deployment, rpcUrl: "https://rpc.example/secret-key" };
  await assert.rejects(
    checkChain(unreachable, sepolia, "sepolia"),
    (err: unknown) =>
      err instanceof RpcUnavailableError &&
      err.message === "Cannot reach the RPC in RPC_URL_SEPOLIA.",
  );
});

// --- askOperator ---

/** A terminal that answers `answer` and records what was asked and warned. */
function terminal(isTTY: boolean, answer = "") {
  const asked: string[] = [];
  const warned: string[] = [];
  const fake: OperatorTerminal = {
    isTTY,
    async question(prompt) {
      asked.push(prompt);
      return answer;
    },
    warn: (line) => warned.push(line),
  };
  return { fake, asked, warned };
}

test("askOperator declines without a terminal and does not ask", async () => {
  const { fake, asked, warned } = terminal(false, "y");
  assert.equal(await askOperator(fake), false);
  assert.deepEqual(asked, []);
  assert.match(warned[0] ?? "", /No terminal to confirm the transfer: declined/);
});

test("askOperator approves only y or yes", async () => {
  for (const answer of ["y", "Y", "yes", " YES "]) {
    assert.equal(await askOperator(terminal(true, answer).fake), true, `answer ${answer}`);
  }
  for (const answer of ["", "n", "no", "yep", "y es"]) {
    assert.equal(await askOperator(terminal(true, answer).fake), false, `answer ${answer}`);
  }
});

test("askOperator asks once with the default no", async () => {
  const { fake, asked } = terminal(true, "n");
  await askOperator(fake);
  assert.deepEqual(asked, ["Proceed? [y/N] "]);
});
