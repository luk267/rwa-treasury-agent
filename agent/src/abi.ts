// ABI fragments needed by the agent tools. Hand-curated from TreasuryVault.sol
// and IERC3643.sol - keep in sync if those contract surfaces change.

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
    outputs: [],
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

// Mirrors the RejectReason enum in TreasuryVault.sol. Index = uint8 value emitted
// in the TransferRejected event.
export const REJECT_REASON = [
  "None",
  "Paused",
  "NotWhitelisted",
  "ExposureCapExceeded",
  "DailyCapExceeded",
  "ERC3643Compliance",
] as const;

export type RejectReasonName = (typeof REJECT_REASON)[number];
