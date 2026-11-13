import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeErrorResult } from "viem";
import { TOKEN_ERRORS_ABI } from "./abi.js";
import { decodeDetail, describeRejection } from "./outcome.js";

const WALLET = "0x90F79bf6EB2c4f870365E785982E1f101E93b906";
const ERROR_STRING_ABI = [
  { type: "error", name: "Error", inputs: [{ name: "message", type: "string" }] },
] as const;

test("decodes Error(string)", () => {
  const data = encodeErrorResult({
    abi: ERROR_STRING_ABI,
    errorName: "Error",
    args: ["Transfer not possible"],
  });
  assert.equal(decodeDetail(data).decoded, 'Error("Transfer not possible")');
});

test("decodes UnverifiedIdentity()", () => {
  const data = encodeErrorResult({ abi: TOKEN_ERRORS_ABI, errorName: "UnverifiedIdentity" });
  const result = decodeDetail(data);
  assert.equal(result.decoded, "UnverifiedIdentity()");
  assert.equal(result.raw, data);
});

test("decodes FrozenWallet(address)", () => {
  const data = encodeErrorResult({
    abi: TOKEN_ERRORS_ABI,
    errorName: "FrozenWallet",
    args: [WALLET],
  });
  assert.equal(decodeDetail(data).decoded, `FrozenWallet(${WALLET})`);
});

test("empty data gives null and a note", () => {
  const result = decodeDetail("0x");
  assert.equal(result.decoded, null);
  assert.ok(result.note);
});

test("unknown selector gives null and a note", () => {
  const result = decodeDetail("0xdeadbeef");
  assert.equal(result.decoded, null);
  assert.match(result.note ?? "", /0xdeadbeef/);
});

test("describeRejection omits detail for vault-level gates", () => {
  assert.deepEqual(describeRejection(4, "0x"), { reason: "DailyCapExceeded" });
});

test("describeRejection decodes detail for the ERC-3643 gate", () => {
  const data = encodeErrorResult({ abi: TOKEN_ERRORS_ABI, errorName: "UnverifiedIdentity" });
  const result = describeRejection(5, data);
  assert.equal(result.reason, "ERC3643Compliance");
  assert.equal(result.detail?.decoded, "UnverifiedIdentity()");
});
