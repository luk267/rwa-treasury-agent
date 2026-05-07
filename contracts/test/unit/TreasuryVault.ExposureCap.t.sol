// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

contract TreasuryVaultExposureCapTest is Test {
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    address cp1 = makeAddr("cp1");
    address cp2 = makeAddr("cp2");
    address alice = makeAddr("alice");

    uint256 constant DAILY_CAP = type(uint256).max;
    uint256 constant EXPOSURE_CAP = 5_000e18;

    TreasuryVault vault;
    MockERC3643 token;

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );
    event ExposureCapSet(address indexed asset, uint256 cap);

    function setUp() public {
        vault = new TreasuryVault();
        token = new MockERC3643();
        token.transfer(address(vault), 100_000e18);

        // Both counterparties have high daily caps - the asset exposure cap
        // is the binding constraint in these tests.
        vault.addCounterparty(cp1, DAILY_CAP);
        vault.addCounterparty(cp2, DAILY_CAP);

        // Set exposure cap: max 5000 tokens of this asset per day across ALL counterparties
        vault.setExposureCap(address(token), EXPOSURE_CAP);
    }

    // ── Setter tests ─────────────────────────────────────────────────

    function test_setExposureCap_byTreasurer_emitsEvent() external {
        MockERC3643 otherToken = new MockERC3643();
        vm.expectEmit();
        emit ExposureCapSet(address(otherToken), 10_000e18);
        vault.setExposureCap(address(otherToken), 10_000e18);
    }

    function test_setExposureCap_byNonTreasurer_reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, TREASURER_ROLE)
        );
        vault.setExposureCap(address(token), 1000e18);
    }

    function test_getExposureCap_returnsSetValue() external view {
        assertEq(vault.getExposureCap(address(token)), EXPOSURE_CAP);
    }

    function test_getExposureCap_unsetAsset_returnsZero() external {
        assertEq(vault.getExposureCap(makeAddr("unknown-token")), 0);
    }

    // ── Transfer tests ───────────────────────────────────────────────

    /// @dev Single transfer under exposure cap should succeed.
    function test_executeTransfer_underExposureCap_succeeds() external {
        vault.executeTransfer(address(token), cp1, 3_000e18);
        assertEq(token.balanceOf(cp1), 3_000e18);
    }

    /// @dev Two transfers to DIFFERENT counterparties that together exceed the
    ///      per-asset cap. The second should be rejected.
    function test_executeTransfer_twoCounterparties_exceedsExposureCap_rejected() external {
        // 3000 to cp1 - ok (3000 < 5000)
        vault.executeTransfer(address(token), cp1, 3_000e18);

        // 3000 to cp2 - rejected (3000 + 3000 = 6000 > 5000 cap)
        vm.expectEmit();
        emit TransferRejected(
            address(token), cp2, 3_000e18, TreasuryVault.RejectReason.ExposureCapExceeded, ""
        );
        vault.executeTransfer(address(token), cp2, 3_000e18);

        assertEq(token.balanceOf(cp1), 3_000e18);
        assertEq(token.balanceOf(cp2), 0);
    }

    /// @dev Transfer exactly at exposure cap should succeed.
    function test_executeTransfer_exactlyAtExposureCap_succeeds() external {
        vault.executeTransfer(address(token), cp1, EXPOSURE_CAP);
        assertEq(token.balanceOf(cp1), EXPOSURE_CAP);
    }

    /// @dev After a day passes, the exposure cap resets.
    function test_executeTransfer_afterDayReset_exposureCapRefreshes() external {
        // Max out the exposure cap
        vault.executeTransfer(address(token), cp1, EXPOSURE_CAP);

        // Should be rejected now
        vm.expectEmit();
        emit TransferRejected(
            address(token), cp2, 1_000e18, TreasuryVault.RejectReason.ExposureCapExceeded, ""
        );
        vault.executeTransfer(address(token), cp2, 1_000e18);

        // Fast-forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Now it should work - new day bucket
        vault.executeTransfer(address(token), cp2, 1_000e18);
        assertEq(token.balanceOf(cp2), 1_000e18);
    }

    /// @dev When no exposure cap is set (0), transfers are unlimited.
    function test_executeTransfer_noExposureCap_unlimited() external {
        MockERC3643 uncappedToken = new MockERC3643();
        uncappedToken.transfer(address(vault), 100_000e18);
        // No setExposureCap call - cap stays at default 0

        vault.executeTransfer(address(uncappedToken), cp1, 80_000e18);
        assertEq(uncappedToken.balanceOf(cp1), 80_000e18);
    }

    /// @dev Exposure cap on one asset must not affect another asset.
    function test_executeTransfer_exposureCap_perAssetIsolation() external {
        MockERC3643 tokenB = new MockERC3643();
        tokenB.transfer(address(vault), 100_000e18);
        // tokenB has no exposure cap

        // Max out token A's exposure cap
        vault.executeTransfer(address(token), cp1, EXPOSURE_CAP);

        // tokenB should still transfer fine
        vault.executeTransfer(address(tokenB), cp1, 50_000e18);
        assertEq(tokenB.balanceOf(cp1), 50_000e18);
    }
}
