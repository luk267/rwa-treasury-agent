// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

/// @dev Not a token: `transfer` reports success and moves nothing.
contract FakeToken {
    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Token allowlist (gate 1) and the daily outflow cap per token (gate 4).
contract TreasuryVaultAssetCapTest is Test {
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    address cp1 = makeAddr("cp1");
    address cp2 = makeAddr("cp2");
    address alice = makeAddr("alice");

    uint256 constant UNLIMITED = type(uint256).max;
    uint256 constant ASSET_CAP = 5000e18;

    TreasuryVault vault;
    MockERC3643 token;

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );
    event AssetConfigSet(address indexed token, bool allowed, uint256 dailyOutflowCap);

    function setUp() public {
        vault = new TreasuryVault(1 days, address(this), address(this), address(this), address(this));
        token = _newFundedToken();

        // Max 5000 tokens of this asset per day across ALL counterparties.
        vault.setAssetConfig(address(token), true, ASSET_CAP);

        // Both counterparties have no limit of their own for this token,
        // so the asset cap is the binding constraint in these tests.
        vault.addCounterparty(cp1);
        vault.addCounterparty(cp2);
        vault.setCounterpartyDailyCap(cp1, address(token), UNLIMITED);
        vault.setCounterpartyDailyCap(cp2, address(token), UNLIMITED);
    }

    /// @dev A second ERC-3643 token held by the vault, with cp1 and cp2 verified.
    function _newFundedToken() internal returns (MockERC3643 t) {
        t = new MockERC3643();
        t.setVerified(address(vault), true);
        t.setVerified(cp1, true);
        t.setVerified(cp2, true);
        assertTrue(t.transfer(address(vault), 100_000e18));
    }

    function _expectRejected(address t, address to, uint256 amount, TreasuryVault.RejectReason reason) internal {
        vm.expectEmit(address(vault));
        emit TransferRejected(t, to, amount, reason, "");
    }

    // ── Setter ───────────────────────────────────────────────────────

    function test_setAssetConfig_byTreasurer_emitsAndStores() external {
        address other = makeAddr("other-token");
        vm.expectEmit(address(vault));
        emit AssetConfigSet(other, true, 10_000e18);
        vault.setAssetConfig(other, true, 10_000e18);

        TreasuryVault.AssetConfig memory config = vault.getAssetConfig(other);
        assertTrue(config.allowed, "should be allowed");
        assertEq(config.dailyOutflowCap, 10_000e18, "cap mismatch");
    }

    function test_setAssetConfig_byNonTreasurer_reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, TREASURER_ROLE)
        );
        vault.setAssetConfig(address(token), true, UNLIMITED);
    }

    function test_getAssetConfig_unknownToken_notAllowedAndZeroCap() external {
        TreasuryVault.AssetConfig memory config = vault.getAssetConfig(makeAddr("unknown-token"));
        assertFalse(config.allowed, "unknown token must not be allowed");
        assertEq(config.dailyOutflowCap, 0, "unknown token must have no cap");
    }

    // ── Gate 1: token allowlist ──────────────────────────────────────

    /// @dev A token the treasurer never configured is rejected, even though the vault holds it.
    function test_executeTransfer_unknownToken_emitsAssetNotAllowed() external {
        MockERC3643 unknown = _newFundedToken();

        _expectRejected(address(unknown), cp1, 100e18, TreasuryVault.RejectReason.AssetNotAllowed);
        (bool executed, TreasuryVault.RejectReason reason,) = vault.executeTransfer(address(unknown), cp1, 100e18);

        assertFalse(executed);
        assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.AssetNotAllowed));
        assertEq(unknown.balanceOf(cp1), 0);
    }

    /// @dev The treasurer can switch a token off again.
    function test_executeTransfer_disallowedToken_emitsAssetNotAllowed() external {
        vault.setAssetConfig(address(token), false, ASSET_CAP);

        _expectRejected(address(token), cp1, 100e18, TreasuryVault.RejectReason.AssetNotAllowed);
        vault.executeTransfer(address(token), cp1, 100e18);

        assertEq(token.balanceOf(cp1), 0);
    }

    /// @dev Regression for a fake token: before the allowlist, any contract whose `transfer`
    ///      returned true passed every gate and used up the counterparty's daily cap.
    function test_executeTransfer_foreignToken_doesNotConsumeCaps() external {
        vault.setCounterpartyDailyCap(cp1, address(token), 1000e18);
        FakeToken fake = new FakeToken();

        _expectRejected(address(fake), cp1, 1000e18, TreasuryVault.RejectReason.AssetNotAllowed);
        vault.executeTransfer(address(fake), cp1, 1000e18);

        assertEq(vault.spentToday(cp1, address(fake)), 0, "fake token consumed the counterparty cap");
        assertEq(vault.assetSpentToday(address(fake)), 0, "fake token consumed an asset cap");

        // The real token still has its full room.
        vm.expectEmit(address(vault));
        emit TransferExecuted(address(token), cp1, 1000e18, address(this));
        vault.executeTransfer(address(token), cp1, 1000e18);
    }

    // ── Gate 4: daily outflow cap per token ──────────────────────────

    /// @dev Default-deny: an allowed token without a cap cannot leave the vault.
    function test_executeTransfer_noCapSet_rejected() external {
        MockERC3643 uncapped = _newFundedToken();
        vault.setAssetConfig(address(uncapped), true, 0);
        vault.setCounterpartyDailyCap(cp1, address(uncapped), UNLIMITED);

        _expectRejected(address(uncapped), cp1, 1, TreasuryVault.RejectReason.AssetDailyCapExceeded);
        vault.executeTransfer(address(uncapped), cp1, 1);

        assertEq(uncapped.balanceOf(cp1), 0);
    }

    /// @dev "Unlimited" is an explicit choice: type(uint256).max.
    function test_executeTransfer_unlimitedAssetCap_allowsLargeTransfer() external {
        vault.setAssetConfig(address(token), true, UNLIMITED);

        vault.executeTransfer(address(token), cp1, 80_000e18);
        assertEq(token.balanceOf(cp1), 80_000e18);
    }

    function test_executeTransfer_underAssetCap_succeeds() external {
        vault.executeTransfer(address(token), cp1, 3000e18);
        assertEq(token.balanceOf(cp1), 3000e18);
    }

    /// @dev Two transfers to DIFFERENT counterparties that together exceed the
    ///      per-asset cap. The second should be rejected.
    function test_executeTransfer_twoCounterparties_exceedsAssetCap_rejected() external {
        // 3000 to cp1 - ok (3000 < 5000)
        vault.executeTransfer(address(token), cp1, 3000e18);

        // 3000 to cp2 - rejected (3000 + 3000 = 6000 > 5000 cap)
        _expectRejected(address(token), cp2, 3000e18, TreasuryVault.RejectReason.AssetDailyCapExceeded);
        (bool executed, TreasuryVault.RejectReason reason,) = vault.executeTransfer(address(token), cp2, 3000e18);

        assertFalse(executed);
        assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.AssetDailyCapExceeded));
        assertEq(token.balanceOf(cp1), 3000e18);
        assertEq(token.balanceOf(cp2), 0);
    }

    function test_executeTransfer_exactlyAtAssetCap_succeeds() external {
        vault.executeTransfer(address(token), cp1, ASSET_CAP);
        assertEq(token.balanceOf(cp1), ASSET_CAP);
    }

    function test_executeTransfer_afterDayReset_assetCapRefreshes() external {
        vault.executeTransfer(address(token), cp1, ASSET_CAP);

        _expectRejected(address(token), cp2, 1000e18, TreasuryVault.RejectReason.AssetDailyCapExceeded);
        vault.executeTransfer(address(token), cp2, 1000e18);

        vm.warp(block.timestamp + 1 days);

        vault.executeTransfer(address(token), cp2, 1000e18);
        assertEq(token.balanceOf(cp2), 1000e18);
    }

    /// @dev The cap on one asset must not affect another asset.
    function test_executeTransfer_assetCap_perAssetIsolation() external {
        MockERC3643 tokenB = _newFundedToken();
        vault.setAssetConfig(address(tokenB), true, UNLIMITED);
        vault.setCounterpartyDailyCap(cp1, address(tokenB), UNLIMITED);

        // Max out token A's cap.
        vault.executeTransfer(address(token), cp1, ASSET_CAP);

        // tokenB still transfers.
        vault.executeTransfer(address(tokenB), cp1, 50_000e18);
        assertEq(tokenB.balanceOf(cp1), 50_000e18);
    }

    /// @dev `assetSpent + amount` used to overflow and revert with Panic(0x11).
    ///      Now the rejection is logged like any other.
    function test_executeTransfer_hugeAmount_assetCap_rejectedWithoutPanic() external {
        vault.setAssetConfig(address(token), true, UNLIMITED);
        vault.executeTransfer(address(token), cp1, 1000e18);

        // cp2 has spent nothing, so its own cap lets the amount through to gate 4.
        uint256 huge = UNLIMITED - 1000e18 + 1;
        _expectRejected(address(token), cp2, huge, TreasuryVault.RejectReason.AssetDailyCapExceeded);
        vault.executeTransfer(address(token), cp2, huge);
    }

    /// @dev A cap lowered below what was already spent today rejects without an underflow.
    function test_setAssetConfig_capLoweredBelowSpent_rejectsWithoutPanic() external {
        vault.executeTransfer(address(token), cp1, 3000e18);
        vault.setAssetConfig(address(token), true, 2000e18);

        _expectRejected(address(token), cp1, 1, TreasuryVault.RejectReason.AssetDailyCapExceeded);
        vault.executeTransfer(address(token), cp1, 1);
    }

    function test_assetSpentToday_countsSuccessesAndResetsNextDay() external {
        vault.executeTransfer(address(token), cp1, 1000e18);
        vault.executeTransfer(address(token), cp2, 500e18);
        assertEq(vault.assetSpentToday(address(token)), 1500e18);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.assetSpentToday(address(token)), 0);
    }
}
