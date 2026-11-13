// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title FalseReturnToken
/// @notice Test-only token whose `transfer` returns false instead of reverting.
/// @dev Plain ERC-20 allows this. T-REX never does it: it reverts with a reason.
contract FalseReturnToken {
    /// @notice Always reports failure without a reason.
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
