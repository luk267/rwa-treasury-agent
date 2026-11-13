import { decodeErrorResult, type Hex } from "viem";
import { REJECT_REASON, TOKEN_ERRORS_ABI } from "./abi.js";

export interface DecodedDetail {
  raw: Hex;
  /** e.g. `UnverifiedIdentity()` or `Error("Transfer not possible")`; null if unknown. */
  decoded: string | null;
  note?: string;
}

/**
 * Decode the `detail` bytes of a TransferRejected event. They hold the revert
 * data of the token's transfer call, so they name the token-level reason.
 */
export function decodeDetail(detail: Hex): DecodedDetail {
  if (detail === "0x") {
    return {
      raw: detail,
      decoded: null,
      note: "No revert data. The token refused the transfer without giving a reason.",
    };
  }
  try {
    const { errorName, args } = decodeErrorResult({ abi: TOKEN_ERRORS_ABI, data: detail });
    const formatted = (args ?? []).map(formatArg).join(", ");
    return { raw: detail, decoded: `${errorName}(${formatted})` };
  } catch {
    return {
      raw: detail,
      decoded: null,
      note: `Unknown error selector ${detail.slice(0, 10)}. Not one of the known ERC-3643 token errors.`,
    };
  }
}

export interface Rejection {
  reason: string;
  detail?: DecodedDetail;
}

/** Map the uint8 reason and the raw detail of a TransferRejected event to tool output. */
export function describeRejection(reasonIndex: number, detail: Hex): Rejection {
  const reason = REJECT_REASON[reasonIndex] ?? `Reason${reasonIndex}`;
  // Only the ERC-3643 gate forwards token data; the vault's own gates emit "".
  if (reason === "ERC3643Compliance" || detail !== "0x") {
    return { reason, detail: decodeDetail(detail) };
  }
  return { reason };
}

function formatArg(arg: unknown): string {
  if (typeof arg === "string" && !arg.startsWith("0x")) return JSON.stringify(arg);
  return String(arg);
}
