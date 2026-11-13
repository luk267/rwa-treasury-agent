// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title IERC3643
/// @notice Minimal ERC-20 subset of the ERC-3643 token interface.
/// @dev See https://eips.ethereum.org/EIPS/eip-3643. The vault calls only `transfer`.
///      The off-chain agent reads `balanceOf`. `transferFrom` is currently unused.

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
