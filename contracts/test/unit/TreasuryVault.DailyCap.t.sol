// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

contract TreasuryVaultDailyCapTest is Test {
    address cp1 = makeAddr("cp1");

    uint256 constant DAILY_CAP = 1000e18;

    TreasuryVault vault;
    MockERC3643 token;

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );

    function setUp() public {
        vault = new TreasuryVault();
        token = new MockERC3643();

        // Fund the vault so transfers can actually move tokens
        token.transfer(address(vault), 100_000e18);

        // Whitelist cp1 with a daily cap of 1000 tokens
        vault.addCounterparty(cp1, DAILY_CAP);
    }

    /// @dev A single transfer under the daily cap should succeed.
    function test_executeTransfer_underDailyCap_succeeds() external {
        vm.expectEmit();
        emit TransferExecuted(address(token), cp1, 500e18, address(this));
        vault.executeTransfer(address(token), cp1, 500e18);
    }

    /// @dev Two transfers that together stay under the daily cap should both succeed.
    function test_executeTransfer_twoTransfers_underDailyCap_bothSucceed() external {
        vault.executeTransfer(address(token), cp1, 400e18);
        vault.executeTransfer(address(token), cp1, 400e18);

        // 800 total, under 1000 cap - both should have gone through
        assertEq(token.balanceOf(cp1), 800e18);
    }

    /// @dev A transfer that would exceed the daily cap is rejected (not reverted).
    function test_executeTransfer_exceedsDailyCap_emitsRejected() external {
        vault.executeTransfer(address(token), cp1, 600e18);

        // Second transfer: 600 + 500 = 1100 > 1000 cap
        vm.expectEmit();
        emit TransferRejected(
            address(token), cp1, 500e18, TreasuryVault.RejectReason.DailyCapExceeded, ""
        );
        vault.executeTransfer(address(token), cp1, 500e18);

        // Only the first 600 should have arrived
        assertEq(token.balanceOf(cp1), 600e18);
    }

    /// @dev A single transfer exactly at the daily cap should succeed.
    function test_executeTransfer_exactlyAtDailyCap_succeeds() external {
        vault.executeTransfer(address(token), cp1, DAILY_CAP);
        assertEq(token.balanceOf(cp1), DAILY_CAP);
    }

    /// @dev After a day passes, the daily cap resets and transfers succeed again.
    function test_executeTransfer_afterDayReset_capRefreshes() external {
        // Max out the daily cap
        vault.executeTransfer(address(token), cp1, DAILY_CAP);
        assertEq(token.balanceOf(cp1), DAILY_CAP);

        // This should be rejected - cap is full
        vm.expectEmit();
        emit TransferRejected(
            address(token), cp1, 100e18, TreasuryVault.RejectReason.DailyCapExceeded, ""
        );
        vault.executeTransfer(address(token), cp1, 100e18);

        // Fast-forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Now it should work again - new day bucket
        vault.executeTransfer(address(token), cp1, 500e18);
        assertEq(token.balanceOf(cp1), DAILY_CAP + 500e18);
    }
}
