import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { REJECT_REASON, VAULT_ABI } from "./abi.js";

// The vault as Foundry compiled it. contracts/out is not committed, so `forge build`
// must run in contracts/ first. CI does that before `npm test`.
const here = dirname(fileURLToPath(import.meta.url));
const ARTIFACT = resolve(here, "../../contracts/out/TreasuryVault.sol/TreasuryVault.json");

type Json = Record<string, unknown>;

function isRecord(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function loadArtifact(): { abi: unknown[]; ast: unknown } {
  if (!existsSync(ARTIFACT)) {
    throw new Error(`${ARTIFACT} is missing. Run \`forge build\` in contracts/ first.`);
  }
  const parsed: unknown = JSON.parse(readFileSync(ARTIFACT, "utf8"));
  if (!isRecord(parsed) || !Array.isArray(parsed.abi)) {
    throw new Error(`${ARTIFACT} has no ABI.`);
  }
  if (!isRecord(parsed.ast)) {
    throw new Error(`${ARTIFACT} has no AST. Set ast = true in contracts/foundry.toml and rebuild.`);
  }
  return { abi: parsed.abi, ast: parsed.ast };
}

// Drop what the compiler adds and the hand-written ABI leaves out: internalType
// (for example "enum TreasuryVault.RejectReason" for a uint8) and anonymous: false.
function normalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalize);
  if (!isRecord(value)) return value;
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key, v]) => key !== "internalType" && !(key === "anonymous" && v === false))
      .map(([key, v]) => [key, normalize(v)]),
  );
}

function findEnumMembers(node: unknown, name: string): string[] | undefined {
  const children = Array.isArray(node) ? node : isRecord(node) ? Object.values(node) : [];
  if (isRecord(node) && node.nodeType === "EnumDefinition" && node.name === name) {
    const members = Array.isArray(node.members) ? node.members : [];
    return members.map((member) => (isRecord(member) ? String(member.name) : ""));
  }
  for (const child of children) {
    const found = findEnumMembers(child, name);
    if (found) return found;
  }
  return undefined;
}

test("every VAULT_ABI entry matches the compiled vault", () => {
  const compiled = loadArtifact().abi.map(normalize);
  for (const entry of VAULT_ABI) {
    const label = `${entry.type} ${entry.name}`;
    const match = compiled.find(
      (item) => isRecord(item) && item.type === entry.type && item.name === entry.name,
    );
    assert.ok(match, `${label} is not in the compiled vault`);
    assert.deepEqual(normalize(entry), match, `${label} differs from the compiled vault`);
  }
});

test("REJECT_REASON matches enum RejectReason of the compiled vault", () => {
  const members = findEnumMembers(loadArtifact().ast, "RejectReason");
  assert.ok(members, "enum RejectReason is not in the compiled vault");
  assert.deepEqual([...REJECT_REASON], members);
});
