// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title EmptyRevertToken
/// @notice Test-only token whose `transfer` reverts without any revert data.
/// @dev Looks the same to the caller as an out-of-gas inside the token: no reason at all.
contract EmptyRevertToken {
    /// @notice Always reverts with empty data.
    function transfer(address, uint256) external pure returns (bool) {
        revert();
    }
}
