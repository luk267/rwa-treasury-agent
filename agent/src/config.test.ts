import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import {
  ConfigError,
  ToolInputError,
  createClients,
  findToken,
  loadDeployment,
  parseAmount,
  resolveCounterparty,
  resolveNetwork,
  type Deployment,
  type Token,
  type ToolInputErrorCode,
} from "./config.js";

// Addresses as scripts/local-dev.sh writes them on a fresh Anvil chain.
const MOCK = "0x5FbDB2315678afecb367f032d93F642f64180aa3" as const;
const CP1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const CP3 = "0x976EA74026E726554dB657fA54763abd0C3a0aa9";
const STRANGER = "0x1111111111111111111111111111111111111111";

const MOCK_TOKEN: Token = { address: MOCK, symbol: "MOCK", decimals: 18 };
const SIX_DECIMALS: Token = { address: MOCK, symbol: "USDX", decimals: 6 };

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
  tokens: [MOCK_TOKEN],
  counterparties: [
    { address: CP1, name: "cp1" },
    { address: CP3, name: "cp3" },
  ],
  vaultFunding: "100000",
};


/** Assert that `fn` throws a ToolInputError with this code. */
function throwsCode(fn: () => unknown, code: ToolInputErrorCode) {
  assert.throws(fn, (err: unknown) => {
    assert.ok(err instanceof ToolInputError);
    assert.equal(err.code, code);
    return true;
  });
}

// --- findToken ---

test("findToken matches the symbol in any case", () => {
  assert.equal(findToken(deployment, "mock"), MOCK_TOKEN);
  assert.equal(findToken(deployment, "MOCK"), MOCK_TOKEN);
});

test("findToken matches the address in any case", () => {
  assert.equal(findToken(deployment, MOCK.toLowerCase()), MOCK_TOKEN);
});

test("findToken refuses an unknown token with UnknownToken", () => {
  throwsCode(() => findToken(deployment, "USDC"), "UnknownToken");
  throwsCode(() => findToken(deployment, STRANGER), "UnknownToken");
});

// --- resolveCounterparty ---

test("resolveCounterparty maps a name in any case to its address", () => {
  assert.equal(resolveCounterparty(deployment, "cp3"), CP3);
  assert.equal(resolveCounterparty(deployment, "CP1"), CP1);
});

test("resolveCounterparty passes any valid address through", () => {
  // The vault decides whether it is whitelisted.
  assert.equal(resolveCounterparty(deployment, STRANGER), STRANGER);
});

test("resolveCounterparty refuses an unknown name with UnknownCounterparty", () => {
  throwsCode(() => resolveCounterparty(deployment, "cp9"), "UnknownCounterparty");
  throwsCode(() => resolveCounterparty(deployment, "0x1234"), "UnknownCounterparty");
});

// --- parseAmount ---

test("parseAmount converts decimals into base units", () => {
  assert.equal(parseAmount("500", MOCK_TOKEN), 500n * 10n ** 18n);
  assert.equal(parseAmount("0.5", MOCK_TOKEN), 5n * 10n ** 17n);
  assert.equal(parseAmount("0", MOCK_TOKEN), 0n);
  assert.equal(parseAmount("1.25", SIX_DECIMALS), 1_250_000n);
});

test("parseAmount accepts exactly token.decimals decimal places", () => {
  assert.equal(parseAmount("0.000000000000000001", MOCK_TOKEN), 1n);
  assert.equal(parseAmount("0.000001", SIX_DECIMALS), 1n);
});

test("parseAmount accepts trailing zeros beyond the token's decimals", () => {
  assert.equal(parseAmount("1.0000000000000000000", MOCK_TOKEN), 10n ** 18n);
  assert.equal(parseAmount("2.50000000", SIX_DECIMALS), 2_500_000n);
});

test("parseAmount refuses an amount finer than the token's decimals, instead of rounding", () => {
  // parseUnits would round this up to 1 wei.
  throwsCode(() => parseAmount("0.0000000000000000006", MOCK_TOKEN), "InvalidAmount");
  // parseUnits would round this up to 2 MOCK.
  throwsCode(() => parseAmount("1.9999999999999999995", MOCK_TOKEN), "InvalidAmount");
  throwsCode(() => parseAmount("1.0000001", SIX_DECIMALS), "InvalidAmount");
});

