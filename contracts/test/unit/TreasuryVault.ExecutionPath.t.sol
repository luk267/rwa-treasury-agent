// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test, Vm } from "forge-std/Test.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { EmptyRevertToken } from "../mocks/EmptyRevertToken.sol";
import { FalseReturnToken } from "../mocks/FalseReturnToken.sol";
import { GasHeavyToken } from "../mocks/GasHeavyToken.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";
import { ReentrantToken } from "../mocks/ReentrantToken.sol";

/// @dev The external call to the token (gate 5): what the vault does when the token gives no
///      reason, runs out of gas or calls back into the vault.
contract TreasuryVaultExecutionPathTest is Test {
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    address cp1 = makeAddr("cp1");

    uint256 constant UNLIMITED = type(uint256).max;
    uint256 constant DAILY_CAP = 1000e18;

    TreasuryVault vault;

    function setUp() public {
        vault = new TreasuryVault(1 days, address(this), address(this), address(this), address(this));
        vault.addCounterparty(cp1);
    }

    /// @dev Allow `token` without an asset cap and give cp1 DAILY_CAP for it.
    function _allow(address token) internal {
        vault.setAssetConfig(token, true, UNLIMITED);
        vault.setCounterpartyDailyCap(cp1, token, DAILY_CAP);
    }

    /// @dev Regression for L11: a transfer of 0 used to pass every gate and log TransferExecuted.
    ///      It is invalid input, so it reverts like a missing role, before any gate runs.
    function test_executeTransfer_zeroAmount_reverts() external {
        MockERC3643 token = new MockERC3643();
        _allow(address(token));

        vm.expectRevert(TreasuryVault.ZeroAmount.selector);
        vault.executeTransfer(address(token), cp1, 0);
    }

    /// @dev A revert without data is not a compliance decision. It is also what an out-of-gas
    ///      inside the token looks like. The vault reverts instead of logging a rejection.
    function test_executeTransfer_tokenRevertsWithoutReason_reverts() external {
        EmptyRevertToken token = new EmptyRevertToken();
        _allow(address(token));

        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TokenTransferFailedWithoutReason.selector, token));
        vault.executeTransfer(address(token), cp1, 100e18);
    }

    /// @dev `false` carries no reason either. Before, this branch was never tested.
    function test_executeTransfer_tokenReturnsFalse_reverts() external {
        FalseReturnToken token = new FalseReturnToken();
        _allow(address(token));

        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TokenTransferFailedWithoutReason.selector, token));
        vault.executeTransfer(address(token), cp1, 100e18);
    }

    /// @dev Regression for L5. The vault keeps 1/64 of its gas when it calls the token (EIP-150).
    ///      If the token runs out of gas, that rest used to be enough to log an ERC3643Compliance
    ///      rejection, so the agent could fake one by picking the gas limit. For every limit the
    ///      call must now either execute or revert as a whole.
    function test_executeTransfer_outOfGasInToken_neverLogsRejection() external {
        GasHeavyToken heavy = new GasHeavyToken();
        assertTrue(heavy.transfer(address(vault), 100e18));
        _allow(address(heavy));

        bytes memory data = abi.encodeCall(TreasuryVault.executeTransfer, (address(heavy), cp1, 1e18));
        bool sawRevert;
        bool sawSuccess;

        for (uint256 gasLimit = 50_000; gasLimit <= 800_000; gasLimit += 10_000) {
            vm.recordLogs();
            (bool ok,) = address(vault).call{ gas: gasLimit }(data);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (!ok) {
                sawRevert = true;
                continue;
            }
            sawSuccess = true;
            for (uint256 i; i < logs.length; ++i) {
                assertTrue(
                    logs[i].topics[0] != TreasuryVault.TransferRejected.selector,
                    string.concat("rejection logged at gas limit ", vm.toString(gasLimit))
                );
            }
        }

        // The range must cover both sides of the threshold, or the test proves nothing.
        assertTrue(sawRevert, "no gas limit was low enough to fail");
        assertTrue(sawSuccess, "no gas limit was high enough to succeed");
    }

    /// @dev Regression for L10. The counters are written after the external call. A token with
    ///      AGENT_ROLE that calls executeTransfer from inside its transfer would see the same
    ///      counter twice and send the daily cap twice. The guard stops the inner call.
    function test_executeTransfer_reentrantToken_cannotBypassCaps() external {
        ReentrantToken evil = new ReentrantToken(vault);
        assertTrue(evil.transfer(address(vault), 10_000e18));
        _allow(address(evil));
        vault.grantRole(AGENT_ROLE, address(evil));

        (bool executed, TreasuryVault.RejectReason reason, bytes memory detail) =
            vault.executeTransfer(address(evil), cp1, DAILY_CAP);

        // The guard reverts the inner call; the token passes that revert on as its own error.
        assertFalse(executed);
        assertEq(uint8(reason), uint8(TreasuryVault.RejectReason.ERC3643Compliance));
        assertEq(detail, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        assertLe(evil.balanceOf(cp1), DAILY_CAP, "re-entry sent more than the daily cap");
        assertEq(vault.spentToday(cp1, address(evil)), evil.balanceOf(cp1), "counter differs from what left the vault");
    }
}
