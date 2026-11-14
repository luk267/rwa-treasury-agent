// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

/// @dev A plain token with 6 decimals, like most stablecoins. Only used to show that
///      raw amounts of tokens with different decimals are never added up.
contract SixDecimalToken is ERC20 {
    constructor() ERC20("Six Decimals", "SIX") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Daily cap per counterparty and token (gate 3).
contract TreasuryVaultDailyCapTest is Test {
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    address cp1 = makeAddr("cp1");
    address alice = makeAddr("alice");

    uint256 constant DAILY_CAP = 1000e18;
    uint256 constant UNLIMITED = type(uint256).max;

    TreasuryVault vault;
    MockERC3643 token;

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TransferRejected(
        address indexed token, address indexed to, uint256 amount, TreasuryVault.RejectReason reason, bytes detail
    );
    event CounterpartyDailyCapSet(address indexed counterparty, address indexed token, uint256 dailyCap);

    function setUp() public {
        vault = new TreasuryVault(1 days, address(this), address(this), address(this), address(this));
        token = new MockERC3643();

        // The test contract deployed the token, so it is the issuer and can verify holders.
        token.setVerified(address(vault), true);
        token.setVerified(cp1, true);

        // Fund the vault so transfers can actually move tokens
        assertTrue(token.transfer(address(vault), 100_000e18));

        // The token has no asset cap of its own here, so the counterparty cap binds.
        vault.setAssetConfig(address(token), true, UNLIMITED);

        // Whitelist cp1 with a daily cap of 1000 tokens of this token
        vault.addCounterparty(cp1);
        vault.setCounterpartyDailyCap(cp1, address(token), DAILY_CAP);
    }

    function _expectRejected(address t, uint256 amount) internal {
        vm.expectEmit(address(vault));
        emit TransferRejected(t, cp1, amount, TreasuryVault.RejectReason.DailyCapExceeded, "");
    }

    // ── Setter ───────────────────────────────────────────────────────

    function test_setCounterpartyDailyCap_byTreasurer_emitsAndStores() external {
        address other = makeAddr("other-token");
        vm.expectEmit(address(vault));
        emit CounterpartyDailyCapSet(cp1, other, 250e18);
        vault.setCounterpartyDailyCap(cp1, other, 250e18);

        assertEq(vault.getCounterpartyDailyCap(cp1, other), 250e18);
        assertEq(vault.getCounterpartyDailyCap(cp1, address(token)), DAILY_CAP, "other token's cap changed");
    }

    function test_setCounterpartyDailyCap_byNonTreasurer_reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, TREASURER_ROLE)
        );
        vault.setCounterpartyDailyCap(cp1, address(token), UNLIMITED);
    }

    // ── Gate 3 ───────────────────────────────────────────────────────

    /// @dev A single transfer under the daily cap should succeed.
    function test_executeTransfer_underDailyCap_succeeds() external {
        vm.expectEmit(address(vault));
        emit TransferExecuted(address(token), cp1, 500e18, address(this));
        (bool executed, TreasuryVault.RejectReason reason, bytes memory detail) =
            vault.executeTransfer(address(token), cp1, 500e18);

        assertTrue(executed);
        assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.None));
        assertEq(detail, "");
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
        vm.expectEmit(address(vault));
        emit TransferRejected(address(token), cp1, 500e18, TreasuryVault.RejectReason.DailyCapExceeded, "");
        (bool executed, TreasuryVault.RejectReason reason,) = vault.executeTransfer(address(token), cp1, 500e18);

        assertFalse(executed);
        assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.DailyCapExceeded));

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
        vm.expectEmit(address(vault));
        emit TransferRejected(address(token), cp1, 100e18, TreasuryVault.RejectReason.DailyCapExceeded, "");
        vault.executeTransfer(address(token), cp1, 100e18);

        // Fast-forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Now it should work again - new day bucket
        vault.executeTransfer(address(token), cp1, 500e18);
        assertEq(token.balanceOf(cp1), DAILY_CAP + 500e18);
    }

    /// @dev Default-deny: a cap for one token does not open another token to the same counterparty.
    function test_executeTransfer_noCounterpartyCapForToken_rejected() external {
        MockERC3643 tokenB = new MockERC3643();
        tokenB.setVerified(address(vault), true);
        tokenB.setVerified(cp1, true);
        assertTrue(tokenB.transfer(address(vault), 100_000e18));
        vault.setAssetConfig(address(tokenB), true, UNLIMITED);

        _expectRejected(address(tokenB), 1);
        vault.executeTransfer(address(tokenB), cp1, 1);
    }

    /// @dev Each token has its own counter. 1000 MOCK (18 decimals) and 1000 SIX (6 decimals)
    ///      are different raw numbers; one shared counter would compare 1e21 with 1e9.
    function test_dailyCap_isPerToken() external {
        SixDecimalToken six = new SixDecimalToken();
        assertTrue(six.transfer(address(vault), 100_000e6));
        vault.setAssetConfig(address(six), true, UNLIMITED);
        vault.setCounterpartyDailyCap(cp1, address(six), 1000e6);

        // Use up cp1's full MOCK cap.
        vault.executeTransfer(address(token), cp1, DAILY_CAP);

        // The SIX cap is untouched.
        vm.expectEmit(address(vault));
        emit TransferExecuted(address(six), cp1, 1000e6, address(this));
        vault.executeTransfer(address(six), cp1, 1000e6);

        assertEq(vault.spentToday(cp1, address(token)), DAILY_CAP);
        assertEq(vault.spentToday(cp1, address(six)), 1000e6);

        // Both caps are now full, each in its own unit.
        _expectRejected(address(six), 1);
        vault.executeTransfer(address(six), cp1, 1);
    }

    /// @dev `spent + amount` used to overflow and revert with Panic(0x11).
    ///      Now the rejection is logged like any other.
    function test_executeTransfer_hugeAmount_rejectedWithoutPanic() external {
        vault.setCounterpartyDailyCap(cp1, address(token), UNLIMITED);
        vault.executeTransfer(address(token), cp1, 500e18);

        uint256 huge = UNLIMITED - 500e18 + 1;
        _expectRejected(address(token), huge);
        vault.executeTransfer(address(token), cp1, huge);
    }

    /// @dev A cap lowered below what was already spent today rejects without an underflow.
    function test_setCounterpartyDailyCap_loweredBelowSpent_rejectsWithoutPanic() external {
        vault.executeTransfer(address(token), cp1, 600e18);
        vault.setCounterpartyDailyCap(cp1, address(token), 500e18);

        _expectRejected(address(token), 1);
        vault.executeTransfer(address(token), cp1, 1);
    }

    function test_spentToday_countsSuccessesAndResetsNextDay() external {
        vault.executeTransfer(address(token), cp1, 300e18);
        vault.executeTransfer(address(token), cp1, 200e18);
        assertEq(vault.spentToday(cp1, address(token)), 500e18);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.spentToday(cp1, address(token)), 0);
    }
}
