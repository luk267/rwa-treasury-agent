// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

/// @dev Properties of a single executeTransfer call that must hold for every amount and cap,
///      not only for the values the unit tests pick.
contract TreasuryVaultFuzzTest is Test {
    uint256 constant UNLIMITED = type(uint256).max;
    uint256 constant FUNDING = 1_000_000e18;
    uint256 constant SPENT = 1000e18;
    uint256 constant CP_CAP = 5000e18;
    uint256 constant ASSET_CAP = 8000e18;

    address cp1 = makeAddr("cp1");
    address cp2 = makeAddr("cp2");
    /// @dev Verified by the issuer, never whitelisted.
    address outsider = makeAddr("outsider");
    /// @dev Whitelisted without limits, but not verified by the issuer.
    address unverified = makeAddr("unverified");

    TreasuryVault vault;
    MockERC3643 token;
    /// @dev Held by the vault, never allowed.
    MockERC3643 foreign;

    function setUp() public {
        vault = new TreasuryVault(1 days, address(this), address(this), address(this), address(this));
        token = _newFundedToken();
        foreign = _newFundedToken();

        vault.setAssetConfig(address(token), true, UNLIMITED);
        vault.addCounterparty(cp1);
        vault.addCounterparty(cp2);
        vault.addCounterparty(unverified);
        // cp1's cap is set in each test.
        vault.setCounterpartyDailyCap(cp2, address(token), UNLIMITED);
        vault.setCounterpartyDailyCap(unverified, address(token), UNLIMITED);
        // A cap for the outsider, so only gate 2 can stop it.
        vault.setCounterpartyDailyCap(outsider, address(token), UNLIMITED);
    }

    /// @dev This contract is the issuer: it verifies the vault and the counterparties (not
    ///      `unverified`) and moves the whole supply into the vault.
    function _newFundedToken() internal returns (MockERC3643 t) {
        t = new MockERC3643();
        t.setVerified(address(vault), true);
        t.setVerified(cp1, true);
        t.setVerified(cp2, true);
        t.setVerified(outsider, true);
        assertTrue(t.transfer(address(vault), FUNDING));
    }

    function _execute(address to, uint256 amount) internal {
        (bool executed,,) = vault.executeTransfer(address(token), to, amount);
        assertTrue(executed, "setup transfer should execute");
    }

    // ── Cap boundary ─────────────────────────────────────────────────

    /// @dev For any cap and any first transfer that fits, a second transfer executes exactly when
    ///      it fits into what is left. Then the rest of the cap still fits and one more wei does not.
    function testFuzz_dailyCap_boundary(uint256 cap, uint256 first, uint256 second) external {
        cap = bound(cap, 1, FUNDING / 2);
        first = bound(first, 1, cap);
        uint256 left = cap - first;
        // Up to twice what is left, so about half the inputs fit and half do not.
        second = bound(second, 1, 2 * left + 1);
        vault.setCounterpartyDailyCap(cp1, address(token), cap);

        (bool firstExecuted,,) = vault.executeTransfer(address(token), cp1, first);
        assertTrue(firstExecuted, "first transfer fits the cap");

        bool fits = second <= left;
        (bool secondExecuted, TreasuryVault.RejectReason reason,) = vault.executeTransfer(address(token), cp1, second);
        assertEq(secondExecuted, fits, "second transfer executes exactly when it fits");
        if (!fits) assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.DailyCapExceeded));

        uint256 spent = first + (fits ? second : 0);
        assertEq(vault.spentToday(cp1, address(token)), spent, "counter holds what was executed");

        // The exact edge: the rest of the cap fits, one more wei does not.
        if (spent < cap) {
            (bool restExecuted,,) = vault.executeTransfer(address(token), cp1, cap - spent);
            assertTrue(restExecuted, "the rest of the cap fits");
        }
        (bool overExecuted, TreasuryVault.RejectReason overReason,) = vault.executeTransfer(address(token), cp1, 1);
        assertFalse(overExecuted, "one wei above the cap is rejected");
        assertEq(uint8(overReason), uint8(TreasuryVault.RejectReason.DailyCapExceeded));
        assertEq(vault.spentToday(cp1, address(token)), cap, "the cap is used up exactly");
    }

    // ── Rejections ───────────────────────────────────────────────────

    /// @dev Whatever the amount, a transfer that a gate refuses moves no tokens and leaves both
    ///      daily counters where they were. Each of the five gates refuses once, after earlier
    ///      transfers today, so the counters have something to lose.
    ///      The amount stops 2 * SPENT below the maximum: above that it does not fit even under
    ///      an unlimited cap (type(uint256).max minus today's spending), and gate 4 would refuse
    ///      before gate 5 is reached. testFuzz_anyAmount_neverPanics covers that range.
    function testFuzz_rejected_changesNothing(uint256 amount) external {
        amount = bound(amount, 1, UNLIMITED - 2 * SPENT);
        vault.setCounterpartyDailyCap(cp1, address(token), SPENT);
        _execute(cp1, SPENT); // cp1 has no room left today
        _execute(cp2, SPENT);

        _assertRejectedWithoutEffect(address(foreign), cp2, amount, TreasuryVault.RejectReason.AssetNotAllowed);
        _assertRejectedWithoutEffect(address(token), outsider, amount, TreasuryVault.RejectReason.NotWhitelisted);
        _assertRejectedWithoutEffect(address(token), cp1, amount, TreasuryVault.RejectReason.DailyCapExceeded);
        _assertRejectedWithoutEffect(address(token), unverified, amount, TreasuryVault.RejectReason.ERC3643Compliance);

        // No room left for the token over all counterparties.
        vault.setAssetConfig(address(token), true, vault.assetSpentToday(address(token)));
        _assertRejectedWithoutEffect(address(token), cp2, amount, TreasuryVault.RejectReason.AssetDailyCapExceeded);
    }

    function _assertRejectedWithoutEffect(address t, address to, uint256 amount, TreasuryVault.RejectReason expected)
        internal
    {
        uint256 vaultBalance = IERC20(t).balanceOf(address(vault));
        uint256 toBalance = IERC20(t).balanceOf(to);
        uint256 spent = vault.spentToday(to, t);
        uint256 assetSpent = vault.assetSpentToday(t);

        (bool executed, TreasuryVault.RejectReason reason,) = vault.executeTransfer(t, to, amount);

        assertFalse(executed, "transfer was executed");
        assertEq(uint8(reason), uint8(expected), "wrong gate");
        assertEq(IERC20(t).balanceOf(address(vault)), vaultBalance, "vault balance changed");
        assertEq(IERC20(t).balanceOf(to), toBalance, "recipient balance changed");
        assertEq(vault.spentToday(to, t), spent, "counterparty counter changed");
        assertEq(vault.assetSpentToday(t), assetSpent, "token counter changed");
    }

    // ── Any amount ───────────────────────────────────────────────────

    /// @dev No amount makes executeTransfer panic, also when the counters are not zero and
    ///      `spent + amount` would overflow. Zero reverts with ZeroAmount. Any other amount
    ///      executes if it fits, or is rejected by the first gate it does not fit. Three paths,
    ///      each from the same state: a finite counterparty cap, a finite token cap, no cap at all.
    function testFuzz_anyAmount_neverPanics(uint256 amount) external {
        vault.setCounterpartyDailyCap(cp1, address(token), CP_CAP);
        vault.setAssetConfig(address(token), true, ASSET_CAP);
        _execute(cp1, SPENT);
        _execute(cp2, SPENT);

        if (amount == 0) {
            vm.expectRevert(TreasuryVault.ZeroAmount.selector);
            vault.executeTransfer(address(token), cp1, amount);
            return;
        }

        uint256 start = vm.snapshotState();
        // cp1 has a finite cap of its own.
        _assertOutcome(cp1, amount);

        vm.revertToState(start);
        // cp2 has no limit of its own; the token cap is finite.
        _assertOutcome(cp2, amount);

        vm.revertToState(start);
        // No finite cap at all; for most amounts the token's balance check decides.
        vault.setAssetConfig(address(token), true, UNLIMITED);
        _assertOutcome(cp2, amount);
    }

    /// @dev Expects the first gate the amount does not fit, in the vault's order: what is left of
    ///      the counterparty cap, what is left of the token cap, the vault's balance. "Unlimited"
    ///      is type(uint256).max, so what is left of it is max minus today's spending. A revert,
    ///      a panic included, fails the test.
    function _assertOutcome(address to, uint256 amount) internal {
        uint256 counterpartyRoom =
            vault.getCounterpartyDailyCap(to, address(token)) - vault.spentToday(to, address(token));
        uint256 tokenRoom = vault.getAssetConfig(address(token)).dailyOutflowCap - vault.assetSpentToday(address(token));
        uint256 balance = token.balanceOf(address(vault));

        (bool executed, TreasuryVault.RejectReason reason,) = vault.executeTransfer(address(token), to, amount);

        if (amount > counterpartyRoom) {
            assertFalse(executed, "executed above the counterparty cap");
            assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.DailyCapExceeded));
        } else if (amount > tokenRoom) {
            assertFalse(executed, "executed above the token cap");
            assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.AssetDailyCapExceeded));
        } else if (amount > balance) {
            assertFalse(executed, "executed above the vault's balance");
            assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.ERC3643Compliance));
        } else {
            assertTrue(executed, "an amount that fits everywhere was rejected");
        }
    }
}
