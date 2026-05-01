// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";

contract TreasuryVaultWhitelistTest is Test {
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    address alice = makeAddr("alice");
    address cp1 = makeAddr("cp1");
    address unknown = makeAddr("unknown");

    uint256 constant DAILY_CAP = 1000;
    address constant TOKEN = address(0xbeef);

    TreasuryVault vault;

    // Mirror events from TreasuryVault for vm.expectEmit
    event CounterpartyAdded(address indexed counterparty, uint256 dailyCap);
    event CounterpartyDeactivated(address indexed counterparty);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );

    function setUp() public {
        vault = new TreasuryVault();
        vault.addCounterparty(alice, type(uint256).max); // alice as CP for executeTransfer happy-path
    }

    function test_addCounterparty_byTreasurer_emitsAndStoresActive() external {
        vm.expectEmit();
        emit CounterpartyAdded(cp1, DAILY_CAP);
        vault.addCounterparty(cp1, DAILY_CAP);

        TreasuryVault.Counterparty memory cp = vault.getCounterparty(cp1);
        assertTrue(cp.active, "should be active");
        assertEq(cp.dailyCap, DAILY_CAP, "dailyCap mismatch");
        assertGt(cp.addedAt, 0, "addedAt not set");
    }

    function test_addCounterparty_byNonTreasurer_reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, TREASURER_ROLE)
        );
        vault.addCounterparty(cp1, DAILY_CAP);
    }

    function test_addCounterparty_zeroAddress_reverts() external {
        vm.expectRevert(TreasuryVault.InvalidCounterparty.selector);
        vault.addCounterparty(address(0), DAILY_CAP);
    }

    function test_addCounterparty_alreadyActive_reverts() external {
        vault.addCounterparty(cp1, DAILY_CAP);
        vm.expectRevert(TreasuryVault.CounterpartyAlreadyActive.selector);
        vault.addCounterparty(cp1, DAILY_CAP);
    }

    function test_deactivateCounterparty_setsInactive_emitsEvent() external {
        vault.addCounterparty(cp1, DAILY_CAP);
        vm.expectEmit();
        emit CounterpartyDeactivated(cp1);
        vault.deactivateCounterparty(cp1);
        TreasuryVault.Counterparty memory cp = vault.getCounterparty(cp1);
        assertFalse(cp.active, "should be inactive");
    }

    function test_deactivateCounterparty_keepsAddedAt() external {
        vault.addCounterparty(cp1, DAILY_CAP);
        uint256 originalAddedAt = vault.getCounterparty(cp1).addedAt;
        vault.deactivateCounterparty(cp1);
        TreasuryVault.Counterparty memory cp = vault.getCounterparty(cp1);
        assertEq(cp.addedAt, originalAddedAt, "addedAt must persist for audit trail");
        assertEq(cp.dailyCap, DAILY_CAP, "dailyCap should persist too");
    }

    /// @dev KEY TEST: vault must NOT revert on rejected transfer.
    ///      Agent reads the TransferRejected event off-chain to know what happened.
    function test_executeTransfer_toUnknownCounterparty_emitsRejected_noRevert() external {
        vm.expectEmit();
        emit TransferRejected(TOKEN, unknown, 100, TreasuryVault.RejectReason.NotWhitelisted, "");
        vault.executeTransfer(TOKEN, unknown, 100);
        // If we reach this line, the no-revert design is correct.
    }

    function test_executeTransfer_toDeactivatedCounterparty_emitsRejected() external {
        vault.addCounterparty(cp1, DAILY_CAP);
        vault.deactivateCounterparty(cp1);
        vm.expectEmit();
        emit TransferRejected(TOKEN, cp1, 100, TreasuryVault.RejectReason.NotWhitelisted, "");
        vault.executeTransfer(TOKEN, cp1, 100);
    }
}