test("parseAmount refuses what is not a non-negative decimal number", () => {
  for (const bad of ["", "abc", "-5", "1e3", "1,000", " 500 ", ".", "1.2.3"]) {
    throwsCode(() => parseAmount(bad, MOCK_TOKEN), "InvalidAmount");
  }
});

test("parseAmount names a non-number as such, even with many decimal places", () => {
  assert.throws(() => parseAmount(`abc.${"x".repeat(19)}`, MOCK_TOKEN), /not a decimal number/);
});

// --- loadDeployment ---

/** Write `content` to a temporary local.json, load it, clean up. */
function loadFrom(content: string): Deployment {
  const dir = mkdtempSync(join(tmpdir(), "agent-config-test-"));
  try {
    const file = join(dir, "local.json");
    writeFileSync(file, content);
    return loadDeployment(file);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Assert that `fn` throws a ConfigError whose message matches `pattern`. */
function throwsConfig(fn: () => unknown, pattern: RegExp) {
  assert.throws(fn, (err: unknown) => {
    assert.ok(err instanceof ConfigError);
    assert.match(err.message, pattern);
    return true;
  });
}

test("loadDeployment reads a valid file", () => {
  assert.deepEqual(loadFrom(JSON.stringify(deployment)), deployment);
});

test("loadDeployment: a missing file is a ConfigError", () => {
  throwsConfig(() => loadDeployment("/nonexistent/local.json"), /Cannot read/);
});

test("loadDeployment: broken JSON is a ConfigError", () => {
  throwsConfig(() => loadFrom("{ not json"), /not valid JSON/);
});

test("loadDeployment: a missing roles.agent is a ConfigError that names the field", () => {
  const { agent: _agent, ...roles } = deployment.roles;
  throwsConfig(() => loadFrom(JSON.stringify({ ...deployment, roles })), /roles\.agent/);
});

test("loadDeployment: a malformed address is a ConfigError that names the field", () => {
  throwsConfig(() => loadFrom(JSON.stringify({ ...deployment, vault: "0x1234" })), /vault/);
  const tokens = [{ ...MOCK_TOKEN, address: "MOCK" }];
  throwsConfig(() => loadFrom(JSON.stringify({ ...deployment, tokens })), /tokens\.0\.address/);
});

test("loadDeployment: wrong types are a ConfigError", () => {
  const tokens = [{ ...MOCK_TOKEN, decimals: "18" }];
  throwsConfig(() => loadFrom(JSON.stringify({ ...deployment, tokens })), /tokens\.0\.decimals/);
  throwsConfig(() => loadFrom("[]"), /invalid/);
});

test("loadDeployment: the hint names the network's own fix", () => {
  throwsConfig(() => loadDeployment("/nonexistent/local.json"), /local-dev\.sh/);
  throwsConfig(() => loadDeployment("/nonexistent/sepolia.json", "sepolia"), /restore it with git/);
});

test("loadDeployment reads a file without rpcUrl and with deployBlock", () => {
  const { rpcUrl: _rpcUrl, ...rest } = deployment;
  const withBlock = { ...rest, deployBlock: 12_345 };
  assert.deepEqual(loadFrom(JSON.stringify(withBlock)), withBlock);
  throwsConfig(() => loadFrom(JSON.stringify({ ...rest, deployBlock: -1 })), /deployBlock/);
});

// --- resolveNetwork ---

test("resolveNetwork: unset or empty means local", () => {
  assert.equal(resolveNetwork(undefined), "local");
  assert.equal(resolveNetwork(""), "local");
});

test("resolveNetwork accepts local and sepolia", () => {
  assert.equal(resolveNetwork("local"), "local");
  assert.equal(resolveNetwork("sepolia"), "sepolia");
});

test("resolveNetwork refuses any other value and lists the allowed ones", () => {
  throwsConfig(() => resolveNetwork("mainnet"), /local, sepolia/);
  throwsConfig(() => resolveNetwork("Sepolia"), /local, sepolia/);
});

// --- createClients ---

// Anvil account #9: a public test key, not a secret.
const TEST_KEY = "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";
const TEST_AGENT = privateKeyToAccount(TEST_KEY).address;
const TEST_RPC = "https://sepolia.example/v2/secret-provider-key";

const { rpcUrl: _localRpc, ...withoutRpc } = deployment;
const sepoliaDeployment: Deployment = {
  ...withoutRpc,
  chainId: sepolia.id,
  deployBlock: 1,
  roles: { ...deployment.roles, agent: TEST_AGENT },
};
const sepoliaEnv = { RPC_URL_SEPOLIA: TEST_RPC, AGENT_PRIVATE_KEY: TEST_KEY };

test("createClients local signs with Anvil account #5 and ignores the environment", () => {
  const { account } = createClients(deployment, "local", sepoliaEnv);
  assert.equal(account.address, deployment.roles.agent);
});

test("createClients sepolia signs with AGENT_PRIVATE_KEY, with or without 0x", () => {
  assert.equal(createClients(sepoliaDeployment, "sepolia", sepoliaEnv).account.address, TEST_AGENT);
  const bare = { ...sepoliaEnv, AGENT_PRIVATE_KEY: TEST_KEY.slice(2) };
  assert.equal(createClients(sepoliaDeployment, "sepolia", bare).account.address, TEST_AGENT);
});

test("createClients sepolia: a missing RPC_URL_SEPOLIA or AGENT_PRIVATE_KEY is a ConfigError", () => {
  throwsConfig(() => createClients(sepoliaDeployment, "sepolia", { AGENT_PRIVATE_KEY: TEST_KEY }), /RPC_URL_SEPOLIA/);
  throwsConfig(() => createClients(sepoliaDeployment, "sepolia", { RPC_URL_SEPOLIA: TEST_RPC }), /AGENT_PRIVATE_KEY/);
});

test("createClients sepolia: a malformed key is a ConfigError that does not echo the key", () => {
  for (const bad of ["0xnot-a-key-but-a-secret", "0x1234", `${TEST_KEY}00`, `0x${"0".repeat(64)}`]) {
    assert.throws(
      () => createClients(sepoliaDeployment, "sepolia", { ...sepoliaEnv, AGENT_PRIVATE_KEY: bad }),
      (err: unknown) => {
        assert.ok(err instanceof ConfigError);
        assert.match(err.message, /AGENT_PRIVATE_KEY/);
        assert.ok(!err.message.includes(bad.slice(2)), "message must not contain the key");
        return true;
      },
    );
  }
});

test("createClients sepolia: a key that is not roles.agent is a ConfigError", () => {
  const other = { ...sepoliaDeployment, roles: { ...sepoliaDeployment.roles, agent: deployment.roles.admin } };
  throwsConfig(() => createClients(other, "sepolia", sepoliaEnv), /roles\.agent.*AGENT_ROLE/);
});

test("createClients: a deployment for another chain is a ConfigError", () => {
  throwsConfig(() => createClients(deployment, "sepolia", sepoliaEnv), /chain 31337.*chain 11155111/);
  throwsConfig(() => createClients(sepoliaDeployment, "local"), /chain 11155111.*chain 31337/);
});

test("createClients: no error message contains the RPC URL", () => {
  const cases = [
    () => createClients(deployment, "sepolia", sepoliaEnv),
    () => createClients(sepoliaDeployment, "sepolia", { RPC_URL_SEPOLIA: TEST_RPC }),
    () => createClients(sepoliaDeployment, "sepolia", { ...sepoliaEnv, AGENT_PRIVATE_KEY: "0x1234" }),
  ];
  for (const fn of cases) {
    assert.throws(fn, (err: unknown) => {
      assert.ok(err instanceof ConfigError);
      assert.ok(!err.message.includes("secret-provider-key"));
      return true;
    });
  }
});

// --- deployments/sepolia.json (committed) ---

test("the committed deployments/sepolia.json is valid and for Sepolia", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const committed = loadDeployment(resolve(here, "../../deployments/sepolia.json"), "sepolia");
  assert.equal(committed.chainId, sepolia.id);
  assert.equal(committed.rpcUrl, undefined, "the Sepolia RPC URL belongs in RPC_URL_SEPOLIA");
  assert.ok(committed.deployBlock !== undefined && committed.deployBlock > 0);
  assert.deepEqual(
    committed.counterparties.map((cp) => cp.name),
    ["cp1", "cp2", "cp3"],
  );
});
