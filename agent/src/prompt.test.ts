import { test } from "node:test";
import assert from "node:assert/strict";
import { REJECT_REASON, TOKEN_ERRORS_ABI, VAULT_ABI } from "./abi.js";
import type { Deployment } from "./config.js";
import { buildSystemPrompt } from "./prompt.js";

const deployment: Deployment = {
  chainId: 31337,
  rpcUrl: "http://127.0.0.1:8545",
  vault: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  roles: {
    admin: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    treasurer: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    pauser: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
    agent: "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
  },
  tokens: [{ address: "0x5FbDB2315678afecb367f032d93F642f64180aa3", symbol: "MOCK", decimals: 18 }],
  counterparties: [{ address: "0x976EA74026E726554dB657fA54763abd0C3a0aa9", name: "cp3" }],
  vaultFunding: "100000",
};

const prompt = buildSystemPrompt(deployment);

// A re-entrant call cannot come from the agent's own transaction.
const NOT_REACHABLE_BY_AGENT = new Set(["ReentrancyGuardReentrantCall"]);

test("the prompt explains every vault revert the agent can hit", () => {
  const reverts = VAULT_ABI.filter((item) => item.type === "error")
    .map((item) => item.name)
    .filter((name) => !NOT_REACHABLE_BY_AGENT.has(name));
  assert.ok(reverts.includes("ZeroAmount"));
  for (const name of reverts) {
    assert.match(prompt, new RegExp(`- ${name}:`), `prompt does not explain ${name}`);
  }
});

test("the prompt explains every rejection reason", () => {
  for (const reason of REJECT_REASON.filter((name) => name !== "None")) {
    assert.match(prompt, new RegExp(`- ${reason}:`), `prompt does not explain ${reason}`);
  }
});

test("the prompt explains every token error the decoder knows", () => {
  for (const item of TOKEN_ERRORS_ABI) {
    assert.match(prompt, new RegExp(`- ${item.name}\\(`), `prompt does not explain ${item.name}`);
  }
});

test("the prompt lists token and counterparty names with addresses", () => {
  assert.match(prompt, /- MOCK: 0x5FbDB2315678afecb367f032d93F642f64180aa3/);
  assert.match(prompt, /- cp3: 0x976EA74026E726554dB657fA54763abd0C3a0aa9/);
});
