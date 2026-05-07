// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

contract TreasuryVaultERC3643ComplianceTest is Test {
    address cp1 = makeAddr("cp1");

    uint256 constant DAILY_CAP = 10_000e18;

    TreasuryVault vault;
    MockERC3643 token;

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );

    function setUp() public {
        vault = new TreasuryVault();
        token = new MockERC3643();
        token.transfer(address(vault), 100_000e18);
        vault.addCounterparty(cp1, DAILY_CAP);
    }

    /// @dev When the ERC-3643 token rejects the transfer (e.g. missing KYC claim),
    ///      the vault must NOT revert. Instead it emits TransferRejected with the
    ///      revert reason from the token so the agent can read it.
    function test_executeTransfer_erc3643Rejects_emitsRejectedWithReason() external {
        // Disable compliance on the mock - simulates a KYC/identity failure
        token.setCompliantTransfersEnabled(false);

        // Build the expected revert reason: MockComplianceBlock(cp1, 500e18)
        bytes memory expectedReason = abi.encodeWithSelector(
            MockERC3643.MockComplianceBlock.selector, cp1, 500e18
        );

        vm.expectEmit();
        emit TransferRejected(
            address(token), cp1, 500e18, TreasuryVault.RejectReason.ERC3643Compliance, expectedReason
        );
        vault.executeTransfer(address(token), cp1, 500e18);
    }

    /// @dev After an ERC-3643 rejection, no tokens should have moved.
    function test_executeTransfer_erc3643Rejects_noTokensMoved() external {
        uint256 vaultBalanceBefore = token.balanceOf(address(vault));
        uint256 cp1BalanceBefore = token.balanceOf(cp1);

        token.setCompliantTransfersEnabled(false);
        vault.executeTransfer(address(token), cp1, 500e18);

        assertEq(token.balanceOf(address(vault)), vaultBalanceBefore, "vault balance should be unchanged");
        assertEq(token.balanceOf(cp1), cp1BalanceBefore, "cp1 balance should be unchanged");
    }

    /// @dev After an ERC-3643 rejection, the daily cap must NOT be consumed.
    ///      Otherwise the agent loses budget for a transfer that never happened.
    function test_executeTransfer_erc3643Rejects_dailyCapNotConsumed() external {
        // First: fail a 500-token transfer
        token.setCompliantTransfersEnabled(false);
        vault.executeTransfer(address(token), cp1, 500e18);

        // Re-enable compliance
        token.setCompliantTransfersEnabled(true);

        // Now transfer the full daily cap - this should succeed because the
        // failed transfer must not have consumed any cap budget.
        vault.executeTransfer(address(token), cp1, DAILY_CAP);
        assertEq(token.balanceOf(cp1), DAILY_CAP);
    }

    /// @dev A successful transfer after a previous success should still work
    ///      (sanity check that try/catch doesn't break the happy path).
    function test_executeTransfer_happyPath_stillWorks() external {
        vm.expectEmit();
        emit TransferExecuted(address(token), cp1, 500e18, address(this));
        vault.executeTransfer(address(token), cp1, 500e18);

        assertEq(token.balanceOf(cp1), 500e18);
    }
}
