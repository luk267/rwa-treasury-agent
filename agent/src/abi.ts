// ABI fragments needed by the agent tools. Hand-curated from TreasuryVault.sol
// (plus ERC-20 balanceOf and the token errors) - keep in sync if the vault changes.

export const VAULT_ABI = [
  {
    type: "function",
    name: "executeTransfer",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [
      { name: "executed", type: "bool" },
      { name: "reason", type: "uint8" },
      { name: "detail", type: "bytes" },
    ],
  },
  {
    type: "function",
    name: "getAssetConfig",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "allowed", type: "bool" },
          { name: "dailyOutflowCap", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "assetSpentToday",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getCounterparty",
    stateMutability: "view",
    inputs: [{ name: "cp", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "active", type: "bool" },
          { name: "addedAt", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getCounterpartyDailyCap",
    stateMutability: "view",
    inputs: [
      { name: "cp", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "spentToday",
    stateMutability: "view",
    inputs: [
      { name: "cp", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "event",
    name: "TransferExecuted",
    inputs: [
      { name: "token", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "by", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "TransferRejected",
    inputs: [
      { name: "token", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "reason", type: "uint8", indexed: false },
      { name: "detail", type: "bytes", indexed: false },
    ],
  },
  {
    type: "error",
    name: "VaultPaused",
    inputs: [],
  },
  {
    type: "error",
    name: "ZeroAmount",
    inputs: [],
  },
  {
    type: "error",
    name: "TokenTransferFailedWithoutReason",
    inputs: [{ name: "token", type: "address" }],
  },
  {
    type: "error",
    name: "ReentrancyGuardReentrantCall",
    inputs: [],
  },
  {
    type: "error",
    name: "AccessControlUnauthorizedAccount",
    inputs: [
      { name: "account", type: "address" },
      { name: "neededRole", type: "bytes32" },
    ],
  },
] as const;

export const IERC3643_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// Errors an ERC-3643 (T-REX v5) token reverts with on transfer. The vault catches
// the revert and forwards the raw bytes as `detail` in TransferRejected and in its
// return value; this ABI
// lets the agent decode them. Error(string) and Panic(uint256) are built into viem.
export const TOKEN_ERRORS_ABI = [
  { type: "error", name: "UnverifiedIdentity", inputs: [] },
  { type: "error", name: "ComplianceNotFollowed", inputs: [] },
  {
    type: "error",
    name: "FrozenWallet",
    inputs: [{ name: "wallet", type: "address" }],
  },
  { type: "error", name: "EnforcedPause", inputs: [] },
  {
    type: "error",
    name: "ERC20InsufficientBalance",
    inputs: [
      { name: "sender", type: "address" },
      { name: "balance", type: "uint256" },
      { name: "needed", type: "uint256" },
    ],
  },
] as const;

// Mirrors the RejectReason enum in TreasuryVault.sol. Index = uint8 value emitted
// in the TransferRejected event and returned by executeTransfer.
export const REJECT_REASON = [
  "None",
  "AssetNotAllowed",
  "NotWhitelisted",
  "DailyCapExceeded",
  "AssetDailyCapExceeded",
  "ERC3643Compliance",
] as const;

export type RejectReasonName = (typeof REJECT_REASON)[number];
