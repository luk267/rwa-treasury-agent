// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

/// @dev Holder rules vs. issuer rights. The token's holder rules (identity, freeze, pause, balance)
///      surface in the vault as TransferRejected with the token's error in `detail`. The issuer's
///      forced transfer bypasses the vault entirely.
contract TreasuryVaultIssuerRightsTest is Test {
    address issuer = makeAddr("issuer");
    address cp1 = makeAddr("cp1");
    address cp3 = makeAddr("cp3");

    uint256 constant FUNDING = 10_000e18;
    uint256 constant DAILY_CAP = 1000e18;

    TreasuryVault vault;
    MockERC3643 token;

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );

    function setUp() public {
        vault = new TreasuryVault(1 days, address(this), address(this), address(this), address(this));

        // The issuer deploys the token and becomes its ISSUER_AGENT.
        vm.startPrank(issuer);
        token = new MockERC3643();
        token.setVerified(address(vault), true);
        token.setVerified(cp1, true);
        // cp3 stays unverified: no KYC at the issuer.
        assertTrue(token.transfer(address(vault), FUNDING));
        vm.stopPrank();

        // The vault whitelists both. Its own policy does not know about the token's identity registry.
        vault.addCounterparty(cp1, DAILY_CAP);
        vault.addCounterparty(cp3, DAILY_CAP);
    }

    function _expectTokenRejection(address to, uint256 amount, bytes memory detail) internal {
        vm.expectEmit(address(vault));
        emit TransferRejected(address(token), to, amount, TreasuryVault.RejectReason.ERC3643Compliance, detail);
    }

    // ---------- Holder rules ----------

    /// @dev A contract that holds ERC-3643 tokens needs an identity like any investor.
    function test_fundVault_unverifiedVault_reverts() external {
        TreasuryVault unverifiedVault =
            new TreasuryVault(1 days, address(this), address(this), address(this), address(this));

        vm.expectRevert(MockERC3643.UnverifiedIdentity.selector);
        vm.prank(issuer);
        token.transfer(address(unverifiedVault), 1e18);
    }

    function test_executeTransfer_recipientNotVerified_emitsRejectedWithUnverifiedIdentity() external {
        _expectTokenRejection(cp3, 100e18, abi.encodeWithSelector(MockERC3643.UnverifiedIdentity.selector));
        vault.executeTransfer(address(token), cp3, 100e18);

        assertEq(token.balanceOf(cp3), 0);
        assertEq(token.balanceOf(address(vault)), FUNDING);
    }

    function test_executeTransfer_vaultFrozen_emitsRejectedWithFrozenWallet() external {
        vm.prank(issuer);
        token.setAddressFrozen(address(vault), true);

        _expectTokenRejection(cp1, 100e18, abi.encodeWithSelector(MockERC3643.FrozenWallet.selector, address(vault)));
        vault.executeTransfer(address(token), cp1, 100e18);

        assertEq(token.balanceOf(cp1), 0);
    }

    function test_executeTransfer_tokenPaused_emitsRejectedWithEnforcedPause() external {
        vm.prank(issuer);
        token.pause();

        _expectTokenRejection(cp1, 100e18, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vault.executeTransfer(address(token), cp1, 100e18);

        assertEq(token.balanceOf(cp1), 0);
    }

    function test_executeTransfer_insufficientBalance_emitsRejected() external {
        // A counterparty without a cap, so the vault's own gates let the oversized amount through.
        address whale = makeAddr("whale");
        vault.addCounterparty(whale, type(uint256).max);
        vm.prank(issuer);
        token.setVerified(whale, true);

        uint256 amount = FUNDING + 1;
        _expectTokenRejection(
            whale,
            amount,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), FUNDING, amount)
        );
        vault.executeTransfer(address(token), whale, amount);

        assertEq(token.balanceOf(address(vault)), FUNDING);
    }

    // ---------- Issuer rights ----------

    /// @dev The issuer can move the vault's tokens to an address the vault never whitelisted.
    ///      The vault takes no part and leaves no trace in its own logs.
    function test_forcedTransfer_movesVaultTokensWithoutVaultEvent() external {
        address recipient = makeAddr("recipient");
        vm.prank(issuer);
        token.setVerified(recipient, true);

        vm.recordLogs();
        vm.prank(issuer);
        assertTrue(token.forcedTransfer(address(vault), recipient, 500e18));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0, "token should emit");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].emitter, address(vault), "vault emitted an event");
        }
        assertEq(token.balanceOf(recipient), 500e18);
        assertEq(token.balanceOf(address(vault)), FUNDING - 500e18);
        assertFalse(vault.getCounterparty(recipient).active, "recipient is not a vault counterparty");
    }

    /// @dev Daily cap and exposure cap count only what goes through executeTransfer.
    function test_forcedTransfer_doesNotTouchDailyCounters() external {
        vault.setExposureCap(address(token), DAILY_CAP);

        vm.prank(issuer);
        token.forcedTransfer(address(vault), cp1, DAILY_CAP);

        // Both caps still have their full room for the agent.
        vm.expectEmit(address(vault));
        emit TransferExecuted(address(token), cp1, DAILY_CAP, address(this));
        vault.executeTransfer(address(token), cp1, DAILY_CAP);

        assertEq(token.balanceOf(cp1), 2 * DAILY_CAP);
    }
}
