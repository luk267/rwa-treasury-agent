// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";

contract TreasuryVaultSkeletonTest is Test {
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address alice = makeAddr("alice");

    TreasuryVault vault;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, address indexed by);

    error VaultPaused();

    function setUp() public {
        vault = new TreasuryVault();
        vault.addCounterparty(alice, type(uint256).max);
    }

    function test_constructor_grantsAllRolesToDeployer() external view {
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "missing DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(TREASURER_ROLE, address(this)), "missing TREASURER_ROLE");
        assertTrue(vault.hasRole(AGENT_ROLE, address(this)), "missing AGENT_ROLE");
        assertTrue(vault.hasRole(PAUSER_ROLE, address(this)), "missing PAUSER_ROLE");
    }

    function test_pause_byPauser_emitsEvent() external {
        vm.expectEmit();
        emit Paused(address(this));
        vault.pause();
    }

    function test_pause_byNonPauser_reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        vault.pause();
    }

    function test_unpause_byPauser_emitsEvent() external {
        vault.pause();
        vm.expectEmit();
        emit Unpaused(address(this));
        vault.unpause();
    }

    function test_executeTransfer_whenPaused_reverts() external {
        vault.pause();
        vm.expectRevert(VaultPaused.selector);
        vault.executeTransfer(address(0xbeef), alice, 100);
    }

    function test_executeTransfer_whenUnpaused_emitsTransferExecutedStub() external {
        address token = address(0xbeef);
        vm.expectEmit();
        emit TransferExecuted(token, alice, 100, address(this));
        vault.executeTransfer(token, alice, 100);
    }
}
