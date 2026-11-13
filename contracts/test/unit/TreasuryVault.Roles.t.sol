// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import { TreasuryVault } from "../../src/TreasuryVault.sol";
import { MockERC3643 } from "../mocks/MockERC3643.sol";

/// @dev Each role sits on its own account. Checks least privilege and the two-step admin handover.
contract TreasuryVaultRolesTest is Test {
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint48 constant ADMIN_DELAY = 1 days;

    address admin = makeAddr("admin");
    address treasurer = makeAddr("treasurer");
    address agent = makeAddr("agent");
    address pauser = makeAddr("pauser");
    address cp1 = makeAddr("cp1");

    TreasuryVault vault;
    MockERC3643 token;

    function setUp() public {
        vault = new TreasuryVault(ADMIN_DELAY, admin, treasurer, agent, pauser);
        token = new MockERC3643();
        token.setVerified(address(vault), true);
        token.setVerified(cp1, true);
        assertTrue(token.transfer(address(vault), 100_000e18));

        vm.startPrank(treasurer);
        vault.setAssetConfig(address(token), true, type(uint256).max);
        vault.addCounterparty(cp1);
        vault.setCounterpartyDailyCap(cp1, address(token), 1000e18);
        vm.stopPrank();
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    // ---------- Constructor ----------

    function test_constructor_grantsEachRoleToItsAccount() external view {
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin missing DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(TREASURER_ROLE, treasurer), "treasurer missing TREASURER_ROLE");
        assertTrue(vault.hasRole(AGENT_ROLE, agent), "agent missing AGENT_ROLE");
        assertTrue(vault.hasRole(PAUSER_ROLE, pauser), "pauser missing PAUSER_ROLE");

        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, agent), "agent has DEFAULT_ADMIN_ROLE");
        assertFalse(vault.hasRole(TREASURER_ROLE, agent), "agent has TREASURER_ROLE");
        assertFalse(vault.hasRole(PAUSER_ROLE, agent), "agent has PAUSER_ROLE");
        assertFalse(vault.hasRole(AGENT_ROLE, admin), "admin has AGENT_ROLE");

        assertEq(vault.defaultAdmin(), admin);
        assertEq(vault.defaultAdminDelay(), ADMIN_DELAY);
    }

    function test_constructor_zeroAddress_reverts() external {
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        new TreasuryVault(ADMIN_DELAY, admin, address(0), agent, pauser);

        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        new TreasuryVault(ADMIN_DELAY, admin, treasurer, address(0), pauser);

        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        new TreasuryVault(ADMIN_DELAY, admin, treasurer, agent, address(0));
    }

    function test_constructor_zeroAdmin_reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new TreasuryVault(ADMIN_DELAY, address(0), treasurer, agent, pauser);
    }

    function test_deployer_hasNoRoleAfterDeployment() external view {
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "deployer has DEFAULT_ADMIN_ROLE");
        assertFalse(vault.hasRole(TREASURER_ROLE, address(this)), "deployer has TREASURER_ROLE");
        assertFalse(vault.hasRole(AGENT_ROLE, address(this)), "deployer has AGENT_ROLE");
        assertFalse(vault.hasRole(PAUSER_ROLE, address(this)), "deployer has PAUSER_ROLE");
    }

    // ---------- Agent is limited to executeTransfer ----------

    function test_agent_cannotAddCounterparty() external {
        _expectUnauthorized(agent, TREASURER_ROLE);
        vm.prank(agent);
        vault.addCounterparty(makeAddr("attacker"));
    }

    function test_agent_cannotSetAssetConfig() external {
        _expectUnauthorized(agent, TREASURER_ROLE);
        vm.prank(agent);
        vault.setAssetConfig(makeAddr("fake-token"), true, type(uint256).max);
    }

    function test_agent_cannotSetCounterpartyDailyCap() external {
        _expectUnauthorized(agent, TREASURER_ROLE);
        vm.prank(agent);
        vault.setCounterpartyDailyCap(cp1, address(token), type(uint256).max);
    }

    function test_agent_cannotPause() external {
        _expectUnauthorized(agent, PAUSER_ROLE);
        vm.prank(agent);
        vault.pause();
    }

    function test_agent_cannotGrantRole() external {
        _expectUnauthorized(agent, DEFAULT_ADMIN_ROLE);
        vm.prank(agent);
        vault.grantRole(TREASURER_ROLE, agent);
    }

    // ---------- Other roles cannot move tokens ----------

    function test_treasurer_cannotExecuteTransfer() external {
        _expectUnauthorized(treasurer, AGENT_ROLE);
        vm.prank(treasurer);
        vault.executeTransfer(address(token), cp1, 1e18);
    }

    function test_pauser_cannotExecuteTransfer() external {
        _expectUnauthorized(pauser, AGENT_ROLE);
        vm.prank(pauser);
        vault.executeTransfer(address(token), cp1, 1e18);
    }

    // ---------- Admin ----------

    function test_admin_revokeAgent_blocksExecuteTransfer() external {
        vm.prank(agent);
        vault.executeTransfer(address(token), cp1, 1e18);
        assertEq(token.balanceOf(cp1), 1e18);

        vm.prank(admin);
        vault.revokeRole(AGENT_ROLE, agent);

        _expectUnauthorized(agent, AGENT_ROLE);
        vm.prank(agent);
        vault.executeTransfer(address(token), cp1, 1e18);
    }

    function test_admin_cannotGrantAdminRoleDirectly() external {
        address newAdmin = makeAddr("newAdmin");
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vm.prank(admin);
        vault.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
    }

    function test_adminTransfer_needsTwoStepsAndDelay() external {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        vault.beginDefaultAdminTransfer(newAdmin);
        (address pending, uint48 schedule) = vault.pendingDefaultAdmin();
        assertEq(pending, newAdmin);
        assertEq(schedule, uint48(block.timestamp) + ADMIN_DELAY);

        // Step 2 before the delay has passed: rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();

        // Step 2 after the delay: the role moves, the old admin loses it.
        vm.warp(uint256(schedule) + 1);
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();

        assertEq(vault.defaultAdmin(), newAdmin);
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }
}
