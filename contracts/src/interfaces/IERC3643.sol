// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IERC3643
/// @notice Minimal subset of the ERC-3643 token interface used by the Treasury Vault.
/// @dev See https://eips.ethereum.org/EIPS/eip-3643. It intentionally includes only
///      the three functions the vault calls: transfer, transferFrom, balanceOf.

interface IERC3643 {
    /// @notice Transfer `amount` tokens to `to`.
    /// @param to The recipient address.
    /// @param amount The amount to transfer (in wei units).
    /// @return success True if the transfer succeeded.
    function transfer(address to, uint256 amount) external returns (bool success);

    /// @notice Move `amount` tokens from `from` to `to` using the caller's allowance.
    /// @param from The source address.
    /// @param to The recipient address.
    /// @param amount The amount to transfer.
    /// @return success True if the transfer succeeded.
    function transferFrom(address from, address to, uint256 amount) external returns (bool success);

    /// @notice Read the token balance of `account`.
    /// @param account The address to query.
    /// @return The number of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256);
}
