// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title IERC3643
/// @notice The part of the ERC-3643 token interface that the vault calls.
/// @dev See https://eips.ethereum.org/EIPS/eip-3643. The vault calls only `transfer`.
///      A T-REX token reverts with a reason when a transfer is not allowed.

interface IERC3643 {
    /// @notice Transfer `amount` tokens to `to`.
    /// @param to The recipient address.
    /// @param amount The amount to transfer (in wei units).
    /// @return success True if the transfer succeeded.
    function transfer(address to, uint256 amount) external returns (bool success);
}
