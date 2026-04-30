// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC3643
/// @notice Test-only ERC-20 with a toggle to simulate ERC-3643 compliance reverts.
/// @dev Used by the Treasury Vault unit tests. NOT production-grade: no access
///      control on `setCompliantTransfersEnabled` so tests can flip the flag freely.

contract MockERC3643 is ERC20 {
    bool public compliantTransfersEnabled = true;

    error MockComplianceBlock(address to, uint256 amount);

    constructor() ERC20("Mock RWA", "MOCK") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /// @notice Toggle compliance behavior. Mock-only: no access control on purpose.
    function setCompliantTransfersEnabled(bool enabled) external {
        compliantTransfersEnabled = enabled;
    }

    /// @dev Reverts with MockComplianceBlock if compliance is disabled, otherwise delegates to ERC20.
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!compliantTransfersEnabled) revert MockComplianceBlock(to, amount);
        return super.transfer(to, amount);
    }

    /// @dev Reverts with MockComplianceBlock if compliance is disabled, otherwise delegates to ERC20.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!compliantTransfersEnabled) revert MockComplianceBlock(to, amount);
        return super.transferFrom(from, to, amount);
    }
}

